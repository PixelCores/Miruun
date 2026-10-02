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
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var enabledItem: NSMenuItem!
    private var statusMenuItem: NSMenuItem!
    private let homeField = NSTextField()
    private let enableButton = NSButton(checkboxWithTitle: "启用后台连续性守护", target: nil, action: nil)
    private let loginButton = NSButton(checkboxWithTitle: "登录 Mac 时启动 Miruun", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "未启用")
    private let loginLabel = NSTextField(wrappingLabelWithString: "")
    private var chooseButton: NSButton!
    private var transitioning = false
    private var enabled = false

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
        refreshLoginState()
        if preferences.bool(forKey: "continuityEnabled") { start() }
        else { showStatus("守护已暂停 · 现有配置保持原样", symbol: "pause.circle") }
        if !preferences.bool(forKey: "continuityOnboardingShown") {
            preferences.set(true, forKey: "continuityOnboardingShown")
            showWindow()
        }
    }

    private func makeMenu() {
        let mainMenu = NSMenu()
        let applicationItem = mainMenu.addItem(withTitle: "Miruun", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "Miruun")
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
        enabledItem = menu.addItem(withTitle: "启用后台守护", action: #selector(toggleEnabled), keyEquivalent: "")
        menu.addItem(withTitle: "查看配置备份…", action: #selector(revealBackups), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出 Miruun", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        menu.autoenablesItems = false
        statusMenuItem.isEnabled = false
        statusItem.menu = menu
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
        addText("一次启用，后台维护 Codex 的本地代理配置。适用于同一数据目录中由官方 openai 创建的全部对话，无须逐条选择。", to: root)
        addText("先在 CC Switch 配好 CLIProxyAPI 和代理 API key。Miruun 会读取认证类型、备份并调整连接配置；对话历史与登录凭据保持原样。", to: root)

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
        loginLabel.font = .systemFont(ofSize: 11)
        loginLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(loginLabel)
        statusLabel.isSelectable = true
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        root.addArrangedSubview(statusLabel)
        statusLabel.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48).isActive = true
        addText("切换后等待配置就绪，再重启 Codex。上下文、原模型与代理账号是否兼容，需要在 GUI 中实际续聊核对。关闭此窗口后守护继续运行。", to: root)
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
        UserDefaults.standard.set(true, forKey: "continuityEnabled")
        UserDefaults.standard.set(homeField.stringValue, forKey: "continuityHome")
        refreshControls()
        showStatus("正在等待稳定的代理配置…", symbol: "arrow.triangle.2.circlepath")
        let home = URL(fileURLWithPath: homeField.stringValue, isDirectory: true)
        let backups = backupDirectory
        worker.async { [self] in
            let guardService = ContinuityGuard(home: home, backupDirectory: backups)
            let timer = DispatchSource.makeTimerSource(queue: self.worker)
            timer.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(300))
            timer.setEventHandler { [weak self] in
                let status = guardService.check()
                DispatchQueue.main.async { [weak self] in self?.show(status) }
            }
            self.timer = timer
            timer.resume()
        }
    }

    private func stop() {
        transitioning = true
        refreshControls()
        worker.async {
            self.timer?.cancel(); self.timer = nil
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
    }

    private func show(_ status: ContinuityStatus) {
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
        worker.async {
            self.timer?.cancel(); self.timer = nil
            DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}
