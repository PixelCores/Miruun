import AppKit
import ServiceManagement
import BridgeEngine

/// UI state stays on the main queue. All configuration access is serialized on
/// worker; stopping waits for any in-progress atomic update before returning.
final class MenuAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let worker = DispatchQueue(label: "io.github.pixelcores.miruun.continuity", qos: .utility)
    private var timer: DispatchSourceTimer? // worker queue only
    private var guardService: ContinuityGuard? // worker queue only
    private var pendingLaunch: (id: UUID, application: URL, home: URL)? // worker queue only
    private var statusItem: NSStatusItem!
    private var window: MenuPanel!
    private var panelView: MenuPanelView!
    private var openItems: [NSMenuItem] = []
    private let homeField = NSTextField()
    private let enableButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let loginButton = NSButton(checkboxWithTitle: "登录 Mac 时启动 Miruun", target: nil, action: nil)
    private let autoOpenButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let openButton = NSButton(title: "打开 Codex", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "未启用")
    private let loginLabel = NSTextField(wrappingLabelWithString: "")
    private var chooseButton: NSButton!
    private var overviewViews: [NSView] = []
    private var settingsViews: [NSView] = []
    private var statusViews: [NSView] = []
    private let sectionLabel = NSTextField(labelWithString: "Miruun")
    private let statusButton = NSButton(title: "查看连接状态", target: nil, action: nil)
    private let settingsButton = NSButton(title: "设置", target: nil, action: nil)
    private let statusScroll = NSScrollView()
    private var isChoosingHome = false
    private var isMenuTracking = false
    private var mouseMonitor: Any?
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
        autoOpenButton.selectItem(withTag: preferences.bool(forKey: "autoOpenCodex") ? 1 : 0)
        homeField.toolTip = homeField.stringValue
        refreshLoginState()
        refreshControls()
        if preferences.bool(forKey: "continuityEnabled") { start() }
        else { showStatus("守护已暂停 · 现有配置保持原样", symbol: "pause.circle") }
        // Manual launches must remain discoverable even after the first run.
        // Only a system login launch should start without a settings window.
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let launchedAtLogin = launchEvent?.eventID == kAEOpenApplication
            && launchEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !launchedAtLogin {
            if enabled && autoOpenButton.selectedTag() == 1 { openCodex() }
            else { showWindow() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if window != nil {
            if enabled && autoOpenButton.selectedTag() == 1 { openCodex() }
            else { showWindow() }
        }
        return true
    }

    private func makeMenu() {
        let mainMenu = NSMenu()
        let applicationItem = mainMenu.addItem(withTitle: "Miruun", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "Miruun")
        let settingsItem = applicationMenu.addItem(withTitle: "设置与状态…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        let openItem = applicationMenu.addItem(withTitle: "打开 Codex", action: #selector(openCodex), keyEquivalent: "")
        openItem.target = self
        openItems.append(openItem)
        applicationMenu.addItem(.separator())
        let quitItem = applicationMenu.addItem(withTitle: "退出 Miruun", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        applicationItem.submenu = applicationMenu
        applicationMenu.autoenablesItems = false
        NSApp.mainMenu = mainMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuPanelView.moonImage()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleWindow)
    }

    private func makeWindow() {
        let frame = NSRect(origin: .zero, size: MenuPanelView.contentSize)
        window = MenuPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "Miruun · 对话连续性"
        window.isReleasedWhenClosed = false
        window.onDismiss = { [weak self] in self?.hideWindow() }
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.appearance = NSAppearance(named: .darkAqua)
        let materialView = NSVisualEffectView(frame: frame)
        panelView = MenuPanelView(frame: frame)
        panelView.installMaterial(materialView)
        materialView.addSubview(panelView)
        window.contentView = materialView

        sectionLabel.frame = NSRect(x: 61, y: 25, width: 255, height: 24)
        sectionLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        sectionLabel.textColor = MenuPanelView.color(0xF4F7FA)
        panelView.addSubview(sectionLabel)
        panelView.addSubview(makeLabel("Codex 对话连续性", frame: NSRect(x: 61, y: 50, width: 255, height: 14), size: 10, weight: .regular))

        statusButton.frame = NSRect(x: 26, y: 79, width: 280, height: 20)
        statusButton.isBordered = false
        statusButton.font = .systemFont(ofSize: 11, weight: .medium)
        statusButton.alignment = .left
        statusButton.imagePosition = .imageLeft
        statusButton.setAccessibilityLabel("查看完整连接状态")
        statusButton.target = self
        statusButton.action = #selector(showConnectionStatus)
        panelView.addSubview(statusButton)
        overviewViews.append(statusButton)

        for (index, row) in [("连续性守护", "根据当前配置准备接入"), ("自动打开 Codex", "打开 Miruun 时自动启动")].enumerated() {
            let offset = CGFloat(index) * 60
            let title = makeLabel(row.0, frame: NSRect(x: 30, y: 127 + offset, width: 178, height: 19), size: 12, weight: .semibold)
            title.textColor = MenuPanelView.color(0xF4F7FA)
            let caption = makeLabel(row.1, frame: NSRect(x: 30, y: 149 + offset, width: 178, height: 14), size: 10, weight: .regular)
            for label in [title, caption] {
                panelView.addSubview(label)
                overviewViews.append(label)
            }
        }
        configurePopup(enableButton, titles: [("已启用", 1), ("已暂停", 0)],
                       frame: NSRect(x: 218, y: 133, width: 84, height: 28), action: #selector(changeGuardMode))
        enableButton.setAccessibilityLabel("后台连续性守护")
        configurePopup(autoOpenButton, titles: [("已开启", 1), ("已关闭", 0)],
                       frame: NSRect(x: 218, y: 193, width: 84, height: 28), action: #selector(toggleAutoOpen))
        autoOpenButton.setAccessibilityLabel("打开 Miruun 时自动打开 Codex")
        styleButton(openButton, frame: NSRect(x: 16, y: 248, width: 300, height: 38))
        openButton.font = .systemFont(ofSize: 13, weight: .semibold)
        openButton.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.72).cgColor
        openButton.layer?.cornerRadius = 10
        openButton.target = self
        openButton.action = #selector(openCodex)
        for button in [enableButton as NSButton, autoOpenButton as NSButton, openButton] {
            panelView.addSubview(button)
            overviewViews.append(button)
        }

        let homeTitle = makeLabel("CODEX HOME", frame: NSRect(x: 30, y: 101, width: 272, height: 14), size: 9, weight: .semibold)
        homeField.frame = NSRect(x: 30, y: 121, width: 272, height: 20)
        homeField.isEditable = false
        homeField.isSelectable = true
        homeField.isBordered = false
        homeField.drawsBackground = false
        homeField.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        homeField.textColor = MenuPanelView.color(0xF4F7FA)
        homeField.lineBreakMode = .byTruncatingMiddle
        chooseButton = NSButton(title: "选择目录…", target: self, action: #selector(chooseHome))
        styleButton(chooseButton, frame: NSRect(x: 30, y: 154, width: 126, height: 28))
        let backupsButton = NSButton(title: "配置备份…", target: self, action: #selector(revealBackups))
        styleButton(backupsButton, frame: NSRect(x: 168, y: 154, width: 134, height: 28))
        loginButton.frame = NSRect(x: 30, y: 198, width: 272, height: 22)
        loginButton.font = .systemFont(ofSize: 11, weight: .medium)
        loginButton.setAccessibilityLabel(loginButton.title)
        loginButton.title = ""
        loginButton.contentTintColor = MenuPanelView.color(0xF4F7FA)
        loginButton.target = self
        loginButton.action = #selector(toggleLogin)
        loginLabel.frame = NSRect(x: 30, y: 235, width: 272, height: 39)
        loginLabel.font = .systemFont(ofSize: 10)
        loginLabel.textColor = MenuPanelView.color(0xC9D2DD)
        settingsViews = [homeTitle, homeField, chooseButton, backupsButton, loginButton, loginLabel]
        for view in settingsViews { panelView.addSubview(view) }

        statusScroll.frame = NSRect(x: 30, y: 101, width: 272, height: 170)
        statusScroll.drawsBackground = false
        statusScroll.hasVerticalScroller = true
        statusScroll.autohidesScrollers = true
        statusLabel.isSelectable = true
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = MenuPanelView.color(0xF4F7FA)
        statusLabel.frame = NSRect(x: 0, y: 0, width: 272, height: 170)
        statusLabel.preferredMaxLayoutWidth = 272
        statusScroll.documentView = statusLabel
        panelView.addSubview(statusScroll)
        statusViews = [statusScroll]

        settingsButton.frame = NSRect(x: 16, y: 304, width: 144, height: 30)
        settingsButton.target = self
        settingsButton.action = #selector(toggleSettings)
        configureFooter(settingsButton, label: "设置")
        let quitButton = NSButton(title: "退出", target: self, action: #selector(quit))
        quitButton.frame = NSRect(x: 172, y: 304, width: 144, height: 30)
        configureFooter(quitButton, label: "退出")
        panelView.addSubview(settingsButton)
        panelView.addSubview(quitButton)
        setPage(0)
        refreshControls()
    }

    private func makeLabel(_ text: String, frame: NSRect, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.frame = frame
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = MenuPanelView.color(0xC9D2DD)
        return label
    }

    private func styleButton(_ button: NSButton, frame: NSRect) {
        button.frame = frame
        button.isBordered = false
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.contentTintColor = MenuPanelView.color(0xF4F7FA)
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        button.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        button.layer?.borderWidth = 0.5
        button.layer?.cornerRadius = 7
    }

    private func configurePopup(_ button: NSPopUpButton, titles: [(String, Int)], frame: NSRect, action: Selector) {
        for (title, tag) in titles {
            button.addItem(withTitle: title)
            button.lastItem?.tag = tag
        }
        styleButton(button, frame: frame)
        button.target = self
        button.action = action
        button.menu?.delegate = self
    }

    private func configureFooter(_ button: NSButton, label: String) {
        // The canvas centers each symbol and label as one group.
        button.isBordered = false
        button.title = ""
        button.image = nil
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }

    private func setPage(_ page: Int) {
        panelView.page = page
        for view in overviewViews { view.isHidden = page != 0 }
        for view in settingsViews { view.isHidden = page != 1 }
        for view in statusViews { view.isHidden = page != 2 }
        sectionLabel.stringValue = page == 0 ? "Miruun" : page == 1 ? "设置" : "连接状态"
        configureFooter(settingsButton, label: page == 0 ? "设置" : "返回")
    }

    @objc private func showOverview() { setPage(0); showWindow() }
    @objc private func showSettings() { setPage(1); showWindow() }
    @objc private func showConnectionStatus() { setPage(2); showWindow() }
    @objc private func toggleSettings() { if panelView.page == 0 { showSettings() } else { showOverview() } }

    @objc private func changeGuardMode() {
        if (enableButton.selectedTag() == 1) != enabled { toggleEnabled() }
    }

    private var backupDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Miruun/ConfigBackups", isDirectory: true)
    }

    @objc private func toggleWindow() {
        if window.isVisible { hideWindow() } else { showWindow() }
    }

    @objc private func showWindow() {
        guard let button = statusItem.button, let anchorWindow = button.window,
              let screen = anchorWindow.screen else { return }
        let anchor = anchorWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        let size = MenuPanelView.contentSize
        let x = min(max(anchor.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let y = max(visible.minY, min(anchor.minY - size.height, visible.maxY - size.height))
        panelView.arrowX = min(max(anchor.midX - x, 24), size.width - 24)
        window.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                guard let self, self.window.isVisible, !self.isChoosingHome, !self.isMenuTracking else { return }
                let location = NSEvent.mouseLocation
                if self.window.frame.contains(location) { return }
                if let button = self.statusItem.button, let anchorWindow = button.window,
                   anchorWindow.convertToScreen(button.convert(button.bounds, to: nil)).contains(location) { return }
                self.hideWindow()
            }
        }
    }

    private func hideWindow() {
        window?.orderOut(nil)
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
    }

    func menuWillOpen(_ menu: NSMenu) { isMenuTracking = true }
    func menuDidClose(_ menu: NSMenu) { isMenuTracking = false }

    func applicationDidResignActive(_ notification: Notification) {
        if !isChoosingHome && !isMenuTracking { hideWindow() }
    }

    @objc private func chooseHome() {
        guard !enabled, !transitioning else { return }
        isChoosingHome = true
        defer { isChoosingHome = false; showWindow() }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = false; panel.allowsMultipleSelection = false
        panel.title = "选择 Codex 使用的 CODEX_HOME"
        if panel.runModal() == .OK, let url = panel.url {
            homeField.stringValue = url.path
            homeField.toolTip = url.path
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
        enableButton.selectItem(withTag: enabled ? 1 : 0)
        enableButton.isEnabled = !transitioning
        chooseButton.isEnabled = !enabled && !transitioning
        openButton.isEnabled = enabled && !transitioning && launchRequest == nil
        for item in openItems { item.isEnabled = openButton.isEnabled }
        openButton.title = launchRequest == nil ? "打开 Codex" : "准备中…"
        openButton.alphaValue = openButton.isEnabled ? 1 : 0.55
    }

    @objc private func toggleAutoOpen() {
        UserDefaults.standard.set(autoOpenButton.selectedTag() == 1, forKey: "autoOpenCodex")
        refreshControls()
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
            showConnectionStatus()
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
        if statusLabel.stringValue != text {
            statusLabel.stringValue = text
            let height = statusLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 272, height: 10_000)).height ?? 170
            statusLabel.setFrameSize(NSSize(width: 272, height: max(170, height)))
            statusScroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, height - 170)))
            statusScroll.reflectScrolledClipView(statusScroll.contentView)
        }
        statusLabel.toolTip = text
        statusButton.toolTip = text
        switch symbol {
        case "checkmark.circle": statusButton.title = "配置已就绪 · 查看状态"
        case "clock": statusButton.title = "正在等待 · 查看状态"
        case "arrow.triangle.2.circlepath": statusButton.title = "正在检查 · 查看状态"
        case "pause.circle": statusButton.title = "守护已暂停 · 查看状态"
        case "exclamationmark.circle": statusButton.title = "需要处理 · 查看状态"
        default: statusButton.title = "查看连接状态"
        }
        statusButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        statusButton.contentTintColor = symbol == "exclamationmark.circle" ? .systemOrange : MenuPanelView.color(0xC9D2DD)
        statusItem.button?.toolTip = "Miruun · " + text
    }

    private func refreshLoginState() {
        let state = SMAppService.mainApp.status
        loginButton.state = state == .enabled || state == .requiresApproval ? .on : .off
        loginLabel.stringValue = state == .requiresApproval ? "请在系统设置 → 通用 → 登录项中允许 Miruun。" : "登录 Mac 时仅启动守护，Codex 不会自动打开。"
        loginLabel.toolTip = loginLabel.stringValue
    }

    @objc private func toggleLogin() {
        do {
            if loginButton.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLoginState()
        } catch {
            refreshLoginState()
            loginLabel.stringValue = "登录项设置失败，请在系统设置中检查；当前守护不受影响。"
            loginLabel.toolTip = loginLabel.stringValue
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
        hideWindow()
        worker.async {
            self.timer?.cancel(); self.timer = nil
            self.guardService = nil; self.pendingLaunch = nil
            DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}
