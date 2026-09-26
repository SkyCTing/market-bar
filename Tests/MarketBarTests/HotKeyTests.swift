import AppKit
import XCTest

@testable import MarketBar

final class KeyComboTests: XCTestCase {
    private func event(keyCode: UInt16, flags: NSEvent.ModifierFlags, key: String = "m") -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil,
            characters: key, charactersIgnoringModifiers: key,
            isARepeat: false, keyCode: keyCode
        )!
    }

    /// ⚠️ 不带修饰键的组合必须拒收 —— 否则「按 m 就触发」会把正常打字全劫走
    func testCombosWithoutModifiersAreRejected() {
        XCTAssertNil(KeyCombo.from(event(keyCode: 46, flags: [])))
        XCTAssertNil(KeyCombo.from(event(keyCode: 46, flags: [.capsLock])))
        XCTAssertNil(KeyCombo.from(event(keyCode: 46, flags: [.function])))
    }

    func testCombosWithModifiersAreAccepted() {
        let combo = KeyCombo.from(event(keyCode: 46, flags: [.option, .command]))

        XCTAssertEqual(combo?.keyCode, 46)
        XCTAssertEqual(combo?.key, "m")
        XCTAssertEqual(combo?.modifiers, NSEvent.ModifierFlags([.option, .command]).rawValue)
    }

    /// 大小写锁/小键盘/功能键不该影响匹配
    func testIrrelevantFlagsAreIgnored() {
        let combo = KeyCombo.from(event(keyCode: 46, flags: [.option, .command]))

        XCTAssertEqual(
            combo?.matches(event(keyCode: 46, flags: [.option, .command, .capsLock, .numericPad])),
            true
        )
    }

    func testMatchesRequiresSameKeyAndModifiers() {
        let combo = KeyCombo.from(event(keyCode: 46, flags: [.option, .command]))!

        XCTAssertFalse(combo.matches(event(keyCode: 35, flags: [.option, .command])), "键不同")
        XCTAssertFalse(combo.matches(event(keyCode: 46, flags: [.option])), "修饰键不同")
        XCTAssertFalse(combo.matches(event(keyCode: 46, flags: [.command])), "修饰键不同")
    }

    func testDisplayText() {
        let combo = KeyCombo.from(event(keyCode: 46, flags: [.option, .command]))!

        XCTAssertEqual(combo.displayText, "⌥⌘M")
    }

    func testDisplayTextCoversAllModifiers() {
        let combo = KeyCombo.from(event(keyCode: 46, flags: [.control, .option, .shift, .command]))!

        XCTAssertEqual(combo.displayText, "⌃⌥⇧⌘M")
    }

    /// 存进 UserDefaults 再读回来要一致（含「用户清掉了」这一档）
    func testRoundTripsThroughJSON() throws {
        let combo = KeyCombo.from(event(keyCode: 35, flags: [.option, .command]))!

        let data = try JSONEncoder().encode(combo as KeyCombo?)
        XCTAssertEqual(try JSONDecoder().decode(KeyCombo?.self, from: data), combo)

        // 清掉之后存的是 null，读回来是 nil（和「没设过」分开）
        let cleared = try JSONEncoder().encode(nil as KeyCombo?)
        XCTAssertNil(try JSONDecoder().decode(KeyCombo?.self, from: cleared))
    }

    /// 两个默认值互不冲突，否则装上去就有一个永远不生效
    func testDefaultCombosDoNotCollide() {
        XCTAssertNotEqual(KeyCombo.defaultPanel, KeyCombo.defaultCharacter)
        XCTAssertFalse(KeyCombo.defaultPanel.matches(
            event(keyCode: KeyCombo.defaultCharacter.keyCode, flags: [.option, .command])
        ))
    }
}
