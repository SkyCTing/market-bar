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
    /// AppleScript 报不报错。**注意这只是脚本的说法，不代表真退没退** ——
    /// app 退得快时回执收不到，脚本会报错但其实是退成功了的
    var quitReportsError = false
    /// 退了却还在跑的（模拟真没退掉的情况）
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
            // 实际状态：不在 stillRunningAfterQuit 里就是真退掉了
            if !recorder.stillRunningAfterQuit.contains(bundleID) {
                recorder.running.remove(bundleID)
            }
            // 脚本的说法（不可信）
            return !recorder.quitReportsError
        }
        effects.launchApp = { bundleID in
            recorder.launched.append(bundleID)
            // 开起来就是「在跑」了，否则后面 verifyRestored 会全报缺失
            recorder.running.insert(bundleID)
        }
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

        let attempted = effects.quitWeChats()

        XCTAssertEqual(attempted, [main], "没在跑的那个不该去退")
        XCTAssertEqual(recorder.quit, [main])
        XCTAssertTrue(effects.verifyQuit(attempted).isEmpty, "真退掉了就不该报失败")
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

    func testAppleScriptReportingAnErrorStillCountsAsRunningUntilVerified() {
        let recorder = SideEffectRecorder()
        recorder.running = [main]
        recorder.stillRunningAfterQuit = [main]   // 模拟：确实没退掉
        let effects = makeEffects(recorder)

        let attempted = effects.quitWeChats()
        XCTAssertEqual(attempted, [main], "尝试过就要记下来，散会后才知道该开回哪个")
        XCTAssertEqual(effects.verifyQuit(attempted), [main], "确实还在跑 → 报到失败里")
    }

    func testQuitThatActuallyWorkedIsNotReportedAsFailure() {
        // 这条钉的是那个假警报：微信退得极快，Apple Event 回执收不到，
        // AppleScript 会报错 —— 但它是**退出成功**的，不该弹框
        let recorder = SideEffectRecorder()
        recorder.running = [main]
        recorder.quitReportsError = true   // 脚本报错（回执丢了），但它其实已经退了
        let effects = makeEffects(recorder)

        let attempted = effects.quitWeChats()
        XCTAssertEqual(attempted, [main])
        XCTAssertTrue(effects.verifyQuit(attempted).isEmpty, "它已经没了 → 不该报失败")
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
        XCTAssertTrue(effects.verifyRestored(quit).isEmpty, "都起来了就该报「没有遗漏」")
        XCTAssertEqual(effects.verifyRestored([main, "+没起来+"]), ["+没起来+"], "没起来的要报出来")
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
