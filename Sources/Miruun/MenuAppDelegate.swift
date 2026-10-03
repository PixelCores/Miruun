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
    private var navigation: [NSButton] = []
    private var overviewViews: [NSView] = []
    private var settingsViews: [NSView] = []
    private var statusViews: [NSView] = []
    private let sectionLabel = NSTextField(labelWithString: "CODEX CONTINUITY")
    private let guardState = NSTextField(labelWithString: "暂停")
    private let launchState = NSTextField(labelWithString: "打开")
    private let autoState = NSTextField(labelWithString: "关闭")
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
        statusItem.button?.image = MenuPanelView.orbitImage()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleWindow)
    }

    private func makeWindow() {
        window = MenuPanel(contentRect: NSRect(x: 0, y: 0, width: 332, height: 379),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "Miruun · 对话连续性"
        window.isReleasedWhenClosed = false
        window.onDismiss = { [weak self] in self?.hideWindow() }
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.appearance = NSAppearance(named: .darkAqua)
        panelView = MenuPanelView(frame: NSRect(x: 0, y: 0, width: 332, height: 379))
        window.contentView = panelView

        let tools: [(String, Selector)] = [
            ("暂停或启用守护", #selector(toggleEnabled)),
            ("概览", #selector(showOverview)),
            ("完整连接状态", #selector(showConnectionStatus)),
            ("打开 Codex", #selector(openCodex)),
            ("查看配置备份", #selector(revealBackups)),
            ("切换自动打开 Codex", #selector(toggleAutoOpenFromToolbar)),
            ("设置", #selector(showSettings)),
            ("切换登录 Mac 时启动 Miruun", #selector(toggleLoginFromToolbar))
        ]
        for (index, tool) in tools.enumerated() {
            let button = NSButton(frame: NSRect(x: 16.5 + CGFloat(index) * 37.7, y: 81, width: 35, height: 30))
            button.isBordered = false
            // The canvas paints these icons at the reference image positions.
            button.title = ""
            button.toolTip = tool.0
            button.setAccessibilityLabel(tool.0)
            button.target = self
            button.action = tool.1
            panelView.addSubview(button)
            navigation.append(button)
        }
        sectionLabel.frame = NSRect(x: 12, y: 129, width: 308, height: 16)
        sectionLabel.font = .systemFont(ofSize: 10, weight: .bold)
        sectionLabel.textColor = MenuPanelView.color(0x949494)
        panelView.addSubview(sectionLabel)

        for (index, name) in ["Miruun", "Codex", "自动打开"].enumerated() {
            let label = makeLabel(name, frame: NSRect(x: 64, y: 164 + CGFloat(index) * 52, width: 126, height: 18), size: 12, weight: .semibold)
            panelView.addSubview(label)
            overviewViews.append(label)
        }
        configurePopup(enableButton, titles: [("已启用", 1), ("已暂停", 0)],
                       frame: NSRect(x: 198, y: 159, width: 112, height: 20), action: #selector(changeGuardMode))
        enableButton.setAccessibilityLabel("后台连续性守护")
        styleButton(openButton, frame: NSRect(x: 198, y: 211, width: 112, height: 20))
        openButton.target = self
        openButton.action = #selector(openCodex)
        configurePopup(autoOpenButton, titles: [("已开启", 1), ("已关闭", 0)],
                       frame: NSRect(x: 198, y: 263, width: 112, height: 20), action: #selector(toggleAutoOpen))
        autoOpenButton.setAccessibilityLabel("打开 Miruun 时自动打开 Codex")
        for button in [enableButton as NSButton, openButton, autoOpenButton as NSButton] {
            panelView.addSubview(button)
            overviewViews.append(button)
        }
        for (index, label) in [guardState, launchState, autoState].enumerated() {
            label.frame = NSRect(x: 235, y: 186 + CGFloat(index) * 52, width: 39, height: 15)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.alignment = .right
            label.textColor = MenuPanelView.color(0xA5A5A5)
            panelView.addSubview(label)
            overviewViews.append(label)
            let detail = NSButton(frame: NSRect(x: 279, y: 185 + CGFloat(index) * 52, width: 14, height: 15))
            detail.isBordered = false
            detail.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "查看连接状态")?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            detail.imagePosition = .imageOnly
            detail.contentTintColor = MenuPanelView.color(0xA5A5A5)
            detail.toolTip = "查看完整连接状态"
            detail.target = self
            detail.action = #selector(showConnectionStatus)
            panelView.addSubview(detail)
            overviewViews.append(detail)
            let indicator = NSImageView(frame: NSRect(x: 302, y: 186 + CGFloat(index) * 52, width: 11, height: 13))
            indicator.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "设置状态")?
                .withSymbolConfiguration(.init(pointSize: 5, weight: .medium))
            indicator.contentTintColor = MenuPanelView.color(0x8F8F8F)
            panelView.addSubview(indicator)
            overviewViews.append(indicator)
        }

        let homeTitle = makeLabel("CODEX HOME", frame: NSRect(x: 25, y: 160, width: 282, height: 13), size: 9, weight: .semibold)
        homeTitle.textColor = MenuPanelView.color(0x949494)
        homeField.frame = NSRect(x: 25, y: 178, width: 282, height: 18)
        homeField.isEditable = false
        homeField.isSelectable = true
        homeField.isBordered = false
        homeField.drawsBackground = false
        homeField.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        homeField.textColor = MenuPanelView.color(0xE9E9E9)
        homeField.lineBreakMode = .byTruncatingMiddle
        chooseButton = NSButton(title: "选择目录…", target: self, action: #selector(chooseHome))
        styleButton(chooseButton, frame: NSRect(x: 25, y: 204, width: 104, height: 22))
        let backupsButton = NSButton(title: "配置备份…", target: self, action: #selector(revealBackups))
        styleButton(backupsButton, frame: NSRect(x: 139, y: 204, width: 116, height: 22))
        loginButton.frame = NSRect(x: 25, y: 237, width: 282, height: 22)
        loginButton.font = .systemFont(ofSize: 11, weight: .medium)
        loginButton.setAccessibilityLabel(loginButton.title)
        loginButton.title = ""
        loginButton.contentTintColor = MenuPanelView.color(0xE9E9E9)
        loginButton.target = self
        loginButton.action = #selector(toggleLogin)
        loginLabel.frame = NSRect(x: 25, y: 267, width: 282, height: 39)
        loginLabel.font = .systemFont(ofSize: 10)
        loginLabel.textColor = MenuPanelView.color(0xA5A5A5)
        settingsViews = [homeTitle, homeField, chooseButton, backupsButton, loginButton, loginLabel]
        for view in settingsViews { panelView.addSubview(view) }

        statusScroll.frame = NSRect(x: 25, y: 163, width: 282, height: 137)
        statusScroll.drawsBackground = false
        statusScroll.hasVerticalScroller = true
        statusScroll.autohidesScrollers = true
        statusLabel.isSelectable = true
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = MenuPanelView.color(0xE9E9E9)
        statusLabel.frame = NSRect(x: 0, y: 0, width: 282, height: 137)
        statusLabel.preferredMaxLayoutWidth = 282
        statusScroll.documentView = statusLabel
        panelView.addSubview(statusScroll)
        statusViews = [statusScroll]

        settingsButton.frame = NSRect(x: 12, y: 332, width: 150, height: 28)
        settingsButton.target = self
        settingsButton.action = #selector(toggleSettings)
        configureFooter(settingsButton, label: "设置")
        let quitButton = NSButton(title: "退出", target: self, action: #selector(quit))
        quitButton.frame = NSRect(x: 170, y: 332, width: 150, height: 28)
        configureFooter(quitButton, label: "退出")
        panelView.addSubview(settingsButton)
        panelView.addSubview(quitButton)
        setPage(1)
        refreshControls()
    }

    private func makeLabel(_ text: String, frame: NSRect, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.frame = frame
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = MenuPanelView.color(0xE9E9E9)
        return label
    }

    private func styleButton(_ button: NSButton, frame: NSRect) {
        button.frame = frame
        button.isBordered = false
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.contentTintColor = MenuPanelView.color(0xE9E9E9)
        button.wantsLayer = true
        button.layer?.backgroundColor = MenuPanelView.color(0x434343).cgColor
        button.layer?.cornerRadius = 5
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

    private func setPage(_ index: Int) {
        panelView.selectedIndex = index
        panelView.showsSettings = index != 1
        for view in overviewViews { view.isHidden = index != 1 }
        for view in settingsViews { view.isHidden = index != 6 }
        for view in statusViews { view.isHidden = index != 2 }
        sectionLabel.stringValue = index == 1 ? "CODEX CONTINUITY" : index == 2 ? "CONNECTION STATUS" : "SETTINGS"
        configureFooter(settingsButton, label: index == 1 ? "设置" : "返回")
        for (position, button) in navigation.enumerated() {
            button.contentTintColor = MenuPanelView.color(position == index ? 0x007AFF : 0x8F8F8F)
        }
    }

    @objc private func showOverview() { setPage(1); showWindow() }
    @objc private func showSettings() { setPage(6); showWindow() }
    @objc private func showConnectionStatus() { setPage(2); showWindow() }
    @objc private func toggleSettings() { if panelView.selectedIndex == 1 { showSettings() } else { showOverview() } }

    @objc private func changeGuardMode() {
        if (enableButton.selectedTag() == 1) != enabled { toggleEnabled() }
    }

    @objc private func toggleAutoOpenFromToolbar() {
        autoOpenButton.selectItem(withTag: autoOpenButton.selectedTag() == 1 ? 0 : 1)
        toggleAutoOpen()
    }

    @objc private func toggleLoginFromToolbar() {
        loginButton.state = loginButton.state == .on ? .off : .on
        toggleLogin()
        showSettings()
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
        let x = min(max(anchor.midX - 166, visible.minX), visible.maxX - 332)
        let y = max(visible.minY, min(anchor.minY - 379, visible.maxY - 379))
        panelView.arrowX = min(max(anchor.midX - x, 24), 308)
        window.setFrame(NSRect(x: x, y: y, width: 332, height: 379), display: true)
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
        navigation[0].isEnabled = !transitioning
        navigation[3].isEnabled = openButton.isEnabled
        navigation[3].alphaValue = openButton.isEnabled ? 1 : 0.45
        openButton.title = launchRequest == nil ? "打开 Codex" : "准备中…"
        openButton.alphaValue = openButton.isEnabled ? 1 : 0.55
        panelView.active = [enabled, launchRequest != nil, autoOpenButton.selectedTag() == 1]
        panelView.waiting = launchRequest != nil
        launchState.stringValue = launchRequest == nil ? "打开" : "等待"
        autoState.stringValue = autoOpenButton.selectedTag() == 1 ? "开启" : "关闭"
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
            let height = statusLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 282, height: 10_000)).height ?? 137
            statusLabel.setFrameSize(NSSize(width: 282, height: max(137, height)))
            statusScroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, height - 137)))
            statusScroll.reflectScrolledClipView(statusScroll.contentView)
        }
        statusLabel.toolTip = text
        guardState.toolTip = text
        sectionLabel.toolTip = text
        navigation[2].toolTip = text
        let blocked = symbol == "exclamationmark.circle"
        panelView.blocked = blocked
        panelView.waiting = launchRequest != nil || symbol == "clock"
        switch symbol {
        case "checkmark.circle": guardState.stringValue = "就绪"
        case "clock": guardState.stringValue = "等待"
        case "arrow.triangle.2.circlepath": guardState.stringValue = "检查"
        case "pause.circle": guardState.stringValue = "暂停"
        case "exclamationmark.circle": guardState.stringValue = "需处理"
        default: guardState.stringValue = "查看"
        }
        guardState.textColor = MenuPanelView.color(blocked ? 0xFF9E33 : 0xA5A5A5)
        launchState.textColor = MenuPanelView.color(panelView.waiting || blocked ? 0xFF9E33 : 0xA5A5A5)
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
