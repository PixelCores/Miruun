import AppKit
import BridgeCore

final class ConfirmationSheet: NSObject {
    private let alert = NSAlert()
    private var checks: [NSButton] = []
    private var complete: ((Bool) -> Void)?

    func present(selection: ConfirmedSelection, backupPath: String, window: NSWindow, completion: @escaping (Bool) -> Void) {
        complete = completion
        alert.messageText = "确认切换这个原对话？"
        alert.informativeText = "逐项阅读并确认下面的原对话、目标地址和风险。所有选项勾选后，才会创建备份并请求变更。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "备份并切换原对话")
        alert.addButton(withTitle: "取消")
        alert.buttons[0].isEnabled = false
        // Return/Escape default to cancellation, not an accidental write.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\u{1b}"
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        let identity = NSTextField(wrappingLabelWithString: selection.summary)
        identity.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        identity.isSelectable = true
        identity.widthAnchor.constraint(equalToConstant: 562).isActive = true
        stack.addArrangedSubview(identity)
        let warnings = [
            "我已在原 GUI 核对标题、完整 ID 和项目，确定选中了要修改的原对话",
            "所有 ChatGPT / Codex GUI 与其他后端已正常退出；全过程保持关闭",
            "我已在 CC Switch / 配置中核对目标供应商与实际 endpoint；菜单只显示脱敏地址",
            "允许在本机备份选中 rollout 和共享状态数据库（可能含其他对话数据）",
            "接受实验性同 ID 恢复风险；尚不能保证此 Mac 的 GUI、压缩上下文与跨账户兼容性",
            "同意本次启动 / 预热向配置的供应商及 MCP 服务发送基础指令、工具元数据，并发生认证 / 初始化活动，可能产生费用",
            "知道之后主动续聊可能把对话历史发给目标供应商；不确定结果只复核，不重试或自动回滚"
        ]
        for text in warnings {
            let button = NSButton(checkboxWithTitle: text, target: self, action: #selector(changed))
            button.setContentHuggingPriority(.defaultLow, for: .horizontal)
            button.cell?.wraps = true
            button.widthAnchor.constraint(equalToConstant: 562).isActive = true
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: text.count > 48 ? 42 : 26).isActive = true
            checks.append(button); stack.addArrangedSubview(button)
        }
        let location = NSTextField(wrappingLabelWithString: "本次私有备份位置：\n\(backupPath)\n不会新建或导入对话，不主动启动模型回合；恢复 / 验证仍可能联网和写入 checkpoint。")
        location.font = .systemFont(ofSize: 11)
        location.textColor = .secondaryLabelColor
        location.isSelectable = true
        location.widthAnchor.constraint(equalToConstant: 562).isActive = true
        stack.addArrangedSubview(location)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 380))
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.widthAnchor.constraint(equalToConstant: 580)
        ])
        alert.accessoryView = scroll
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            let approved = response == .alertFirstButtonReturn && self.checks.allSatisfy { $0.state == .on }
            self.complete?(approved)
            self.complete = nil
        }
    }
    @objc private func changed() { alert.buttons[0].isEnabled = checks.allSatisfy { $0.state == .on } }
}
