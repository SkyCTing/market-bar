import AppKit

/// 「会议模式设置…」表单（作为 NSAlert 的 accessory view）。
///
/// 手写 frame，和 `HotKeySettingsView` 一个路子
@MainActor
final class MeetingSettingsView: NSView {
    private let quitWeChatCheckbox = NSButton(
        checkboxWithTitle: "开会时退出微信（散会后自动开回来）",
        target: nil,
        action: nil
    )
    private let startField = NSTextField()
    private let endField = NSTextField()

    var onChange: (() -> Void)?

    init(quitsWeChat: Bool, startShortcut: String, endShortcut: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 150))
        quitWeChatCheckbox.state = quitsWeChat ? .on : .off
        startField.stringValue = startShortcut
        endField.stringValue = endShortcut
        buildLayout()
        for field in [startField, endField] {
            field.delegate = self
        }
        quitWeChatCheckbox.target = self
        quitWeChatCheckbox.action = #selector(changed)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var firstResponderControl: NSView { startField }

    var quitsWeChat: Bool { quitWeChatCheckbox.state == .on }
    var startShortcut: String { startField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    var endShortcut: String { endField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func buildLayout() {
        quitWeChatCheckbox.frame = NSRect(x: 0, y: 122, width: 400, height: 20)
        addSubview(quitWeChatCheckbox)

        func rowLabel(_ text: String, y: CGFloat) {
            let field = NSTextField(labelWithString: text)
            field.frame = NSRect(x: 0, y: y + 4, width: 104, height: 18)
            field.alignment = .right
            addSubview(field)
        }

        rowLabel("开始专注", y: 84)
        startField.frame = NSRect(x: 112, y: 80, width: 288, height: 24)
        startField.placeholderString = "快捷指令名字，留空 = 不动专注模式"
        addSubview(startField)

        rowLabel("结束专注", y: 50)
        endField.frame = NSRect(x: 112, y: 46, width: 288, height: 24)
        endField.placeholderString = "快捷指令名字，留空 = 不动专注模式"
        addSubview(endField)

        let hint = NSTextField(wrappingLabelWithString:
            "专注模式没有公开 API，只能借道快捷指令：在「快捷指令」里建两个（操作选「设定专注模式」），"
                + "把名字填在这里。第一次跑可能弹一次控制「快捷指令」的自动化授权。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 0, y: 4, width: 400, height: 38)
        addSubview(hint)
    }

    @objc private func changed() { onChange?() }
}

extension MeetingSettingsView: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) { onChange?() }
}
