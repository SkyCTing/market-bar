import XCTest

@testable import MarketBar

/// 纯函数部分：排布与「该不该响」
final class WaterScheduleTests: XCTestCase {
    /// 固定时刻，不受跑测试当天日期影响
    private func at(_ hour: Int, _ minute: Int, day: Int = 15) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = day
        components.hour = hour
        components.minute = minute
        return TradingSession.calendar.date(from: components)!
    }

    private func plan(
        start: Int = 9 * 60, end: Int = 21 * 60, cups: Int = 8, enabled: Bool = true
    ) -> WaterPlan {
        var plan = WaterPlan()
        plan.isEnabled = enabled
        plan.startMinutes = start
        plan.endMinutes = end
        plan.cups = cups
        return plan
    }

    private func hours(_ dates: [Date]) -> [(Int, Int)] {
        dates.map { date in
            let parts = TradingSession.calendar.dateComponents([.hour, .minute], from: date)
            return (parts.hour ?? -1, parts.minute ?? -1)
        }
    }

    func testTimesSplitTheWindowEvenly() {
        // 9:00–21:00、8 杯 → 每 1.5 小时一杯；最后一杯落在开始 + 7 × 1.5h = 19:30。
        // （除数用杯数而不是杯数−1，所以末尾会留一个间隔 —— 这是为了让「每 1.5 小时」
        //   这个说法成立，间隔 1 小时 43 分和用户脑子里的数对不上）
        let times = hours(WaterSchedule.times(in: plan(), on: at(0, 0)))
        XCTAssertEqual(times.map { "\($0.0):\(String(format: "%02d", $0.1))" },
                       ["9:00", "10:30", "12:00", "13:30", "15:00", "16:30", "18:00", "19:30"])
        XCTAssertEqual(times.count, 8)
    }

    func testSingleCupLandsAtStart() {
        let times = hours(WaterSchedule.times(in: plan(cups: 1), on: at(0, 0)))
        XCTAssertEqual(times.count, 1)
        XCTAssertEqual(times.first?.0, 9)
        XCTAssertEqual(times.first?.1, 0)
    }

    func testCupCountIsClampedToSomethingSane() {
        // 0 / 负数会让均分算出除零，别崩
        XCTAssertEqual(plan(cups: 0).effectiveCups, WaterPlan.cupRange.lowerBound)
        XCTAssertEqual(plan(cups: -5).effectiveCups, WaterPlan.cupRange.lowerBound)
        XCTAssertEqual(plan(cups: 999).effectiveCups, WaterPlan.cupRange.upperBound)
    }

    func testReversedWindowIsSwappedInsteadOfRejected() {
        // 把结束时间调到开始之前是很自然的误操作，按「他就是要一个区间」理解
        let reversed = plan(start: 21 * 60, end: 9 * 60, cups: 4)
        XCTAssertEqual(reversed.effectiveWindow.start, 9 * 60)
        XCTAssertEqual(reversed.effectiveWindow.end, 21 * 60)
        XCTAssertEqual(WaterSchedule.times(in: reversed, on: at(0, 0)).count, 4)
    }

    func testNextTimeSkipsForwardPastNow() {
        // 10:00 时，下一次是 10:30
        let next = WaterSchedule.nextTime(after: at(10, 0), plan: plan(), progress: WaterProgress())
        let parts = TradingSession.calendar.dateComponents([.hour, .minute], from: next!)
        XCTAssertEqual(parts.hour, 10)
        XCTAssertEqual(parts.minute, 30)
    }

    func testNextTimeIsNilWhenAlreadyDrunkEnough() {
        let full = WaterProgress(day: "2026-06-15", drunk: 8)
        XCTAssertNil(WaterSchedule.nextTime(after: at(10, 0), plan: plan(), progress: full))
    }

    func testNextTimeIsNilAfterTheWindow() {
        // 20:00 之后只剩 19:30 那一杯，已经过了 → 今天不再提醒
        XCTAssertNil(WaterSchedule.nextTime(after: at(20, 0), plan: plan(), progress: WaterProgress()))
    }

    func testNextTimeIsNilWhenDisabled() {
        XCTAssertNil(WaterSchedule.nextTime(after: at(10, 0), plan: plan(enabled: false), progress: WaterProgress()))
    }

    func testDueCupPicksTheMostRecentOne() {
        // 10:35 时最近刚过的是 10:30 那杯（index 1）
        XCTAssertEqual(WaterSchedule.dueCup(at: at(10, 35), plan: plan(), fired: []), 1)
        // 正好卡在点上也算
        XCTAssertEqual(WaterSchedule.dueCup(at: at(12, 0), plan: plan(), fired: []), 2)
    }

    func testDueCupDoesNotBackfillMissedOnes() {
        // ⚠️ 这条钉的是「错过不补」：23:00 打开 app 时，今天已经过了 8 杯，
        // 但最近那杯（19:30）距今 3.5 小时 > 一个间隔，所以一杯都不该补 ——
        // 否则关几天再打开会被一堆积压弹窗糊脸
        XCTAssertNil(WaterSchedule.dueCup(at: at(23, 0), plan: plan(), fired: []))
        // 边界：刚过一个间隔以内还是要响的
        XCTAssertEqual(WaterSchedule.dueCup(at: at(20, 30), plan: plan(), fired: []), 7)
    }

    func testDueCupIsNilWhenTheRecentOneAlreadyFired() {
        // 最近那杯响过了就不再往前找更早的 —— 那些属于「错过」
        XCTAssertNil(WaterSchedule.dueCup(at: at(10, 35), plan: plan(), fired: [1]))
    }

    func testDueCupIsNilWhenDisabled() {
        XCTAssertNil(WaterSchedule.dueCup(at: at(10, 35), plan: plan(enabled: false), fired: []))
    }

    func testTextFormat() {
        XCTAssertEqual(WaterSchedule.text(drunk: 3, cups: 8), "3/8")
    }

    // MARK: - 自定义每一杯的时刻

    private func custom(_ minutes: [Int]) -> WaterPlan {
        var plan = WaterPlan()
        plan.isEnabled = true
        plan.customTimes = minutes
        return plan
    }

    func testCustomTimesOverrideTheEvenDivision() {
        // 9:00–21:00 均分本该是 9:00 / 10:30 / …，自定义之后一律以自定义为准
        let plan = custom([9 * 60, 14 * 60, 16 * 60 + 20])
        XCTAssertEqual(hours(WaterSchedule.times(in: plan, on: at(0, 0))).map { "\($0.0):\(String(format: "%02d", $0.1))" },
                       ["9:00", "14:00", "16:20"])
    }

    func testCustomTimesAreSortedAndDriveTheCupCount() {
        // 乱序进来也要按时间先后排好
        let plan = custom([16 * 60, 9 * 60, 14 * 60])
        XCTAssertEqual(plan.cupMinutes, [9 * 60, 14 * 60, 16 * 60])
        // 杯数这时以自定义列表为准，不是 plan.cups（默认 8）
        XCTAssertEqual(plan.effectiveCups, 3)
    }

    func testEmptyCustomTimesFallsBackToEvenDivision() {
        var plan = WaterPlan()
        plan.customTimes = []
        XCTAssertEqual(plan.cupMinutes, plan.evenMinutes)
        XCTAssertEqual(plan.effectiveCups, 8)
    }

    func testFreshnessWindowUsesTheSmallestGap() {
        // ⚠️ 自定义时刻可能疏密不均。窗口取**最小**间隔才不会被稀疏的一段放大：
        // 9:00 / 9:30 / 18:00 的最小间隔是 30 分钟，所以 18:45 时那杯 18:00
        // 已经「凉了」，不该补响（用平均或最大间隔算的话都会误补）
        let plan = custom([9 * 60, 9 * 60 + 30, 18 * 60])
        XCTAssertEqual(WaterSchedule.freshnessWindow(plan), 30 * 60)
        XCTAssertNil(WaterSchedule.dueCup(at: at(18, 45), plan: plan, fired: []))
        // 还在窗口内就正常响
        XCTAssertEqual(WaterSchedule.dueCup(at: at(18, 10), plan: plan, fired: []), 2)
    }

    func testSingleCupGetsAnHourWideWindow() {
        let plan = custom([10 * 60])
        XCTAssertEqual(WaterSchedule.freshnessWindow(plan), 60 * 60)
        XCTAssertEqual(WaterSchedule.dueCup(at: at(10, 30), plan: plan, fired: []), 0)
        XCTAssertNil(WaterSchedule.dueCup(at: at(11, 30), plan: plan, fired: []))
    }
}

