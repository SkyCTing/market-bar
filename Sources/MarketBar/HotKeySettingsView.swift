import AppKit

/// 录制一组快捷键的小方框：点一下，然后按你要的组合键。
@MainActor
final class KeyComboRecorderView: NSView {
    var combo: KeyCombo? {
        didSet {
            refresh()
            onChange?()
        }
    }
    var onChange: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 120, height: 26) }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: 26))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1

        label.alignment = .center
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
        refresh()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return }
        guard let recorded = KeyCombo.from(event) else {
            // 没带修饰键：不接受，否则「按 m 就触发」会把打字全劫走
            NSSound.beep()
            label.stringValue = "要带 ⌘⌥⌃⇧"
            return
        }
        combo = recorded
        isRecording = false
        refresh()
        // 录完把焦点交回去，免得下一次按键又被这里吃掉
        window?.makeFirstResponder(nil)
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        refresh()
        return true
    }

    private func refresh() {
        if isRecording {
            label.stringValue = "按下组合键…"
            label.textColor = .secondaryLabelColor
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            return
        }
        label.stringValue = combo?.displayText ?? "未设置"
        label.textColor = combo == nil ? .tertiaryLabelColor : .labelColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

/// 「快捷键」设置表单（作为 NSAlert 的 accessory view）
@MainActor
final class HotKeySettingsView: NSView {
    private let panelRecorder = KeyComboRecorderView()
    private let characterRecorder = KeyComboRecorderView()
    var onChange: (() -> Void)?

    init(panel: KeyCombo?, character: KeyCombo?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 122))
        panelRecorder.combo = panel
        characterRecorder.combo = character
        buildLayout()
        panelRecorder.onChange = { [weak self] in self?.onChange?() }
        characterRecorder.onChange = { [weak self] in self?.onChange?() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var firstResponderControl: NSView { panelRecorder }

    private func buildLayout() {
        func rowLabel(_ text: String, y: CGFloat) {
            let field = NSTextField(labelWithString: text)
            field.frame = NSRect(x: 0, y: y + 4, width: 76, height: 18)
            field.alignment = .right
            addSubview(field)
        }

        rowLabel("行情面板", y: 84)
        panelRecorder.frame = NSRect(x: 84, y: 80, width: 120, height: 26)
        addSubview(panelRecorder)
        let panelClear = NSButton(title: "清除", target: self, action: #selector(clearPanel))
        panelClear.frame = NSRect(x: 212, y: 80, width: 64, height: 26)
        panelClear.bezelStyle = .rounded
        addSubview(panelClear)

        rowLabel("宠物显隐", y: 46)
        characterRecorder.frame = NSRect(x: 84, y: 42, width: 120, height: 26)
        addSubview(characterRecorder)
        let characterClear = NSButton(title: "清除", target: self, action: #selector(clearCharacter))
        characterClear.frame = NSRect(x: 212, y: 42, width: 64, height: 26)
        characterClear.bezelStyle = .rounded
        addSubview(characterClear)

        let hint = NSTextField(wrappingLabelWithString:
            "点方框，然后按下你要的组合键。至少带一个 ⌘⌥⌃⇧ —— 不带修饰键会把正常打字劫走。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 0, y: 6, width: 400, height: 30)
        addSubview(hint)
    }

    @objc private func clearPanel() { panelRecorder.combo = nil }
    @objc private func clearCharacter() { characterRecorder.combo = nil }

    var panelCombo: KeyCombo? { panelRecorder.combo }
    var characterCombo: KeyCombo? { characterRecorder.combo }
}
