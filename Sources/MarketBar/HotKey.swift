import AppKit

/// 一组快捷键：键码 + 修饰键。`key` 只用来显示。
///
/// 匹配只认 (keyCode, modifiers)，**不认字符** —— 字符会随输入法/键盘布局变，
/// 键码不会。
struct KeyCombo: Codable, Equatable, Sendable {
    var keyCode: UInt16
    /// 只保留 deviceIndependentFlagsMask 里的位
    var modifiers: UInt
    /// 显示用，录制时从 `charactersIgnoringModifiers` 取
    var key: String

    /// 参与匹配的修饰键（大小写锁、小键盘、功能键不参与 —— 它们不该影响快捷键）
    static let relevantFlags: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    static func normalize(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(relevantFlags)
    }

    /// 从一次按键录制
    static func from(_ event: NSEvent) -> KeyCombo? {
        let flags = normalize(event.modifierFlags)
        // **必须带修饰键**：不带的话就成了「按 m 就触发」，会把正常打字全劫走
        guard !flags.isEmpty else { return nil }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        guard !key.isEmpty else { return nil }
        return KeyCombo(keyCode: event.keyCode, modifiers: flags.rawValue, key: key)
    }

    func matches(_ event: NSEvent) -> Bool {
        guard event.keyCode == keyCode else { return false }
        return Self.normalize(event.modifierFlags).rawValue == modifiers
    }

    /// "⌥⌘M"
    var displayText: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + key.uppercased()
    }

    /// 默认：行情面板 ⌥⌘M、宠物显隐 ⌥⌘P。挑的都是不容易和别的 app 撞的组合
    static let defaultPanel = KeyCombo(
        keyCode: 46, modifiers: NSEvent.ModifierFlags([.option, .command]).rawValue, key: "m"
    )
    static let defaultCharacter = KeyCombo(
        keyCode: 35, modifiers: NSEvent.ModifierFlags([.option, .command]).rawValue, key: "p"
    )
}

/// 注册若干组快捷键。
///
/// 用 `NSEvent` 监视器而不是 Carbon 热键：代码少得多，而本 app 本来就需要
/// 辅助功能权限（微信未读徽标用）。代价是**按键不会被吃掉**（Carbon 会），
/// 所以默认挑的都是不容易冲突的组合。
///
/// 两个监视器缺一不可：全局的收不到本 app 自己是前台时的按键，本地的只管那时。
@MainActor
final class HotKeyCenter {
    private var monitors: [Any] = []
    private var bindings: [(combo: KeyCombo, action: () -> Void)] = []

    /// 换绑（配置改了之后重新调用即可）
    func bind(_ bindings: [(combo: KeyCombo, action: () -> Void)]) {
        self.bindings = bindings
        installMonitorsIfNeeded()
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    private func installMonitorsIfNeeded() {
        guard monitors.isEmpty else { return }

        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let action = self?.action(for: event) else { return }
            Task { @MainActor in action() }
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let action = self?.action(for: event) else { return event }
            Task { @MainActor in action() }
            return nil   // 自己前台时把它吃掉
        }) {
            monitors.append(monitor)
        }
    }

    /// 这个按键对应哪条动作（不匹配返回 nil）
    private func action(for event: NSEvent) -> (() -> Void)? {
        bindings.first { $0.combo.matches(event) }?.action
    }
}