/// 状态与持久化
@MainActor
final class WaterTrackerTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "WaterTrackerTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
    }

    private func day(_ n: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = n
        components.hour = 10
        return TradingSession.calendar.date(from: components)!
    }

    func testStartsDisabledAndEmpty() {
        let tracker = WaterTracker(defaults: defaults)
        XCTAssertFalse(tracker.isEnabled, "默认关 —— 装上去不该自己开始提醒")
        XCTAssertEqual(tracker.progress.drunk, 0)
        XCTAssertNil(tracker.plaqueText, "没开就不该占着人物头顶那个位置")
    }

    func testRecordIncrementsAndStopsAtTheTarget() {
        let tracker = WaterTracker(defaults: defaults)
        var plan = WaterPlan()
        plan.isEnabled = true
        plan.cups = 2
        tracker.setPlan(plan)

        XCTAssertTrue(tracker.record(now: day(15)))
        XCTAssertEqual(tracker.progress.drunk, 1)
        XCTAssertTrue(tracker.record(now: day(15)))
        XCTAssertEqual(tracker.progress.drunk, 2)
        // 喝够了就不再涨
        XCTAssertFalse(tracker.record(now: day(15)))
        XCTAssertEqual(tracker.progress.drunk, 2)
    }

    func testProgressResetsOnANewDay() {
        let tracker = WaterTracker(defaults: defaults)
        var plan = WaterPlan()
        plan.isEnabled = true
        tracker.setPlan(plan)

        tracker.record(now: day(15))
        tracker.record(now: day(15))
        XCTAssertEqual(tracker.progress.drunk, 2)

        // app 一直开着跨零点：第二天记第一杯时应当先归零
        XCTAssertTrue(tracker.record(now: day(16)))
        XCTAssertEqual(tracker.progress.drunk, 1)
    }

    func testFiredCupsResetOnANewDay() {
        let tracker = WaterTracker(defaults: defaults)
        var plan = WaterPlan()
        plan.isEnabled = true
        plan.cups = 2
        plan.startMinutes = 9 * 60
        plan.endMinutes = 21 * 60
        tracker.setPlan(plan)
        tracker.markFired(0)

        tracker.resetIfNewDay(now: day(16))
        // 已经响过的那一杯不该带到第二天（否则第二天这杯永远不响）
        XCTAssertEqual(tracker.dueCup(at: day(16), calendar: TradingSession.calendar), 0)
    }

    func testPlanSurvivesRestart() {
        let first = WaterTracker(defaults: defaults)
        var plan = WaterPlan()
        plan.isEnabled = true
        plan.cups = 6
        plan.startMinutes = 8 * 60 + 30
        first.setPlan(plan)
        first.record(now: day(15))

        let second = WaterTracker(defaults: defaults)
        XCTAssertTrue(second.isEnabled)
        XCTAssertEqual(second.plan.effectiveCups, 6)
        XCTAssertEqual(second.plan.startMinutes, 8 * 60 + 30)
        XCTAssertEqual(second.progress.drunk, 1)
    }

    func testCorruptStateFallsBackToDefaultsWithoutWipingTheKey() {
        defaults.set(Data("not json".utf8), forKey: WaterTracker.stateKey)
        let tracker = WaterTracker(defaults: defaults)
        XCTAssertFalse(tracker.isEnabled)
        XCTAssertEqual(tracker.progress.drunk, 0)
        // 坏数据留着别删 —— 改回正确配置后下一版还读得到
        XCTAssertNotNil(defaults.data(forKey: WaterTracker.stateKey))
    }

    func testAlertKeyStaysStableAcrossPlanChanges() {
        // ⚠️ 这条钉的是会议模式补放：`stillValid` 靠这个 key 认领喝水提醒。
        // 它一变，会议期间攒下的那条就会被当成「已删除」丢掉
        let tracker = WaterTracker(defaults: defaults)
        let original = tracker.alertKey

        var plan = WaterPlan()
        plan.isEnabled = true
        plan.cups = 4
        plan.alertKey = UUID()          // 就算外面塞了个新的，也不该生效
        tracker.setPlan(plan)

        XCTAssertEqual(tracker.alertKey, original)
        XCTAssertEqual(WaterTracker(defaults: defaults).alertKey, original, "重启后也要是同一个")
    }

    func testPlaqueTextShowsProgressOnlyWhenEnabled() {
        let tracker = WaterTracker(defaults: defaults)
        var plan = WaterPlan()
        plan.cups = 8
        tracker.setPlan(plan)
        XCTAssertNil(tracker.plaqueText)

        plan.isEnabled = true
        tracker.setPlan(plan)
        tracker.record()
        XCTAssertEqual(tracker.plaqueText, "💧 1/8")
    }
}

