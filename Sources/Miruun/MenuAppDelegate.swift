import AppKit
import ServiceManagement
import BridgeEngine

/// UI state stays on the main queue. All configuration access is serialized on
/// worker; stopping waits for any in-progress atomic update before returning.
final class MenuAppDelegate: NSObject, NSApplicationDelegate {
    private let worker = DispatchQueue(label: "io.github.pixelcores.miruun.continuity", qos: .utility)
    private let historyWorker = DispatchQueue(label: "io.github.pixelcores.miruun.history", qos: .utility)
    private var historyTimer: Timer? // main queue only; file work uses historyWorker
    private var historyBusy = false
    private var historyError: String?
    private var historySnapshots: [CodexHistoryBackup.Snapshot] = []
    private let historyButton = NSButton(title: "查看备份与版本", target: nil, action: nil)
    private let historyToggle = NSSwitch(frame: .zero)
    private let historyPageToggle = NSSwitch(frame: .zero)
    private let historyInterval = NSPopUpButton(frame: .zero, pullsDown: false)
    private let historyVersions = NSPopUpButton(frame: .zero, pullsDown: false)
    private let historyNow = NSButton(title: "立即备份", target: nil, action: nil)
    private let historyExport = NSButton(title: "导出所选版本…", target: nil, action: nil)
    private let historyStatus = NSTextField(wrappingLabelWithString: "尚未备份")
    private var historyViews: [NSView] = []
    private var timer: DispatchSourceTimer? // worker queue only
    private var guardService: ContinuityGuard? // worker queue only
    private var pendingLaunch: (id: UUID, application: URL, home: URL)? // worker queue only
    private var statusItem: NSStatusItem!
    private var window: MenuPanel!
    private var panelView: MenuPanelView!
    private var openItems: [NSMenuItem] = []
    private let homeField = NSTextField()
    private let claudeHomeField = NSTextField()
    private let homeTitle = NSTextField(labelWithString: "CODEX")
    private let discoverButton = NSButton(title: "自动查找", target: nil, action: nil)
    private var selectedHome: URL?
    private var isDiscovering = false
    private let enableButton = NSSwitch(frame: .zero)
    private let loginButton = NSButton(checkboxWithTitle: "登录 Mac 时启动 Miruun", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "未启用")
    private let loginLabel = NSTextField(wrappingLabelWithString: "")
    private var chooseButton: NSButton!
    private var overviewViews: [NSView] = []
    private var settingsViews: [NSView] = []
    private var statusViews: [NSView] = []
    private let sectionLabel = NSTextField(labelWithString: "Miruun")
    private let statusButton = NSButton(title: "查看连接状态", target: nil, action: nil)
    private let settingsButton = NSButton(title: "设置", target: nil, action: nil)
    private let quitButton = NSButton(title: "退出", target: nil, action: nil)
    private let statusScroll = NSScrollView()
    private var isChoosingHome = false
    private var mouseMonitor: Any?
    private var transitioning = false
    private var terminating = false
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
        let defaultHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        // Older releases saved the default on every start; only a non-default
        // legacy path should migrate as an explicit choice.
        if preferences.object(forKey: "continuityHomeIsCustom") == nil {
            let previous = preferences.string(forKey: "continuityHome")
            preferences.set(previous != nil && previous != defaultHome, forKey: "continuityHomeIsCustom")
        }
        preferences.removeObject(forKey: "autoOpenCodex")
        refreshLoginState()
        discoverDirectories(resumeGuard: preferences.bool(forKey: "continuityEnabled"))
        // Manual launches must remain discoverable even after the first run.
        // Only a system login launch should start without a settings window.
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let launchedAtLogin = launchEvent?.eventID == kAEOpenApplication
            && launchEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !launchedAtLogin { showWindow() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if window != nil { showWindow() }
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
        let historyItem = applicationMenu.addItem(withTitle: "聊天与记忆备份…", action: #selector(showHistoryBackups), keyEquivalent: "")
        historyItem.target = self
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
        let frame = NSRect(origin: .zero, size: MenuPanelView.contentSize(for: 0))
        window = MenuPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "Miruun"
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

        sectionLabel.frame = NSRect(x: 61, y: 29, width: 255, height: 24)
        sectionLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        sectionLabel.textColor = MenuPanelView.color(0xF4F7FA)
        panelView.addSubview(sectionLabel)

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

        let guardTitle = makeLabel("连续性守护", frame: NSRect(x: 30, y: 135, width: 190, height: 19), size: 12, weight: .semibold)
        guardTitle.textColor = MenuPanelView.color(0xF4F7FA)
        let guardCaption = makeLabel("根据当前配置准备接入", frame: NSRect(x: 30, y: 161, width: 190, height: 14), size: 10, weight: .regular)
        for label in [guardTitle, guardCaption] {
            panelView.addSubview(label)
            overviewViews.append(label)
        }
        enableButton.frame = NSRect(x: 252, y: 140, width: 42, height: 26)
        enableButton.target = self
        enableButton.action = #selector(changeGuardMode)
        enableButton.setAccessibilityLabel("连续性守护")
        panelView.addSubview(enableButton)
        overviewViews.append(enableButton)

        let backupTitle = makeLabel("聊天与记忆备份", frame: NSRect(x: 30, y: 221, width: 190, height: 19), size: 12, weight: .semibold)
        backupTitle.textColor = MenuPanelView.color(0xF4F7FA)
        let backupCaption = makeLabel("定时保存本地历史版本", frame: NSRect(x: 30, y: 247, width: 190, height: 14), size: 10, weight: .regular)
        for label in [backupTitle, backupCaption] { panelView.addSubview(label); overviewViews.append(label) }
        historyToggle.frame = NSRect(x: 252, y: 226, width: 42, height: 26)
        historyToggle.target = self
        historyToggle.action = #selector(toggleHistoryBackups(_:))
        historyToggle.setAccessibilityLabel("定时备份聊天与记忆")
        panelView.addSubview(historyToggle)
        overviewViews.append(historyToggle)

        historyButton.frame = NSRect(x: 26, y: 290, width: 280, height: 20)
        historyButton.isBordered = false
        historyButton.font = .systemFont(ofSize: 11, weight: .medium)
        historyButton.alignment = .left
        historyButton.contentTintColor = MenuPanelView.color(0xC9D2DD)
        historyButton.target = self
        historyButton.action = #selector(showHistoryBackups)
        historyButton.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        panelView.addSubview(historyButton)
        overviewViews.append(historyButton)

        homeTitle.frame = NSRect(x: 30, y: 91, width: 190, height: 14)
        homeTitle.font = .systemFont(ofSize: 9, weight: .semibold)
        homeTitle.textColor = MenuPanelView.color(0xC9D2DD)
        styleButton(discoverButton, frame: NSRect(x: 230, y: 86, width: 72, height: 23))
        discoverButton.font = .systemFont(ofSize: 10, weight: .medium)
        discoverButton.target = self
        discoverButton.action = #selector(rediscoverDirectories)
        discoverButton.toolTip = "暂停守护后，按当前配置自动查找目录。"
        configureDirectoryField(homeField, frame: NSRect(x: 30, y: 114, width: 272, height: 20))
        homeField.setAccessibilityLabel("Codex 配置目录")
        let claudeTitle = makeLabel("CLAUDE", frame: NSRect(x: 30, y: 142, width: 272, height: 14), size: 9, weight: .semibold)
        configureDirectoryField(claudeHomeField, frame: NSRect(x: 30, y: 163, width: 272, height: 20))
        claudeHomeField.setAccessibilityLabel("Claude 配置目录")
        chooseButton = NSButton(title: "选择 Codex 目录…", target: self, action: #selector(chooseHome))
        styleButton(chooseButton, frame: NSRect(x: 30, y: 196, width: 126, height: 28))
        let backupsButton = NSButton(title: "配置备份…", target: self, action: #selector(revealBackups))
        styleButton(backupsButton, frame: NSRect(x: 168, y: 196, width: 134, height: 28))
        loginButton.frame = NSRect(x: 30, y: 237, width: 272, height: 22)
        loginButton.font = .systemFont(ofSize: 11, weight: .medium)
        loginButton.setAccessibilityLabel(loginButton.title)
        loginButton.title = ""
        loginButton.contentTintColor = MenuPanelView.color(0xF4F7FA)
        loginButton.target = self
        loginButton.action = #selector(toggleLogin)
        loginLabel.frame = NSRect(x: 30, y: 267, width: 272, height: 22)
        loginLabel.font = .systemFont(ofSize: 10)
        loginLabel.textColor = MenuPanelView.color(0xC9D2DD)
        settingsViews = [homeTitle, discoverButton, homeField, claudeTitle, claudeHomeField, chooseButton, backupsButton, loginButton, loginLabel]
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

        makeHistoryControls()

        settingsButton.frame = NSRect(x: 16, y: 304, width: 144, height: 30)
        settingsButton.target = self
        settingsButton.action = #selector(toggleSettings)
        configureFooter(settingsButton, label: "设置")
        quitButton.target = self
        quitButton.action = #selector(quit)
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

    private func configureDirectoryField(_ field: NSTextField, frame: NSRect) {
        field.frame = frame
        field.isEditable = false
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        field.textColor = MenuPanelView.color(0xF4F7FA)
        field.lineBreakMode = .byTruncatingMiddle
        field.stringValue = "正在查找…"
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
        let footerY = MenuPanelView.contentSize(for: page).height - 46
        settingsButton.setFrameOrigin(NSPoint(x: 16, y: footerY))
        quitButton.setFrameOrigin(NSPoint(x: 172, y: footerY))
        for view in overviewViews { view.isHidden = page != 0 }
        for view in settingsViews { view.isHidden = page != 1 }
        for view in statusViews { view.isHidden = page != 2 }
        for view in historyViews { view.isHidden = page != 3 }
        sectionLabel.stringValue = page == 0 ? "Miruun" : page == 1 ? "设置" : page == 2 ? "连接状态" : "聊天与记忆备份"
        configureFooter(settingsButton, label: page == 0 ? "设置" : "返回")
    }

    @objc private func showOverview() { setPage(0); showWindow() }
    @objc private func showSettings() {
        setPage(1)
        showWindow()
        if !enabled { discoverDirectories() }
    }
    @objc private func showConnectionStatus() { setPage(2); showWindow() }
    @objc private func toggleSettings() { if panelView.page == 0 { showSettings() } else { showOverview() } }

    @objc private func changeGuardMode() {
        if (enableButton.state == .on) != enabled { toggleEnabled() }
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
        let size = MenuPanelView.contentSize(for: panelView.page)
        let x = min(max(anchor.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let y = max(visible.minY, min(anchor.minY - size.height, visible.maxY - size.height))
        panelView.arrowX = min(max(anchor.midX - x, 24), size.width - 24)
        window.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                guard let self, self.window.isVisible, !self.isChoosingHome else { return }
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

    func applicationDidResignActive(_ notification: Notification) {
        if !isChoosingHome { hideWindow() }
    }

    @objc private func chooseHome() {
        guard !enabled, !transitioning, !isDiscovering, !historyBusy else { return }
        isChoosingHome = true
        defer { isChoosingHome = false; showWindow() }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = false; panel.allowsMultipleSelection = false
        panel.title = "选择 Codex 使用的 CODEX_HOME"
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: "continuityHome")
            UserDefaults.standard.set(true, forKey: "continuityHomeIsCustom")
            discoverDirectories()
        }
    }

    @objc private func rediscoverDirectories() {
        guard !enabled, !transitioning, !isDiscovering, !historyBusy else { return }
        UserDefaults.standard.set(false, forKey: "continuityHomeIsCustom")
        discoverDirectories()
    }

    private func discoverDirectories(resumeGuard: Bool = false) {
        guard !enabled, !transitioning, !isDiscovering, !historyBusy else { return }
        isDiscovering = true
        historyTimer?.invalidate(); historyTimer = nil
        selectedHome = nil
        historySnapshots = []
        historyError = nil
        historyVersions.removeAllItems()
        homeField.stringValue = "正在查找…"
        claudeHomeField.stringValue = "正在查找…"
        refreshControls()
        showStatus("正在查找配置目录…", symbol: "arrow.triangle.2.circlepath")
        let preferences = UserDefaults.standard
        let manualHome = preferences.bool(forKey: "continuityHomeIsCustom")
            ? preferences.string(forKey: "continuityHome") : nil
        worker.async {
            do {
                let directories = try NativeDiscovery.configurationDirectories(codexOverride: manualHome)
                DispatchQueue.main.async {
                    guard !self.transitioning else { return }
                    self.isDiscovering = false
                    self.selectedHome = directories.codex.directory
                    self.homeTitle.stringValue = manualHome == nil ? "CODEX" : "CODEX · 手动选择"
                    self.homeField.stringValue = directories.codex.directory?.path ?? directories.codex.error ?? "未找到目录"
                    self.homeField.toolTip = self.homeField.stringValue + "\n来源：" + directories.codex.source
                    self.claudeHomeField.stringValue = directories.claude.directory?.path ?? directories.claude.error ?? "未找到目录"
                    self.claudeHomeField.toolTip = self.claudeHomeField.stringValue + "\n来源：" + directories.claude.source
                    self.refreshControls()
                    self.loadHistoryBackups()
                    if resumeGuard && self.selectedHome != nil { self.start() }
                    else if let error = directories.codex.error { self.showStatus(error, symbol: "exclamationmark.circle") }
                    else { self.showStatus("守护已暂停 · 配置目录已找到", symbol: "pause.circle") }
                }
            } catch {
                let message = (error as? NativeEngineError)?.message ?? "无法查找配置目录。"
                DispatchQueue.main.async {
                    guard !self.transitioning else { return }
                    self.isDiscovering = false
                    self.homeField.stringValue = "无法查找目录"
                    self.claudeHomeField.stringValue = "无法查找目录"
                    self.homeField.toolTip = message
                    self.claudeHomeField.toolTip = message
                    self.refreshControls()
                    self.showStatus(message, symbol: "exclamationmark.circle")
                }
            }
        }
    }

    @objc private func toggleEnabled() {
        guard !transitioning, !isDiscovering else { refreshControls(); return }
        if enabled { stop() } else { start() }
    }

    private func start() {
        guard Bundle.main.bundleIdentifier == "io.github.pixelcores.miruun" else {
            showStatus("请运行打包后的 Miruun.app", symbol: "exclamationmark.circle")
            return
        }
        guard let home = selectedHome else {
            refreshControls()
            showStatus("未找到 Codex 配置目录，请自动查找或手动选择。", symbol: "exclamationmark.circle")
            return
        }
        enabled = true
        launchError = nil
        UserDefaults.standard.set(true, forKey: "continuityEnabled")
        refreshControls()
        showStatus("正在等待稳定的代理配置…", symbol: "arrow.triangle.2.circlepath")
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
        enableButton.isEnabled = !transitioning && !isDiscovering && (enabled || selectedHome != nil)
        chooseButton.isEnabled = !enabled && !transitioning && !isDiscovering && !historyBusy
        discoverButton.isEnabled = chooseButton.isEnabled
        let canOpen = enabled && !transitioning && launchRequest == nil
        for item in openItems { item.isEnabled = canOpen }
        let canBackup = !transitioning && !isDiscovering && !historyBusy && selectedHome != nil
        historyNow.isEnabled = canBackup
        let automatic = UserDefaults.standard.bool(forKey: "historyBackupEnabled")
        historyToggle.state = automatic ? .on : .off
        historyPageToggle.state = historyToggle.state
        historyToggle.isEnabled = !terminating && !isDiscovering && selectedHome != nil
        historyPageToggle.isEnabled = historyToggle.isEnabled
        historyInterval.isEnabled = !terminating && !isDiscovering
        historyVersions.isEnabled = canBackup && !historySnapshots.isEmpty
        historyExport.isEnabled = canBackup && historyVersions.indexOfSelectedItem >= 0 && !historySnapshots.isEmpty

    }

    @objc private func openCodex() {
        guard enabled, !transitioning, launchRequest == nil, let home = selectedHome else { return }
        launchError = nil
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.codexIdentifier),
              Bundle(url: application)?.bundleIdentifier == Self.codexIdentifier else {
            finishLaunch(error: "未找到 Codex 应用，请先安装并正常打开一次。")
            return
        }
        let id = UUID()
        launchRequest = id
        refreshControls()
        showStatus("正在检查当前接入配置，准备完成后打开 Codex…", symbol: "clock")
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
        loginLabel.stringValue = state == .requiresApproval ? "请在系统设置 → 通用 → 登录项中允许 Miruun。" : "登录 Mac 时启动 Miruun 与已启用的备份。"
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

    private func makeHistoryControls() {
        let caption = makeLabel("所选 Codex 目录中的本地记录", frame: NSRect(x: 30, y: 88, width: 272, height: 18), size: 11, weight: .medium)
        let intervalLabel = makeLabel("定时备份", frame: NSRect(x: 30, y: 120, width: 95, height: 20), size: 12, weight: .medium)
        historyPageToggle.frame = NSRect(x: 252, y: 113, width: 42, height: 26)
        historyPageToggle.target = self
        historyPageToggle.action = #selector(toggleHistoryBackups(_:))
        historyPageToggle.setAccessibilityLabel("定时备份聊天与记忆")
        historyInterval.frame = NSRect(x: 26, y: 145, width: 280, height: 28)
        for (title, seconds) in [("每小时备份", 3600), ("每天备份", 86400)] {
            historyInterval.addItem(withTitle: title)
            historyInterval.lastItem?.tag = seconds
        }
        historyInterval.selectItem(withTag: UserDefaults.standard.integer(forKey: "historyBackupInterval"))
        if historyInterval.indexOfSelectedItem < 0 { historyInterval.selectItem(withTag: 3600) }
        historyInterval.target = self
        historyInterval.action = #selector(changeHistoryInterval)
        historyInterval.setAccessibilityLabel("聊天与记忆定时备份间隔")
        historyNow.target = self
        historyNow.action = #selector(backupHistoryNow)
        styleButton(historyNow, frame: NSRect(x: 30, y: 184, width: 126, height: 28))
        let reveal = NSButton(title: "打开备份目录", target: self, action: #selector(revealHistoryBackups))
        styleButton(reveal, frame: NSRect(x: 168, y: 184, width: 134, height: 28))
        historyVersions.frame = NSRect(x: 26, y: 224, width: 280, height: 28)
        historyVersions.setAccessibilityLabel("历史备份版本，最新在前")
        historyVersions.target = self
        historyVersions.action = #selector(selectHistoryVersion)
        historyExport.target = self
        historyExport.action = #selector(exportHistoryVersion)
        styleButton(historyExport, frame: NSRect(x: 30, y: 263, width: 272, height: 28))
        let scroll = NSScrollView(frame: NSRect(x: 30, y: 304, width: 272, height: 58))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        historyStatus.frame = NSRect(x: 0, y: 0, width: 258, height: 58)
        historyStatus.preferredMaxLayoutWidth = 258
        historyStatus.font = .systemFont(ofSize: 11)
        historyStatus.textColor = MenuPanelView.color(0xF4F7FA)
        historyStatus.isSelectable = true
        scroll.documentView = historyStatus
        let scope = NSTextField(wrappingLabelWithString: "备份保留在本机，包含聊天原文和附件。\n不含云端记录、目录外数据库与登录凭据。")
        scope.frame = NSRect(x: 30, y: 371, width: 272, height: 34)
        scope.font = .systemFont(ofSize: 10)
        scope.textColor = MenuPanelView.color(0xC9D2DD)
        historyViews = [caption, intervalLabel, historyPageToggle, historyInterval, historyNow, reveal, historyVersions, historyExport, scroll, scope]
        for view in historyViews { panelView.addSubview(view) }
    }

    @objc private func showHistoryBackups() {
        setPage(3)
        showWindow()
        if !historyBusy { loadHistoryBackups() }
    }

    private func setHistoryStatus(_ message: String, failed: Bool = false) {
        if failed { historyError = message }
        let visible = !failed && historyError != nil ? message + "\n最近操作失败：" + historyError! : message
        historyStatus.stringValue = visible
        historyStatus.toolTip = visible
        let height = historyStatus.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 258, height: 10_000)).height ?? 58
        historyStatus.setFrameSize(NSSize(width: 258, height: max(58, height)))
        historyStatus.textColor = historyError != nil ? .systemOrange : MenuPanelView.color(0xF4F7FA)
        historyButton.title = historyError != nil ? "备份需要处理 · 查看详情" : "查看备份与版本"
        historyButton.toolTip = historyError ?? message
    }

    private func updateHistoryVersions(_ snapshots: [CodexHistoryBackup.Snapshot]) {
        historySnapshots = snapshots
        historyVersions.removeAllItems()
        for snapshot in snapshots {
            historyVersions.addItem(withTitle: snapshot.createdAt.formatted(date: .numeric, time: .standard) + " · " + String(snapshot.id.prefix(8)))
        }
        if snapshots.isEmpty { historyVersions.addItem(withTitle: "尚无历史版本") }
        refreshControls()
    }

    @objc private func selectHistoryVersion() {
        let index = historyVersions.indexOfSelectedItem
        guard historySnapshots.indices.contains(index) else { return }
        let snapshot = historySnapshots[index]
        let bytes = snapshot.files.reduce(Int64(0)) { $0 + $1.byteCount }
        setHistoryStatus("版本包含 \(snapshot.files.count) 个文件 · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))\n导出到新目录后可查看完整文件；不会覆盖当前 Codex。")
    }

    private func loadHistoryBackups() {
        guard !historyBusy, !transitioning, !isDiscovering, let home = selectedHome else { return }
        historyBusy = true
        refreshControls()
        historyWorker.async {
            let result = Result { try CodexHistoryBackup.snapshots(home: home, repository: CodexHistoryBackup.defaultRepository) }
            DispatchQueue.main.async {
                self.historyBusy = false
                guard !self.terminating else { return }
                switch result {
                case .success(let snapshots):
                    self.updateHistoryVersions(snapshots)
                    if let error = self.historyError {
                        self.setHistoryStatus(error, failed: true)
                    } else if let latest = snapshots.first {
                        self.setHistoryStatus("最新版本：" + latest.createdAt.formatted(date: .numeric, time: .standard) + "\n共 \(snapshots.count) 个版本 · \(latest.files.count) 个文件")
                    } else { self.setHistoryStatus("尚无备份。选择立即备份或启用定时备份。") }
                    self.configureHistoryTimer()
                case .failure(let error):
                    self.updateHistoryVersions([])
                    self.setHistoryStatus(error.localizedDescription, failed: true)
                }
                self.refreshControls()
            }
        }
    }

    @objc private func toggleHistoryBackups(_ sender: NSSwitch) {
        UserDefaults.standard.set(sender.state == .on, forKey: "historyBackupEnabled")
        refreshControls()
        configureHistoryTimer()
        if sender.state == .off {
            setHistoryStatus(historyBusy
                ? "定时备份已关闭；当前操作完成后停止，历史版本保留。"
                : "定时备份已关闭；历史版本保留，可随时手动备份。")
        }
    }

    @objc private func changeHistoryInterval() {
        UserDefaults.standard.set(historyInterval.selectedItem?.tag ?? 3600, forKey: "historyBackupInterval")
        configureHistoryTimer()
    }

    private func configureHistoryTimer() {
        historyTimer?.invalidate(); historyTimer = nil
        guard UserDefaults.standard.bool(forKey: "historyBackupEnabled"), selectedHome != nil, !terminating else { return }
        historyTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.backupHistoryIfDue()
        }
        backupHistoryIfDue()
    }

    private func backupHistoryIfDue() {
        guard UserDefaults.standard.bool(forKey: "historyBackupEnabled"),
              let home = selectedHome, let interval = historyInterval.selectedItem?.tag, interval > 0 else { return }
        let last = UserDefaults.standard.object(forKey: "historyBackupLastAttempt." + home.path) as? Date
        if let last, last <= Date(), Date().timeIntervalSince(last) < Double(interval) { return }
        backupHistoryNow()
    }

    @objc private func backupHistoryNow() {
        guard !historyBusy, !transitioning, !isDiscovering, let home = selectedHome else { return }
        historyBusy = true
        historyError = nil
        UserDefaults.standard.set(Date(), forKey: "historyBackupLastAttempt." + home.path)
        setHistoryStatus("正在备份聊天、记忆与附件…")
        refreshControls()
        historyWorker.async {
            let result = Result { () -> (CodexHistoryBackup.Snapshot, [CodexHistoryBackup.Snapshot]) in
                let snapshot = try CodexHistoryBackup.create(home: home, repository: CodexHistoryBackup.defaultRepository)
                return (snapshot, try CodexHistoryBackup.snapshots(home: home, repository: CodexHistoryBackup.defaultRepository))
            }
            DispatchQueue.main.async {
                self.historyBusy = false
                guard !self.terminating else { return }
                switch result {
                case .success(let (snapshot, snapshots)):
                    self.updateHistoryVersions(snapshots)
                    self.setHistoryStatus("备份检查完成 · \(snapshot.files.count) 个文件\n最新版本：" + snapshot.createdAt.formatted(date: .numeric, time: .standard) + "；内容不变时复用原版本。")
                case .failure(let error): self.setHistoryStatus(error.localizedDescription, failed: true)
                }
                self.refreshControls()
            }
        }
    }

    @objc private func revealHistoryBackups() {
        let directory = CodexHistoryBackup.defaultRepository
        if FileManager.default.fileExists(atPath: directory.path) { NSWorkspace.shared.open(directory) }
        else { setHistoryStatus("尚未创建备份目录，请先完成一次备份。") }
    }

    @objc private func exportHistoryVersion() {
        let index = historyVersions.indexOfSelectedItem
        guard !historyBusy, !transitioning, historySnapshots.indices.contains(index) else { return }
        let snapshot = historySnapshots[index]
        isChoosingHome = true
        defer { isChoosingHome = false; showWindow() }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.title = "选择导出位置"
        panel.message = "将在这里新建独立文件夹，保留原目录结构，包含聊天与记忆原文。"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let destination = parent.appendingPathComponent("Miruun-" + snapshot.id, isDirectory: true)
        historyBusy = true
        setHistoryStatus("正在校验并导出所选版本…")
        refreshControls()
        historyWorker.async {
            let result = Result { try CodexHistoryBackup.export(snapshot, repository: CodexHistoryBackup.defaultRepository, destination: destination) }
            DispatchQueue.main.async {
                self.historyBusy = false
                guard !self.terminating else { return }
                switch result {
                case .success:
                    self.historyError = nil
                    self.setHistoryStatus("版本已导出到：\n" + destination.path)
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                case .failure(let error): self.setHistoryStatus(error.localizedDescription, failed: true)
                }
                self.refreshControls()
            }
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminating = true
        transitioning = true
        historyTimer?.invalidate(); historyTimer = nil
        launchRequest = nil
        hideWindow()
        worker.async {
            self.timer?.cancel(); self.timer = nil
            self.guardService = nil; self.pendingLaunch = nil
            self.historyWorker.async {
                DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) }
            }
        }
        return .terminateLater
    }
}
