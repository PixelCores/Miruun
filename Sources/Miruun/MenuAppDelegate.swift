import AppKit
import BridgeCore

final class MenuAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var runner: BridgeRunner?
    private var storage: PrivateState?
    private var gate = OperationGate()
    private var activeRequest: String?
    private var confirmation: ConfirmationSheet?
    private var threads: [JSONValue] = []
    private var providers: [JSONValue] = []
    private var backendChoices: [String] = []
    private var lastReceipt: String?
    private var controls: [NSControl] = []
    private var readReturnsLocked = false

    private let backendField = NSTextField()
    private let homeField = NSTextField()
    private let projectField = NSTextField()
    private let searchField = NSSearchField()
    private let archivedCheck = NSButton(checkboxWithTitle: "查询归档对话", target: nil, action: nil)
    private let discoveredPopup = NSPopUpButton()
    private let providerPopup = NSPopUpButton()
    private let table = NSTableView()
    private let identityLabel = NSTextField(wrappingLabelWithString: "先读取元数据，再选择要修改的原对话。不会读取预览或完整历史。")
    private let statusLabel = NSTextField(wrappingLabelWithString: "就绪 · 默认只发现应用，未启动 Codex 后端")
    private let closedCheck = NSButton(checkboxWithTitle: "所有 ChatGPT / Codex 客户端与后端已正常退出，并将保持关闭", target: nil, action: nil)
    private var readButton: NSButton!
    private var preflightButton: NSButton!
    private var verifyButton: NSButton!
    private var revealButton: NSButton!

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { storage = try PrivateState() }
        catch { gate = OperationGate(uncertain: true) }
        if storage?.blocked == true { gate = OperationGate(uncertain: true) }
        if let executable = Bundle.main.executableURL {
            let entry = executable.deletingLastPathComponent().appendingPathComponent("MiruunEngine")
            if FileManager.default.isExecutableFile(atPath: entry.path) { runner = BridgeRunner(entry: entry) }
        }
        makeMenu(); makeWindow(); loadPreferences(); restorePendingNotice(); refreshControls()
        showWindow()
        if runner != nil { discover() }
    }

    private func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let symbol = NSImage(systemSymbolName: "arrow.triangle.swap", accessibilityDescription: "Miruun 原对话供应商切换") {
            statusItem.button?.image = symbol
        } else { statusItem.button?.title = "⇄" }
        statusItem.button?.toolTip = "Miruun · 保留原对话 ID"
        let menu = NSMenu()
        menu.addItem(withTitle: "打开原对话切换面板…", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出 Miruun", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    private func makeWindow() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let available = NSWindow.contentRect(forFrameRect: screen.insetBy(dx: 20, dy: 20), styleMask: style)
        let size = NSSize(width: min(860, available.width), height: min(830, available.height))
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: style, backing: .buffered, defer: false)
        window.title = "Miruun · 原对话供应商切换"
        window.contentMinSize = NSSize(width: min(760, size.width), height: min(560, size.height))
        window.delegate = self; window.isReleasedWhenClosed = false; window.center()
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        window.contentView = scroll
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 24, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = root
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            root.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            root.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        let title = NSTextField(labelWithString: "切换供应商，留在原对话")
        title.font = .systemFont(ofSize: 24, weight: .semibold); root.addArrangedSubview(title)
        addLabel("原生菜单栏工具 · 实验性同 ID 恢复 · 不新建 / 导入对话", to: root, color: .secondaryLabelColor)
        addLabel("1  选择实际后端和存储", to: root, bold: true)
        fieldRow("Codex 后端", field: backendField, buttonTitle: "选择…", action: #selector(chooseBackend), root: root)
        discoveredPopup.target = self; discoveredPopup.action = #selector(choseDiscovered)
        discoveredPopup.addItem(withTitle: "发现的后端候选（需要你选择）")
        let discovery = NSButton(title: "重新发现应用", target: self, action: #selector(discover))
        controls += [discoveredPopup, discovery]
        row([discoveredPopup, discovery], to: root)
        fieldRow("CODEX_HOME", field: homeField, buttonTitle: "选择…", action: #selector(chooseHome), root: root)
        addLabel("读取前请正常退出所有 ChatGPT / Codex 客户端与后端。只读查询也会启动所选后端，它可能读取自己的配置 / 认证并联网维护缓存；桥接程序不读取 auth.json。", to: root, color: .secondaryLabelColor)
        addLabel("2  选择已存在的原对话和供应商", to: root, bold: true)
        searchField.placeholderString = "按后端真实标题检索；留空读取有限条最近对话"
        searchField.delegate = self; controls.append(searchField)
        readButton = NSButton(title: "读取对话与供应商", target: self, action: #selector(loadCatalog))
        controls += [readButton, archivedCheck]; row([searchField, archivedCheck, readButton], to: root)
        for (id, name, width) in [("name", "原对话标题", 270.0), ("cwd", "项目", 285.0), ("model_provider", "当前 provider", 140.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = name; column.width = width
            table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self; table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false; table.rowHeight = 27
        table.setAccessibilityLabel("已有对话，仅身份元数据")
        let tableScroll = NSScrollView(); tableScroll.documentView = table; tableScroll.hasVerticalScroller = true
        root.addArrangedSubview(tableScroll)
        tableScroll.heightAnchor.constraint(equalToConstant: 168).isActive = true
        tableScroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48).isActive = true
        identityLabel.isSelectable = true; identityLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        root.addArrangedSubview(identityLabel); identityLabel.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48).isActive = true
        providerPopup.target = self; providerPopup.action = #selector(providerChanged)
        controls.append(providerPopup)
        row([NSTextField(labelWithString: "目标供应商"), providerPopup], to: root)
        addLabel("只列出该 CODEX_HOME/config.toml 中能确认地址的供应商；CC Switch 的临时覆盖和环境配置不能靠菜单猜测。", to: root, color: .secondaryLabelColor)
        addLabel("3  核对项目，然后预检", to: root, bold: true)
        fieldRow("目标项目", field: projectField, buttonTitle: "选择目录…", action: #selector(chooseProject), root: root)
        projectField.placeholderString = "独立选择你实际想修改的项目；不要照抄错误对话的目录"
        closedCheck.target = self; closedCheck.action = #selector(consentChanged)
        controls.append(closedCheck); root.addArrangedSubview(closedCheck)
        preflightButton = NSButton(title: "预检并查看切换确认…", target: self, action: #selector(preflight))
        preflightButton.bezelStyle = .rounded
        verifyButton = NSButton(title: "仅只读复核", target: self, action: #selector(verify))
        revealButton = NSButton(title: "在 Finder 查看本机备份", target: self, action: #selector(revealReceipt))
        row([preflightButton, verifyButton, revealButton], to: root)
        statusLabel.isSelectable = true; statusLabel.font = .systemFont(ofSize: 12)
        root.addArrangedSubview(statusLabel); statusLabel.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48).isActive = true
        addLabel("实验性原生工具。后端设置验证不等于原 GUI 已成功续聊，请自行核对原对话与实际请求。当前应用未经 Developer ID 签名或公证。关闭面板仅隐藏界面；进行中的切换不能取消或重试。", to: root, color: .secondaryLabelColor)
    }

    private func row(_ views: [NSView], to root: NSStackView) {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = 10; stack.alignment = .centerY
        root.addArrangedSubview(stack); stack.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48).isActive = true
    }
    private func fieldRow(_ label: String, field: NSTextField, buttonTitle: String, action: Selector, root: NSStackView) {
        let name = NSTextField(labelWithString: label); name.widthAnchor.constraint(equalToConstant: 106).isActive = true
        let button = NSButton(title: buttonTitle, target: self, action: action)
        field.delegate = self; field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controls += [field, button]; row([name, field, button], to: root)
    }
    private func addLabel(_ text: String, to root: NSStackView, bold: Bool = false, color: NSColor = .labelColor) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: bold ? 14 : 11, weight: bold ? .semibold : .regular); label.textColor = color
        root.addArrangedSubview(label); label.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48).isActive = true
    }

    @objc private func showWindow() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if gate.busy {
            showWindow(); status("操作尚未返回最终结果。请保持应用运行；关闭窗口可隐藏面板，不会取消操作。", warning: true)
            return .terminateCancel
        }
        return .terminateNow
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }

    private func loadPreferences() {
        let defaults = UserDefaults.standard
        backendField.stringValue = defaults.string(forKey: "backendPath") ?? ""
        homeField.stringValue = defaults.string(forKey: "codexHome") ?? NSHomeDirectory() + "/.codex"
    }
    private func savePreferences() {
        UserDefaults.standard.set(backendField.stringValue, forKey: "backendPath")
        UserDefaults.standard.set(homeField.stringValue, forKey: "codexHome")
    }
    private func restorePendingNotice() {
        if let pending = storage?.pending {
            backendField.stringValue = pending["backend"]?.string ?? backendField.stringValue
            homeField.stringValue = pending["home"]?.string ?? homeField.stringValue
            lastReceipt = pending["backup_directory"]?.string
        }
        if locked { status("上次操作未获得明确最终结果，或本机状态目录不可用。变更已锁定；保留备份，只能只读复核，不会重试或自动回滚。", warning: true) }
        if runner == nil { status("缺少已打包的 Swift 引擎。请用 Build App.command 构建完整 .app，不要直接运行 swift run。", warning: true) }
    }
    private var locked: Bool { storage == nil || storage?.blocked == true || gate.phase == .uncertain }
    private var selectedThread: JSONValue? { table.selectedRow >= 0 && table.selectedRow < threads.count ? threads[table.selectedRow] : nil }
    private var selectedProvider: JSONValue? {
        let index = providerPopup.indexOfSelectedItem - 1
        return index >= 0 && index < providers.count ? providers[index] : nil
    }
    private func path(_ field: NSTextField) -> String { (field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath }
    private func status(_ text: String, warning: Bool = false) { statusLabel.stringValue = text; statusLabel.textColor = warning ? .systemOrange : .labelColor }
    private func refreshControls() {
        for control in controls { control.isEnabled = !gate.busy }
        let ready = !gate.busy && runner != nil
        readButton.isEnabled = ready && !path(backendField).isEmpty && !path(homeField).isEmpty
        preflightButton.isEnabled = ready && !locked && selectedThread != nil && selectedProvider?["selectable"].bool == true && path(projectField).hasPrefix("/") && closedCheck.state == .on
        verifyButton.isEnabled = ready && (selectedThread != nil || storage?.pending?["thread_id"]?.string != nil)
        revealButton.isEnabled = !gate.busy && lastReceipt != nil
        statusItem.button?.appearsDisabled = gate.busy
    }

    @objc private func chooseBackend() { choose(field: backendField, directory: false) }
    @objc private func chooseHome() { choose(field: homeField, directory: true) }
    @objc private func chooseProject() { choose(field: projectField, directory: true) }
    private func choose(field: NSTextField, directory: Bool) {
        guard !gate.busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = !directory; panel.canChooseDirectories = directory
        panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.message = directory ? "选择已存在的本机目录" : "选择实际可执行文件；可按 ⌘⇧G 输入完整路径"
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            field.stringValue = url.path; self.inputChanged(field)
        }
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }; inputChanged(field)
    }
    private func inputChanged(_ field: NSTextField) {
        guard !gate.busy else { return }
        if field === backendField || field === homeField { clearCatalog(); savePreferences() }
        refreshControls()
    }
    private func clearCatalog() {
        threads.removeAll(); providers.removeAll(); table.reloadData(); providerPopup.removeAllItems()
        identityLabel.stringValue = "后端 / 存储已改变，请重新读取原对话元数据。"
        projectField.stringValue = ""; closedCheck.state = .off
    }
    @objc private func choseDiscovered() {
        let index = discoveredPopup.indexOfSelectedItem - 1
        guard index >= 0 && index < backendChoices.count else { return }
        backendField.stringValue = backendChoices[index]; inputChanged(backendField)
    }
    @objc private func providerChanged() { refreshControls() }
    @objc private func consentChanged() { refreshControls() }

    private func request(_ command: String) -> [String: JSONValue] {
        var value: [String: JSONValue] = ["protocol_version": .number(1), "command": .string(command), "request_id": .string(UUID().uuidString)]
        if command != "discover" {
            value["backend"] = .string(path(backendField)); value["home"] = .string(path(homeField)); value["confirm_native"] = .bool(true)
            if let storage { value["state_directory"] = .string(storage.root.path) }
        }
        return value
    }
    private func runRead(_ value: [String: JSONValue], finish: @escaping (JSONValue) -> Void) {
        guard let runner, !gate.busy else { return }
        readReturnsLocked = locked
        guard gate.beginRead() else { return }
        activeRequest = value["request_id"]?.string; let id = activeRequest
        refreshControls(); status("正在进行只读检查…")
        runner.run(request: value, progress: { [weak self] event in
            guard let self, self.activeRequest == id else { return }; self.progress(event)
        }) { [weak self] response in
            guard let self, self.activeRequest == id else { return }
            self.activeRequest = nil; self.gate.endRead(locked: self.readReturnsLocked); self.refreshControls()
            switch response {
            case .success(let envelope):
                if envelope.ok == true, let result = envelope.result { finish(result) }
                else { self.status(envelope.error?["message"].string ?? "只读检查未通过；未请求切换。", warning: true) }
            case .failure(let error): self.status(error.message, warning: true)
            }
        }
    }
    private func progress(_ envelope: BridgeEnvelope) {
        let names = ["candidate_probe": "正在核对实际版本与协议", "identity_inspection": "重新核对原对话身份和安全门", "backup_start": "正在创建本机私有备份", "backup_complete": "私有备份已完成", "resume_request": "正在恢复同一个原对话", "resume_response_validation": "正在核对变更响应", "verification_backend_start": "正在启动独立验证后端", "verification_resume_request": "正在冷重开验证持久化设置", "verification_response_validation": "正在核对持久化结果", "complete": "收到后端结果"]
        if let receipt = envelope.receiptPath { lastReceipt = receipt }
        status(names[envelope.stage ?? ""] ?? "正在等待后端完成安全检查…")
    }

    @objc private func discover() {
        guard !gate.busy else { return }
        runRead(request("discover")) { [weak self] result in
            guard let self else { return }
            self.backendChoices.removeAll(); self.discoveredPopup.removeAllItems()
            self.discoveredPopup.addItem(withTitle: "发现的后端候选（需要你选择）")
            for app in result["apps"].array ?? [] {
                for candidate in app["backend_candidates"].array ?? [] {
                    guard let backend = candidate.string else { continue }
                    self.backendChoices.append(backend)
                    self.discoveredPopup.addItem(withTitle: "\(app["name"].string ?? "应用") \(app["version"].string ?? "") · \(backend)")
                }
            }
            self.status(self.backendChoices.isEmpty ? "未发现后端候选。请选择实际可执行文件；未读取任何会话。" : "发现 \(self.backendChoices.count) 个后端候选。请选择当前实际使用的应用后端；未启动候选程序。")
            self.refreshControls()
            if self.locked { self.restorePendingNotice() }
        }
    }
    @objc private func loadCatalog() {
        guard !gate.busy else { return }
        let alert = NSAlert(); alert.messageText = "读取原对话身份元数据？"
        alert.informativeText = "请先正常退出所有 ChatGPT / Codex 客户端与其他后端。将启动你选择的 Codex 后端，读取标题、ID、项目、模型 / provider 与现有配置的脱敏供应商地址。不会读取预览或历史，不会 resume / 切换。后端自身仍可能读取认证、维护缓存或进行启动网络活动。"
        alert.addButton(withTitle: "读取元数据"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn, !self.gate.busy else { return }
            self.savePreferences()
            var value = self.request("catalog")
            let search = self.searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !search.isEmpty { value["search"] = .string(search) }
            value["archived"] = .bool(self.archivedCheck.state == .on)
            self.runRead(value) { [weak self] result in
                guard let self else { return }
                self.threads = Array((result["threads"].array ?? []).prefix(100))
                self.providers = Array((result["providers"].array ?? []).prefix(100))
                self.table.reloadData(); self.table.deselectAll(nil); self.providerPopup.removeAllItems()
                self.providerPopup.addItem(withTitle: "请选择目标供应商")
                for provider in self.providers {
                    let endpoint = provider["endpoint_origin"].string ?? "地址未知"
                    let blocked = provider["selectable"].bool == true ? "" : " · 不可切换"
                    self.providerPopup.addItem(withTitle: "\(provider["id"].string ?? "未知") · \(endpoint)\(blocked)")
                }
                self.projectField.stringValue = ""; self.closedCheck.state = .off
                self.identityLabel.stringValue = "请选择原对话，并在原 GUI 独立核对完整 ID / 标题 / 项目。"
                self.status("读取 \(self.threads.count) 条身份元数据 · \(result["backend_version"].string ?? "后端版本未知")。更多对话请用标题检索。")
                self.refreshControls()
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { threads.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < threads.count, let key = tableColumn?.identifier.rawValue else { return nil }
        let label = NSTextField(labelWithString: threads[row][key].string ?? (key == "name" ? "（无后端标题）" : "未知"))
        label.lineBreakMode = .byTruncatingMiddle; label.toolTip = label.stringValue
        return label
    }
    func selectionShouldChange(in tableView: NSTableView) -> Bool { !gate.busy }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !gate.busy, let thread = selectedThread else { return }
        identityLabel.stringValue = "标题：\(thread["name"].string ?? "（后端未提供）")\n原 ID：\(thread["thread_id"].string ?? "未知")\n项目：\(thread["cwd"].string ?? "未知")\n当前：\(thread["model_provider"].string ?? "未知") · 模型 \(thread["model"].string ?? "（将在预检核实）")"
        projectField.stringValue = ""; closedCheck.state = .off; refreshControls()
    }

    @objc private func preflight() {
        guard gate.mayMutate, !locked, let thread = selectedThread, let provider = selectedProvider,
              let threadID = thread["thread_id"].string, let providerID = provider["id"].string,
              closedCheck.state == .on, provider["selectable"].bool == true else { return }
        let expectedCWD = URL(fileURLWithPath: path(projectField)).standardizedFileURL.path
        var value = request("preflight")
        value["thread_id"] = .string(threadID); value["provider"] = .string(providerID)
        value["expected_name"] = thread["name"]
        if let model = thread["model"].string { value["model"] = .string(model) }
        value["expected_cwd"] = .string(expectedCWD); value["closed_clients"] = .bool(true)
        runRead(value) { [weak self] result in
            guard let self else { return }
            guard result["can_switch"].bool == true, let preflightID = result["preflight_id"].string else {
                let blockers = (result["blockers"].array ?? []).compactMap(\.string).joined(separator: "\n")
                self.status("预检未通过，未请求变更。\n" + blockers, warning: true); return
            }
            let identity = result["identity"], destination = result["destination"]
            let selection = ConfirmedSelection(threadID: identity["thread_id"].string ?? "", title: identity["name"].string,
                cwd: identity["cwd"].string ?? "", provider: destination["provider"].string ?? "",
                endpoint: destination["endpoint_origin"].string ?? "", model: result["model"].string ?? identity["model"].string ?? "")
            guard selection.complete, selection.threadID == threadID, selection.cwd == expectedCWD,
                  selection.provider == providerID, selection.endpoint == provider["endpoint_origin"].string else {
                self.status("预检返回的身份 / 目标地址与选中项不一致；停止。请重新读取并核对。", warning: true); return
            }
            self.confirm(selection, preflightID: preflightID)
        }
    }
    private func confirm(_ selection: ConfirmedSelection, preflightID: String) {
        guard let storage, !locked, gate.beginConfirmation() else { return }
        let backup = storage.root.appendingPathComponent("Backups", isDirectory: true).appendingPathComponent(UUID().uuidString).path
        refreshControls()
        confirmation = ConfirmationSheet()
        confirmation?.present(selection: selection, backupPath: backup, window: window) { [weak self] approved in
            guard let self else { return }
            self.confirmation = nil
            if approved { self.apply(selection, preflightID: preflightID, backup: backup) }
            else { self.gate.cancelConfirmation(); self.status("已取消确认，未启动变更。"); self.refreshControls() }
        }
    }
    private func apply(_ selection: ConfirmedSelection, preflightID: String, backup: String) {
        guard let storage, let runner, gate.phase == .confirming, !storage.blocked else { return }
        var value = request("switch")
        value["thread_id"] = .string(selection.threadID); value["provider"] = .string(selection.provider)
        value["model"] = .string(selection.model); value["expected_cwd"] = .string(selection.cwd)
        value["preflight_id"] = .string(preflightID); value["backup_directory"] = .string(backup)
        for flag in ["confirmed", "closed_clients", "backup_consent", "experimental_consent", "endpoint_ack", "startup_transmission_ack"] { value[flag] = .bool(true) }
        do { try storage.begin(value) }
        catch {
            gate.cancelConfirmation(); status("无法安全保存本机操作锁，未启动变更。请检查私有状态目录。", warning: true); refreshControls(); return
        }
        guard gate.beginSwitch(allConsents: true) else { return }
        activeRequest = value["request_id"]?.string; let id = activeRequest
        lastReceipt = backup; status("正在备份并切换原对话。请保持所有 Codex 客户端关闭；此时不能取消或重复执行。")
        refreshControls()
        runner.run(request: value, progress: { [weak self] event in
            guard let self, self.activeRequest == id else { return }; self.progress(event)
        }) { [weak self] response in
            guard let self, self.activeRequest == id else { return }
            self.activeRequest = nil
            var certain = false
            switch response {
            case .success(let envelope):
                if envelope.ok == true, let result = envelope.result {
                    let state = result["state"].string ?? "unknown"
                    certain = state == "backend_verified_gui_unverified" && result["thread_id"].string == selection.threadID && result["fresh_backend_effective_settings_verified"].bool == true
                    self.lastReceipt = result["receipt_path"].string ?? result["backup_directory"].string ?? backup
                    if certain {
                        if let index = self.threads.firstIndex(where: { $0["thread_id"].string == selection.threadID }),
                           var thread = self.threads[index].object {
                            thread["model_provider"] = .string(selection.provider)
                            thread["model"] = .string(selection.model)
                            self.threads[index] = .object(thread)
                            self.table.reloadData()
                        }
                        self.identityLabel.stringValue = selection.summary + "\n后端设置已验证；GUI 续聊待核对。"
                        self.status("后端已验证：原 ID 与原模型保持，冷重开后目标 provider 设置保留。GUI 尚未验证。现在可自行打开原对话核对；不要为清除旧超时提示重复切换。\n备份 / 回执：\(self.lastReceipt ?? backup)")
                    } else {
                        self.status("\(result["detail"].string ?? "结果不确定，可能已修改。")\n阶段：\(result["diagnostic_stage"].string ?? state)\n保留本机备份；不会自动重试或回滚。", warning: true)
                    }
                } else {
                    certain = envelope.error?["uncertain"].bool == false && envelope.error?["stopped_before_mutation"].bool == true
                    self.lastReceipt = envelope.error?["receipt_path"].string ?? backup
                    self.status(envelope.error?["message"].string ?? "操作没有明确结果；保留备份，只能只读复核。", warning: true)
                }
            case .failure(let error):
                // Even a spawn failure keeps the durable lock: unexpected local
                // errors are never used as an automatic permission to retry.
                self.status(error.message, warning: true)
            }
            do { try storage.finish(certain: certain) }
            catch { certain = false; self.status("最终结果已返回，但未能安全更新操作锁。保留备份，暂时只做只读复核。", warning: true) }
            self.gate.finishSwitch(certain: certain); self.closedCheck.state = .off; self.refreshControls()
        }
    }

    @objc private func verify() {
        guard !gate.busy else { return }
        var value = request("verify")
        if locked, let pending = storage?.pending {
            for key in ["backend", "home", "thread_id"] { value[key] = pending[key] }
        } else { value["thread_id"] = selectedThread?["thread_id"] }
        guard value["thread_id"]?.string != nil else { return }
        runRead(value) { [weak self] result in
            guard let self else { return }
            let identity = result["identity"].object != nil ? result["identity"] : result
            self.status("只读身份复核：\n原 ID：\(identity["thread_id"].string ?? "未知")\n标题：\(identity["name"].string ?? "（后端未提供）")\n项目：\(identity["cwd"].string ?? "未知")\n存储 provider：\(identity["model_provider"].string ?? "未知")\n这是存储元数据，不能证明 GUI 当前路由 / 模型请求成功；不会解除不确定操作锁。", warning: self.locked)
        }
    }
    @objc private func revealReceipt() {
        guard let root = storage?.root, let lastReceipt else { return }
        let url = URL(fileURLWithPath: lastReceipt).standardizedFileURL
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/") else { return }
        let existing = FileManager.default.fileExists(atPath: url.path) ? url : root
        NSWorkspace.shared.activateFileViewerSelecting([existing])
    }
}