/// 设置表单：读出来的配置对不对
@MainActor
final class WaterSettingsViewTests: XCTestCase {
    private func plan(cups: Int = 8, start: Int = 9 * 60, end: Int = 21 * 60) -> WaterPlan {
        var plan = WaterPlan()
        plan.isEnabled = true
        plan.cups = cups
        plan.startMinutes = start
        plan.endMinutes = end
        return plan
    }

    /// 表单里那 16 个「每杯时刻」选择器（前两个是起止时间，跳过）
    private func cupPickers(_ view: WaterSettingsView) -> [NSDatePicker] {
        view.subviews.compactMap { $0 as? NSDatePicker }.dropFirst(2).filter { !$0.isHidden }
    }

    func testSavingWithoutChangingAnythingStaysOnTheEvenDivision() {
        let view = WaterSettingsView(plan: plan())
        XCTAssertEqual(view.plan.customTimes, [], "没动过任何一杯，就不该变成「自定义」")
        XCTAssertEqual(view.plan.cupMinutes.count, 8)
    }

    func testShrinkingTheCupCountDoesNotLeakHiddenPickers() {
        // ⚠️ 复现用户报的 bug：设 16 杯再改回 8 杯，保存后再打开变成 16 杯。
        // 原因是藏起来的那 8 个选择器还留着 16 杯时的值，
        // 而保存时把 16 个全读了
        let view = WaterSettingsView(plan: plan(cups: 16))
        view.setCupCount(8)

        XCTAssertEqual(view.plan.cupMinutes.count, 8, "杯数不能因为藏起来的选择器而翻倍")
        XCTAssertEqual(view.plan.customTimes, [], "藏起来的那些值也不该被当成自定义")
    }

