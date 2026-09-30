import XCTest

@testable import MarketBar

/// 一份「当前在跑什么」的假状态机：退出会真的把它移除，
/// 这样「用户自己在会中又把微信开回来了」才模拟得出来
@MainActor
private final class SideEffectRecorder {
    var running: Set<String> = []
    var quit: [String] = []
    var launched: [String] = []
    var shortcuts: [String] = []
    /// 哪些「退出」会成功
    var quitSucceeds = true
    /// 退了却还在跑的（模拟退不掉的情况）
    var stillRunningAfterQuit: Set<String> = []
}

@MainActor
final class MeetingSideEffectsTests: XCTestCase {
    private let main = "com.tencent.xinWeChat"
    private let second = "com.tencent.xinWeChatSecond"

    private func makeEffects(_ recorder: SideEffectRecorder) -> MeetingSideEffects {
        var effects = MeetingSideEffects()
        effects.isRunning = { recorder.running.contains($0) }
        effects.quitApp = { bundleID in
            recorder.quit.append(bundleID)
            guard recorder.quitSucceeds else { return false }
            if !recorder.stillRunningAfterQuit.contains(bundleID) {
                recorder.running.remove(bundleID)
            }
            return true
        }
        effects.launchApp = { recorder.launched.append($0) }
        effects.runShortcut = { name in
            recorder.shortcuts.append(name)
            return true
        }
        return effects
    }

    func testQuitsOnlyTheWeChatsThatAreRunning() {
        let recorder = SideEffectRecorder()
        // 只开着主微信
        recorder.running = [main]
        let effects = makeEffects(recorder)

        let quit = effects.quitWeChats()

        XCTAssertEqual(quit, [main])
        XCTAssertEqual(recorder.quit, [main], "没在跑的那个不该去退")
    }

    func testQuitsBothWhenBothAreRunning() {
        let recorder = SideEffectRecorder()
        recorder.running = [main, second]
        let effects = makeEffects(recorder)
        XCTAssertEqual(Set(effects.quitWeChats()), [main, second])
    }

    func testNothingRunningQuitsNothing() {
        let recorder = SideEffectRecorder()
        let effects = makeEffects(recorder)
        XCTAssertTrue(effects.quitWeChats().isEmpty)
        XCTAssertTrue(recorder.quit.isEmpty)
    }

    func testQuitThatFailedIsNotRemembered() {
        let recorder = SideEffectRecorder()
        recorder.quitSucceeds = false
        recorder.running = [main]
        let effects = makeEffects(recorder)

        // 没退成功就不该记下来 —— 否则散会后会去「开回来」一个本来就还开着的
        XCTAssertTrue(effects.quitWeChats().isEmpty)
    }

    func testRestoreSkipsAppsThatCameBackOnTheirOwn() {
        let recorder = SideEffectRecorder()
        recorder.running = [main, second]
        let effects = makeEffects(recorder)
        let quit = effects.quitWeChats()
        XCTAssertEqual(Set(quit), [main, second], "前提：两个都被我们退了")

        // 用户在会中自己又把主微信开回来了
        recorder.running.insert(main)

        effects.restoreWeChats(quit)

        XCTAssertEqual(recorder.launched, [second], "已经自己起来的那个不该再被开一次")
    }

    func testRestoreDoesNothingForAnEmptyList() {
        let recorder = SideEffectRecorder()
        let effects = makeEffects(recorder)
        effects.restoreWeChats([])
        XCTAssertTrue(recorder.launched.isEmpty)
    }

    func testEmptyShortcutNameIsSkippedEntirely() {
        let recorder = SideEffectRecorder()
        let effects = makeEffects(recorder)

        // 没配快捷指令（留空）时不该去跑任何东西，也不算失败
        XCTAssertFalse(effects.applyFocus(shortcut: ""))
        XCTAssertFalse(effects.applyFocus(shortcut: "   \n "))
        XCTAssertTrue(recorder.shortcuts.isEmpty)
    }

    func testShortcutNameIsTrimmedBeforeRunning() {
        let recorder = SideEffectRecorder()
        let effects = makeEffects(recorder)

        XCTAssertTrue(effects.applyFocus(shortcut: "  会议开始  "))
        XCTAssertEqual(recorder.shortcuts, ["会议开始"])
    }

    func testQuitThenRestoreRoundTripsOnlyWhatWeQuit() {
        let recorder = SideEffectRecorder()
        recorder.running = [main, second]
        let effects = makeEffects(recorder)

        let quit = effects.quitWeChats()
        XCTAssertEqual(Set(quit), [main, second])

        effects.restoreWeChats(quit)
        XCTAssertEqual(Set(recorder.launched), [main, second], "退掉的两个都该开回来")
    }

    func testQuitWeChatListSurvivesRestart() throws {
        let suite = "MeetingSideEffectsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let mode = MeetingMode(defaults: defaults)
        XCTAssertTrue(mode.quitWeChatBundleIDs.isEmpty)
        mode.quitWeChatBundleIDs = [main]

        // 开会中途 app 重启：不记着这个，散会后微信就再也回不来了
        XCTAssertEqual(MeetingMode(defaults: defaults).quitWeChatBundleIDs, [main])

        mode.quitWeChatBundleIDs = []
        XCTAssertTrue(MeetingMode(defaults: defaults).quitWeChatBundleIDs.isEmpty)
    }
}
