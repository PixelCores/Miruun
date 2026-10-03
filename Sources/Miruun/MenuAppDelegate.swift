import AppKit
import ServiceManagement
import BridgeEngine

/// Keeps short settings content at the top of the scroll viewport.
private final class SettingsStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// UI state stays on the main queue. All configuration access is serialized on
/// worker; stopping waits for any in-progress atomic update before returning.
final class MenuAppDelegate: NSObject, NSApplicationDelegate {
    private let worker = DispatchQueue(label: "io.github.pixelcores.miruun.continuity", qos: .utility)
    private var timer: DispatchSourceTimer? // worker queue only
    private var guardService: ContinuityGuard? // worker queue only
    private var pendingLaunch: (id: UUID, application: URL, home: URL)? // worker queue only
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var enabledItem: NSMenuItem!
    private var statusMenuItem: NSMenuItem!
    private var openItems: [NSMenuItem] = []
    private let homeField = NSTextField()
    private let enableButton = NSButton(checkboxWithTitle: "启用后台连续性守护", target: nil, action: nil)
    private let loginButton = NSButton(checkboxWithTitle: "登录 Mac 时启动 Miruun", target: nil, action: nil)
    private let autoOpenButton = NSButton(checkboxWithTitle: "打开 Miruun 时自动打开 Codex", target: nil, action: nil)
    private let openButton = NSButton(title: "打开 Codex", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "未启用")
    private let loginLabel = NSTextField(wrappingLabelWithString: "")
    private var chooseButton: NSButton!
    private var transitioning = false
    private var enabled = false
    private var launchRequest: UUID? // main queue only; also invalidates queued callbacks
    private var launchError: String?
    private static let codexIdentifier = "com.openai.codex"

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: {
               $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
           }) {
            NSApp.terminate(nil)
            return
        }
        makeMenu()
        makeWindow()
        let preferences = UserDefaults.standard
        homeField.stringValue = preferences.string(forKey: "continuityHome")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        autoOpenButton.state = preferences.bool(forKey: "autoOpenCodex") ? .on : .off
        refreshLoginState()
        if preferences.bool(forKey: "continuityEnabled") { start() }
        else { showStatus("守护已暂停 · 现有配置保持原样", symbol: "pause.circle") }
        // Manual launches must remain discoverable even after the first run.
        // Only a system login launch should start without a settings window.
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let launchedAtLogin = launchEvent?.eventID == kAEOpenApplication
            && launchEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !launchedAtLogin {
            if enabled && autoOpenButton.state == .on { openCodex() }
            else { showWindow() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if window != nil {
            if enabled && autoOpenButton.state == .on { openCodex() }
            else { showWindow() }
        }
        return true
    }

    private func makeMenu() {
        let mainMenu = NSMenu()
        let applicationItem = mainMenu.addItem(withTitle: "Miruun", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "Miruun")
        let settingsItem = applicationMenu.addItem(withTitle: "设置与状态…", action: #selector(showWindow), keyEquivalent: ",")
        settingsItem.target = self
        let openItem = applicationMenu.addItem(withTitle: "打开 Codex", action: #selector(openCodex), keyEquivalent: "")
        openItem.target = self
        openItems.append(openItem)
        applicationMenu.addItem(.separator())
        let quitItem = applicationMenu.addItem(withTitle: "退出 Miruun", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        applicationItem.submenu = applicationMenu
        NSApp.mainMenu = mainMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: "Miruun", action: nil, keyEquivalent: "")
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "设置与状态…", action: #selector(showWindow), keyEquivalent: ",")
        openItems.append(menu.addItem(withTitle: "打开 Codex", action: #selector(openCodex), keyEquivalent: ""))
        enabledItem = menu.addItem(withTitle: "启用后台守护", action: #selector(toggleEnabled), keyEquivalent: "")
        menu.addItem(withTitle: "查看配置备份…", action: #selector(revealBackups), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出 Miruun", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        menu.autoenablesItems = false
        statusMenuItem.isEnabled = false
        statusItem.menu = menu
        applicationMenu.autoenablesItems = false
    }

    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Miruun · 对话连续性"
        window.isReleasedWhenClosed = false
        window.center()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        window.contentView = scroll
        let root = SettingsStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = root
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            root.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            root.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])
        let title = NSTextField(labelWithString: "换个账号，继续原来的工作")
        title.font = .systemFont(ofSize: 23, weight: .semibold)
        root.addArrangedSubview(title)
        addText("一次启用，后台维护 Codex 的接入配置。支持原生 openai 历史；回到官方登录时补齐缺失的 custom 接入，保留原对话。", to: root)
        addText("Miruun 复用 CC Switch 已配置的本机代理 Key，备份配置与认证后，为 Codex 设置 API Key 接入。账号由 CLIProxyAPI 管理，对话历史保持原样。", to: root)

        root.addArrangedSubview(NSTextField(labelWithString: "Codex 数据目录"))
        homeField.isEditable = false
        homeField.isSelectable = true
        homeField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        homeField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        chooseButton = NSButton(title: "选择…", target: self, action: #selector(chooseHome))
        let row = NSStackView(views: [homeField, chooseButton])
        row.spacing = 10
        root.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48).isActive = true

        enableButton.target = self; enableButton.action = #selector(toggleEnabled)
        loginButton.target = self; loginButton.action = #selector(toggleLogin)
        root.addArrangedSubview(enableButton)
        root.addArrangedSubview(loginButton)
        autoOpenButton.target = self; autoOpenButton.action = #selector(toggleAutoOpen)
        root.addArrangedSubview(autoOpenButton)
        openButton.target = self; openButton.action = #selector(openCodex)
        root.addArrangedSubview(openButton)
        loginLabel.font = .systemFont(ofSize: 11)
        loginLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(loginLabel)
        statusLabel.isSelectable = true
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        root.addArrangedSubview(statusLabel)
        statusLabel.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48).isActive = true
        addText("通过“打开 Codex”自动等配置就绪后启动。若 Codex 仍在运行，请先正常退出。勾选自动打开后，可将 Miruun 固定到 Dock 作为启动入口；登录 Mac 时仍保持静默。接管时不改写历史。", to: root)
        refreshControls()
    }

    private func addText(_ text: String, to root: NSStackView) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        root.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48).isActive = true
    }

    private var backupDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Miruun/ConfigBackups", isDirectory: true)
    }

    @objc private func showWindow() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func chooseHome() {
        guard !enabled, !transitioning else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = false; panel.allowsMultipleSelection = false
        panel.title = "选择 Codex 使用的 CODEX_HOME"
        if panel.runModal() == .OK, let url = panel.url {
            homeField.stringValue = url.path
            UserDefaults.standard.set(url.path, forKey: "continuityHome")
        }
    }

    @objc private func toggleEnabled() {
        guard !transitioning else { return }
        if enabled { stop() } else { start() }
    }

    private func start() {
        guard Bundle.main.bundleIdentifier == "io.github.pixelcores.miruun" else {
            showStatus("请运行打包后的 Miruun.app", symbol: "exclamationmark.circle")
            return
        }
        enabled = true
        launchError = nil
        UserDefaults.standard.set(true, forKey: "continuityEnabled")
        UserDefaults.standard.set(homeField.stringValue, forKey: "continuityHome")
        refreshControls()
        showStatus("正在等待稳定的代理配置…", symbol: "arrow.triangle.2.circlepath")
        let home = URL(fileURLWithPath: homeField.stringValue, isDirectory: true)
        let backups = backupDirectory
        worker.async { [self] in
            self.guardService = ContinuityGuard(home: home, backupDirectory: backups)
            let timer = DispatchSource.makeTimerSource(queue: self.worker)
            timer.schedule(deadline: .now(), leeway: .milliseconds(300))
            timer.setEventHandler { [weak self] in
                self?.checkConfiguration()
            }
            self.timer = timer
            timer.resume()
        }
    }

    private func stop() {
        launchRequest = nil
        launchError = nil
        transitioning = true
        refreshControls()
        worker.async {
            self.timer?.cancel(); self.timer = nil
            self.guardService = nil; self.pendingLaunch = nil
            DispatchQueue.main.async {
                self.enabled = false; self.transitioning = false
                UserDefaults.standard.set(false, forKey: "continuityEnabled")
                self.refreshControls()
                self.showStatus("守护已暂停 · 现有配置保持原样", symbol: "pause.circle")
            }
        }
    }

    private func refreshControls() {
        enableButton.state = enabled ? .on : .off
        enabledItem.state = enabled ? .on : .off
        enableButton.isEnabled = !transitioning
        enabledItem.isEnabled = !transitioning
        chooseButton.isEnabled = !enabled && !transitioning
        openButton.isEnabled = enabled && !transitioning && launchRequest == nil
        for item in openItems { item.isEnabled = openButton.isEnabled }
    }

    @objc private func toggleAutoOpen() {
        UserDefaults.standard.set(autoOpenButton.state == .on, forKey: "autoOpenCodex")
    }

    @objc private func openCodex() {
        guard enabled, !transitioning, launchRequest == nil else { return }
        launchError = nil
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.codexIdentifier),
              Bundle(url: application)?.bundleIdentifier == Self.codexIdentifier else {
            finishLaunch(error: "未找到 Codex 应用，请先安装并正常打开一次。")
            return
        }
        let id = UUID(), home = URL(fileURLWithPath: homeField.stringValue, isDirectory: true)
        launchRequest = id
        refreshControls()
        showStatus("正在检查当前接入配置，完成后自动打开 Codex…", symbol: "clock")
        worker.async {
            self.pendingLaunch = (id, application, home)
        }
    }

    /// Worker queue only. Launch requests use a fresh check on the normal timer;
    /// clicking never shortens the guard's stable sampling interval.
    private func checkConfiguration() {
        // One-shot scheduling avoids catch-up ticks shortening the sampling
        // interval after process checks or a slow login shell probe.
        defer { timer?.schedule(deadline: .now() + .seconds(2), leeway: .milliseconds(300)) }
        guard let guardService else { return }
        let request = pendingLaunch
        var status = request == nil ? guardService.check() : guardService.checkForLaunch()
        if let request, status.phase == .ready || status.phase == .updated {
            do {
                try NativeDiscovery.verifyLaunchHome(request.home)
                // The shell probe can take time; re-read files and client state
                // before dispatching a launch instead of retaining an old result.
                status = guardService.checkForLaunch()
            } catch {
                status = ContinuityStatus(phase: .blocked, message: (error as? NativeEngineError)?.message
                    ?? "无法确认 Codex 的启动目录；未启动应用。")
            }
        }
        if let request, status.phase != .waiting {
            pendingLaunch = nil
            DispatchQueue.main.async {
                guard self.launchRequest == request.id else { return }
                if status.phase == .blocked { self.finishLaunch(error: status.message) }
                else { self.launchCodex(application: request.application, home: request.home, id: request.id) }
            }
        } else {
            DispatchQueue.main.async {
                guard self.enabled, !self.transitioning else { return }
                self.show(status)
            }
        }
    }

    private func launchCodex(application: URL, home: URL, id: UUID) {
        // NSWorkspace environment overrides apply only to a new process.
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Self.codexIdentifier).isEmpty else {
            finishLaunch(error: "Codex 已从其他入口启动；请退出后再通过 Miruun 打开。")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.environment = ["CODEX_HOME": home.path]
        configuration.allowsRunningApplicationSubstitution = false
        NSWorkspace.shared.openApplication(at: application, configuration: configuration) { app, error in
            DispatchQueue.main.async {
                guard self.launchRequest == id else { return }
                if error != nil || app == nil {
                    self.finishLaunch(error: "Codex 启动失败，请检查应用安装后重试；接入配置与备份已保留。")
                } else {
                    self.finishLaunch(error: nil)
                    self.showStatus("已按当前接入配置打开 Codex", symbol: "checkmark.circle")
                }
            }
        }
    }

    private func finishLaunch(error: String?) {
        launchRequest = nil
        launchError = error
        refreshControls()
        if let error {
            showStatus(error, symbol: "exclamationmark.circle")
            showWindow()
        }
    }

    private func show(_ status: ContinuityStatus) {
        if let launchError {
            showStatus(launchError + "\n" + status.message, symbol: "exclamationmark.circle")
            return
        }
        let symbol: String
        switch status.phase {
        case .ready, .updated: symbol = "checkmark.circle"
        case .waiting: symbol = "clock"
        case .blocked: symbol = "exclamationmark.circle"
        }
        showStatus(status.message, symbol: symbol)
    }

    private func showStatus(_ text: String, symbol: String) {
        statusLabel.stringValue = text
        statusMenuItem.title = text.count > 38 ? String(text.prefix(38)) + "…" : text
        statusMenuItem.toolTip = text
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
        statusItem.button?.toolTip = "Miruun · " + text
    }

    private func refreshLoginState() {
        let state = SMAppService.mainApp.status
        loginButton.state = state == .enabled || state == .requiresApproval ? .on : .off
        loginLabel.stringValue = state == .requiresApproval ? "请在系统设置 → 通用 → 登录项中允许 Miruun。" : ""
    }

    @objc private func toggleLogin() {
        do {
            if loginButton.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLoginState()
        } catch {
            refreshLoginState()
            loginLabel.stringValue = "登录项设置失败，请在系统设置中检查；当前守护不受影响。"
        }
    }

    @objc private func revealBackups() {
        if FileManager.default.fileExists(atPath: backupDirectory.path) {
            NSWorkspace.shared.open(backupDirectory)
        } else {
            showStatus("尚无配置备份 · 首次调整前自动保存", symbol: "info.circle")
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        launchRequest = nil
        worker.async {
            self.timer?.cancel(); self.timer = nil
            self.guardService = nil; self.pendingLaunch = nil
            DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}