    func testGrowingTheCupCountAlsoStaysClean() {
        let view = WaterSettingsView(plan: plan(cups: 4))
        view.setCupCount(12)
        XCTAssertEqual(view.plan.cupMinutes.count, 12)
        XCTAssertEqual(view.plan.customTimes, [])
    }

    func testEditingOneCupMakesItCustom() {
        let view = WaterSettingsView(plan: plan())
        let pickers = cupPickers(view)
        XCTAssertEqual(pickers.count, 8)

        // 把第一杯从 9:00 改成 9:07
        var components = DateComponents()
        components.year = 2000; components.month = 1; components.day = 1
        components.hour = 9; components.minute = 7
        pickers[0].dateValue = TradingSession.calendar.date(from: components)!

        let saved = view.plan
        XCTAssertEqual(saved.customTimes.count, 8, "改一杯之后要把 8 个都记下来")
        XCTAssertEqual(saved.customTimes.first, 9 * 60 + 7)
        // 其余几杯还是均分的值
        XCTAssertEqual(Array(saved.customTimes.dropFirst()), Array(saved.evenMinutes.dropFirst()))
    }

    func testDegenerateWindowStillHasOneCup() {
        // 起止拖成一样时不能变成「0 杯」（那会表现成永远不提醒，还看不出原因）
        let view = WaterSettingsView(plan: plan(cups: 8, start: 10 * 60, end: 10 * 60))
        XCTAssertEqual(view.plan.cupMinutes, [10 * 60])
    }
}
