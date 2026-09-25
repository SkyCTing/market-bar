import Foundation
import XCTest

@testable import MarketBar

final class ReminderSchedulerTests: XCTestCase {
    private let calendar = TradingSession.calendar

    private func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    private func reminder(_ rule: Reminder.Repeat, hour: Int = 9, minute: Int = 58) -> Reminder {
        Reminder(title: "t", body: "b", hour: hour, minute: minute, repeatRule: rule)
    }

    func testDailyFiresAtExactMinuteOnly() {
        let r = reminder(.daily)
        XCTAssertTrue(ReminderScheduler.isDue(r, at: at(23, 9, 58), calendar: calendar))
        XCTAssertFalse(ReminderScheduler.isDue(r, at: at(23, 9, 57), calendar: calendar))
        XCTAssertFalse(ReminderScheduler.isDue(r, at: at(23, 10, 58), calendar: calendar))
    }

    /// 2026-09-23 是周三（weekday = 4）
    func testWeeklyMatchesOnlyThatWeekday() {
        let wednesday = reminder(.weekly(weekday: 4))
        XCTAssertTrue(ReminderScheduler.isDue(wednesday, at: at(23, 9, 58), calendar: calendar))
        XCTAssertFalse(ReminderScheduler.isDue(wednesday, at: at(22, 9, 58), calendar: calendar))  // 周二
    }

    func testMonthlyMatchesOnlyThatDay() {
        let fifteenth = reminder(.monthly(day: 15))
        XCTAssertTrue(ReminderScheduler.isDue(fifteenth, at: at(15, 9, 58), calendar: calendar))
        XCTAssertFalse(ReminderScheduler.isDue(fifteenth, at: at(16, 9, 58), calendar: calendar))
    }

    /// 同一分钟只触发一次
    func testFireKeyDeduplicatesWithinTheSameMinute() {
        let r = reminder(.daily)
        XCTAssertEqual(
            ReminderScheduler.fireKey(r, at: at(23, 9, 58), calendar: calendar),
            ReminderScheduler.fireKey(r, at: at(23, 9, 58), calendar: calendar)
        )
        XCTAssertNotEqual(
            ReminderScheduler.fireKey(r, at: at(23, 9, 58), calendar: calendar),
            ReminderScheduler.fireKey(r, at: at(24, 9, 58), calendar: calendar)
        )
    }

    func testNextFireDate() {
        let daily = ReminderScheduler.nextFireDate(after: at(23, 10, 0), reminder: reminder(.daily), calendar: calendar)
        XCTAssertEqual(daily.map { calendar.dateComponents([.day, .hour, .minute], from: $0).day }, 24)

        // 每月 15 号：9/23 之后应该是 10/15
        let monthly = ReminderScheduler.nextFireDate(after: at(23, 10, 0), reminder: reminder(.monthly(day: 15)), calendar: calendar)
        XCTAssertEqual(monthly.map { calendar.dateComponents([.month, .day], from: $0).month }, 10)
        XCTAssertEqual(monthly.map { calendar.dateComponents([.month, .day], from: $0).day }, 15)
    }

    /// 每月 31 号：当月没有 31 号就跳过，不会提前到 30 号
    func testMonthly31SkipsShortMonths() {
        let after = at(30, 12, 0)   // 9/30
        let next = ReminderScheduler.nextFireDate(after: after, reminder: reminder(.monthly(day: 31)), calendar: calendar)

        XCTAssertEqual(next.map { calendar.dateComponents([.month, .day], from: $0).month }, 10)
        XCTAssertEqual(next.map { calendar.dateComponents([.month, .day], from: $0).day }, 31)
    }

    @MainActor
    func testStoreRoundTrip() throws {
        let suiteName = "ReminderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ReminderStore(defaults: defaults)
        XCTAssertTrue(store.reminders.isEmpty)

        store.upsert(Reminder(title: "还信用卡", body: "还信用卡", hour: 9, minute: 58, repeatRule: .monthly(day: 15)))
        XCTAssertEqual(store.reminders.count, 1)

        let reloaded = ReminderStore(defaults: defaults)
        XCTAssertEqual(reloaded.reminders.first?.body, "还信用卡")
        XCTAssertEqual(reloaded.reminders.first?.repeatRule, .monthly(day: 15))

        reloaded.removeAll()
        XCTAssertTrue(ReminderStore(defaults: defaults).reminders.isEmpty)
    }
}

/// 第二轮改进：秒级 + 节假日开关
final class ReminderSecondAndHolidayTests: XCTestCase {
    private let calendar = TradingSession.calendar
    private let holiday = ["2026-10-01": "国庆节"]

    private func at(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: 2026, month: 9, day: day, hour: hour, minute: minute, second: second
        ))!
    }

    func testFiresAtExactSecond() {
        var r = Reminder(title: "t", body: "b", hour: 9, minute: 58)
        r.second = 30

        XCTAssertTrue(ReminderScheduler.isDue(r, at: at(23, 9, 58, 30), calendar: calendar))
        XCTAssertFalse(ReminderScheduler.isDue(r, at: at(23, 9, 58, 29), calendar: calendar))
        XCTAssertFalse(ReminderScheduler.isDue(r, at: at(23, 9, 58, 31), calendar: calendar))
    }

    /// 不勾选（默认）→ 节假日照常提醒
    func testHolidayStillFiresWhenSkipIsOff() {
        let r = Reminder(title: "t", body: "b", hour: 9, minute: 0)   // skipHolidays 默认 false
        let nationalDay = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 9, minute: 0))!

        XCTAssertFalse(r.skipHolidays)
        XCTAssertTrue(ReminderScheduler.isDue(r, at: nationalDay, holidays: holiday, calendar: calendar))
    }

    /// 勾选 → 法定节假日与周末都不提醒
    func testSkipHolidaysSuppressesHolidayAndWeekend() {
        var r = Reminder(title: "t", body: "b", hour: 9, minute: 0)
        r.skipHolidays = true

        let nationalDay = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 9, minute: 0))!
        XCTAssertFalse(ReminderScheduler.isDue(r, at: nationalDay, holidays: holiday, calendar: calendar))

        // 2026-09-26 是周六
        XCTAssertFalse(ReminderScheduler.isDue(r, at: at(26, 9, 0), holidays: holiday, calendar: calendar))
        // 工作日照常
        XCTAssertTrue(ReminderScheduler.isDue(r, at: at(23, 9, 0), holidays: holiday, calendar: calendar))
    }

    /// 勾选后算下一次触发时间也要跳过节假日
    func testNextFireDateSkipsHolidaysWhenEnabled() {
        var r = Reminder(title: "t", body: "b", hour: 9, minute: 0)
        r.skipHolidays = true

        // 从 9/30 出发，每天都提醒：下一次应该是 10/8（10/1 节假日、10/3-4 周末…）
        let next = ReminderScheduler.nextFireDate(
            after: at(30, 12, 0), reminder: r, holidays: holiday, calendar: calendar
        )
        let day = next.map { calendar.dateComponents([.month, .day], from: $0) }
        XCTAssertNotEqual(day?.day, 1, "不该落在国庆节")
    }

    /// 旧数据（没有 second / skipHolidays 字段）要能解出来，而不是把整个列表清空
    func testDecodesLegacyPayloadWithoutNewFields() throws {
        let legacy = #"[{"id":"11111111-2222-3333-4444-555555555555","title":"还信用卡","body":"还信用卡","hour":9,"minute":58,"repeatRule":{"daily":{}}}]"#
        let decoded = try JSONDecoder().decode([Reminder].self, from: Data(legacy.utf8))

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.hour, 9)
        XCTAssertEqual(decoded.first?.second, 0)
        XCTAssertFalse(decoded.first?.skipHolidays ?? true)
    }
}

/// 「每 N 天」重复规则
final class ReminderEveryDaysTests: XCTestCase {
    private let calendar = TradingSession.calendar

    private func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    private func everyDays(_ interval: Int, anchor: String = "2026-09-01") -> Reminder {
        var r = Reminder(title: "t", body: "b", hour: 9, minute: 0)
        r.repeatRule = .everyDays(interval: interval)
        r.anchorDay = anchor
        return r
    }

    func testDaysBetween() {
        XCTAssertEqual(ReminderScheduler.daysBetween("2026-09-01", and: at(4, 9, 0), calendar: calendar), 3)
        XCTAssertEqual(ReminderScheduler.daysBetween("2026-09-01", and: at(1, 23, 59), calendar: calendar), 0)
        XCTAssertNil(ReminderScheduler.daysBetween("", and: at(1, 9, 0), calendar: calendar))
        XCTAssertNil(ReminderScheduler.daysBetween("不是日期", and: at(1, 9, 0), calendar: calendar))
    }

    /// 锚点 9/1，每 3 天 → 9/1、9/4、9/7 触发；9/2、9/3 不触发
    func testEveryThreeDays() {
        let r = everyDays(3)
        XCTAssertTrue(ReminderScheduler.isDue(r, at: at(1, 9, 0), calendar: calendar))
        XCTAssertFalse(ReminderScheduler.isDue(r, at: at(2, 9, 0), calendar: calendar))
        XCTAssertFalse(ReminderScheduler.isDue(r, at: at(3, 9, 0), calendar: calendar))
        XCTAssertTrue(ReminderScheduler.isDue(r, at: at(4, 9, 0), calendar: calendar))
        XCTAssertTrue(ReminderScheduler.isDue(r, at: at(7, 9, 0), calendar: calendar))
    }

    /// 时间不匹配照样不触发
    func testEveryDaysStillRequiresTheTime() {
        XCTAssertFalse(ReminderScheduler.isDue(everyDays(1), at: at(2, 9, 1), calendar: calendar))
    }

    /// 锚点缺失时按「该提醒」处理，不要因为数据缺字段而漏提醒
    func testMissingAnchorFailsOpen() {
        XCTAssertTrue(ReminderScheduler.isDue(everyDays(3, anchor: ""), at: at(2, 9, 0), calendar: calendar))
    }

    func testNextFireDateForEveryDays() {
        // 9/2 12:00（锚点 9/1、每 3 天）→ 下一次应是 9/4 09:00
        let next = ReminderScheduler.nextFireDate(after: at(2, 12, 0), reminder: everyDays(3), calendar: calendar)
        let parts = next.map { calendar.dateComponents([.month, .day, .hour], from: $0) }
        XCTAssertEqual(parts?.day, 4)
        XCTAssertEqual(parts?.hour, 9)
    }

    func testTitleShowsInterval() {
        XCTAssertEqual(Reminder.Repeat.everyDays(interval: 5).title, "每5天")
    }
}

/// 「智能跳过节假日」：补班的周末算工作日，照常提醒
final class ReminderMakeupWorkdayTests: XCTestCase {
    private let calendar = TradingSession.calendar

    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: 0))!
    }

    private var smartReminder: Reminder {
        var r = Reminder(title: "t", body: "b", hour: 9, minute: 0)
        r.skipHolidays = true
        return r
    }

    /// 2026-09-26 是周六：普通周末 → 跳过
    func testNormalSaturdayIsSkipped() {
        XCTAssertFalse(ReminderScheduler.isDue(smartReminder, at: at(2026, 9, 26), calendar: calendar))
    }

    /// 同一个周六，如果它是调休补班日 → 照常提醒
    func testMakeupSaturdayStillFires() {
        XCTAssertTrue(ReminderScheduler.isDue(
            smartReminder,
            at: at(2026, 9, 26),
            holidays: [:],
            makeupWorkdays: ["2026-09-26"],
            calendar: calendar
        ))
    }

    /// 法定节假日即使被标成补班也还是休息日（holidays 优先）
    func testHolidayWinsOverMakeupFlag() {
        XCTAssertFalse(ReminderScheduler.isDue(
            smartReminder,
            at: at(2026, 10, 1),
            holidays: ["2026-10-01": "国庆节"],
            makeupWorkdays: ["2026-10-01"],
            calendar: calendar
        ))
    }

    func testParsesMakeupWorkdaysFromPayload() {
        let json = """
        {"code":0,"holiday":{
          "10-01":{"holiday":true,"name":"国庆节","date":"2026-10-01"},
          "10-10":{"holiday":false,"name":"国庆节后补班","date":"2026-10-10"},
          "01-01":{"holiday":true,"name":"元旦","date":"2026-01-01"}}}
        """
        let makeup = MarketCalendar.parseMakeupWorkdays(Data(json.utf8))

        XCTAssertEqual(makeup, ["2026-10-10"])
    }

    func testIsRestDayRules() {
        // 普通周三 → 工作日
        XCTAssertFalse(MarketCalendar.isRestDay(at(2026, 9, 23), holidays: [:], calendar: calendar))
        // 周六 → 休息日
        XCTAssertTrue(MarketCalendar.isRestDay(at(2026, 9, 26), holidays: [:], calendar: calendar))
        // 补班的周六 → 工作日
        XCTAssertFalse(MarketCalendar.isRestDay(
            at(2026, 9, 26), holidays: [:], makeupWorkdays: ["2026-09-26"], calendar: calendar
        ))
        // 法定节假日 → 休息日
        XCTAssertTrue(MarketCalendar.isRestDay(
            at(2026, 10, 1), holidays: ["2026-10-01": "国庆节"], calendar: calendar
        ))
    }

    func testMakeupWorkdayCacheRoundTrip() throws {
        let suiteName = "MakeupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        MarketCalendar.HolidayCache.saveMakeupWorkdays(["2026-10-10"], year: 2026, to: defaults)
        XCTAssertEqual(MarketCalendar.HolidayCache.loadMakeupWorkdays(year: 2026, from: defaults), ["2026-10-10"])
        XCTAssertTrue(MarketCalendar.HolidayCache.loadMakeupWorkdays(year: 2027, from: defaults).isEmpty)
    }
}

// MARK: - 倒计时与提醒方式（第三轮）

final class CountdownFormatTests: XCTestCase {
    func testRemainingUnderAnHour() {
        XCTAssertEqual(CountdownFormat.remaining(1_499), "24:59")
        XCTAssertEqual(CountdownFormat.remaining(60), "01:00")
        XCTAssertEqual(CountdownFormat.remaining(9), "00:09")
        XCTAssertEqual(CountdownFormat.remaining(0), "00:00")
    }

    func testRemainingOverAnHour() {
        XCTAssertEqual(CountdownFormat.remaining(3_600), "1:00:00")
        XCTAssertEqual(CountdownFormat.remaining(3_753), "1:02:33")
    }

    func testRemainingOverADay() {
        XCTAssertEqual(CountdownFormat.remaining(90_000), "1天 01:00:00")
    }

    /// 还剩 0.4 秒时显示 00:01 而不是 00:00 —— 「显示 0 了却还没响」很让人困惑
    func testRemainingRoundsUp() {
        XCTAssertEqual(CountdownFormat.remaining(0.4), "00:01")
        XCTAssertEqual(CountdownFormat.remaining(59.2), "01:00")
    }

    /// app 睡过头时可能算出负数，不能显示成 "-1:-30"
    func testRemainingClampsNegatives() {
        XCTAssertEqual(CountdownFormat.remaining(-5), "00:00")
        XCTAssertEqual(CountdownFormat.remaining(-99_999), "00:00")
    }

    func testDurationText() {
        XCTAssertEqual(CountdownFormat.duration(1_500), "25 分钟")
        XCTAssertEqual(CountdownFormat.duration(45), "45 秒")
        XCTAssertEqual(CountdownFormat.duration(90), "1 分钟 30 秒")
        XCTAssertEqual(CountdownFormat.duration(3_600), "1 小时")
        XCTAssertEqual(CountdownFormat.duration(5_400), "1 小时 30 分钟")
        XCTAssertEqual(CountdownFormat.duration(0), "0 秒")
        XCTAssertEqual(CountdownFormat.duration(-5), "0 秒")
    }

    /// 有小时的时候不再啰嗦到秒
    func testDurationDropsSecondsOnceThereAreHours() {
        XCTAssertEqual(CountdownFormat.duration(3_690), "1 小时 1 分钟")
        XCTAssertEqual(CountdownFormat.duration(3_630), "1 小时", "秒被丢掉，分钟又是 0，就只剩小时")
    }
}

final class ReminderCountdownTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func countdown(seconds: Int, repeats: Bool = false) -> Reminder {
        var reminder = Reminder(title: "泡茶", body: "泡茶", hour: 0, minute: 0)
        reminder.kind = .countdown
        reminder.countdownSeconds = seconds
        reminder.countdownStartedAt = start
        reminder.repeatsCountdown = repeats
        return reminder
    }

    func testDeadlineIsStartPlusDuration() {
        XCTAssertEqual(
            ReminderScheduler.countdownDeadline(countdown(seconds: 1_500)),
            start.addingTimeInterval(1_500)
        )
    }

    /// 没在跑就没有到点时刻：一次性倒计时响过之后 startedAt 会被置空
    func testDeadlineIsNilWhenNotRunning() {
        var reminder = countdown(seconds: 60)
        reminder.countdownStartedAt = nil

        XCTAssertNil(ReminderScheduler.countdownDeadline(reminder))
    }

    func testDeadlineIsNilForScheduledReminders() {
        let scheduled = Reminder(title: "t", body: "b", hour: 9, minute: 0)

        XCTAssertNil(ReminderScheduler.countdownDeadline(scheduled))
    }

    func testDeadlineIsNilForZeroDuration() {
        XCTAssertNil(ReminderScheduler.countdownDeadline(countdown(seconds: 0)))
    }

    func testIsDueOnlyAfterTheDeadline() {
        let reminder = countdown(seconds: 600)

        XCTAssertFalse(ReminderScheduler.isDue(reminder, at: start))
        XCTAssertFalse(ReminderScheduler.isDue(reminder, at: start.addingTimeInterval(599)))
        XCTAssertTrue(ReminderScheduler.isDue(reminder, at: start.addingTimeInterval(600)))
        XCTAssertTrue(ReminderScheduler.isDue(reminder, at: start.addingTimeInterval(9_999)), "过期很久也算到点")
    }

    /// 倒计时不该被重复规则或节假日影响：它就是「从现在起 N 分钟后叫我」
    func testCountdownIgnoresRepeatRuleAndHolidays() {
        var reminder = countdown(seconds: 60)
        reminder.skipHolidays = true
        reminder.hour = 9
        reminder.minute = 30

        // 到达时刻是 00:10（start 是整点），跟 hour/minute 完全对不上，仍然要触发
        XCTAssertTrue(ReminderScheduler.isDue(
            reminder,
            at: start.addingTimeInterval(60),
            holidays: ["2026-09-25": "中秋节"]
        ))
    }

    /// 没在跑的倒计时永远不会到点
    func testNotRunningCountdownIsNeverDue() {
        var reminder = countdown(seconds: 60)
        reminder.countdownStartedAt = nil

        XCTAssertFalse(ReminderScheduler.isDue(reminder, at: start.addingTimeInterval(9_999)))
    }

    func testNextFireDateIsTheDeadline() {
        let reminder = countdown(seconds: 1_500)

        XCTAssertEqual(
            ReminderScheduler.nextFireDate(after: start, reminder: reminder),
            start.addingTimeInterval(1_500)
        )
    }

    /// app 关着的时候到点了：重启后要立刻触发，而不是等下一轮
    func testOverdueCountdownFiresImmediately() {
        let reminder = countdown(seconds: 60)
        let later = start.addingTimeInterval(9_999)

        XCTAssertEqual(ReminderScheduler.nextFireDate(after: later, reminder: reminder), later)
    }

    func testNextFireDateIsNilWhenNotRunning() {
        var reminder = countdown(seconds: 60)
        reminder.countdownStartedAt = nil

        XCTAssertNil(ReminderScheduler.nextFireDate(after: start, reminder: reminder))
    }

    func testRemainingText() {
        let reminder = countdown(seconds: 1_500)

        XCTAssertEqual(ReminderScheduler.remainingText(reminder, at: start), "25:00")
        XCTAssertEqual(ReminderScheduler.remainingText(reminder, at: start.addingTimeInterval(60)), "24:00")
        XCTAssertNil(ReminderScheduler.remainingText(Reminder(title: "t", body: "b", hour: 9, minute: 0), at: start))
    }

    /// 一次性：响完就停，不再有下一次
    func testAfterFiringStopsOneShot() {
        let fired = ReminderScheduler.afterCountdownFired(countdown(seconds: 60), at: start.addingTimeInterval(60))

        XCTAssertNil(fired.countdownStartedAt)
        XCTAssertNil(ReminderScheduler.countdownDeadline(fired))
    }

    /// 循环：从现在重新起算
    func testAfterFiringRestartsLooping() {
        let fireTime = start.addingTimeInterval(60)
        let fired = ReminderScheduler.afterCountdownFired(countdown(seconds: 60, repeats: true), at: fireTime)

        XCTAssertEqual(fired.countdownStartedAt, fireTime)
        XCTAssertEqual(ReminderScheduler.countdownDeadline(fired), fireTime.addingTimeInterval(60))
    }

    /// 用「实际响的时刻」重新起算：睡了一觉醒来不会连着补响好几轮
    func testLoopingRestartsFromTheActualFireTime() {
        let late = start.addingTimeInterval(10_000)
        let fired = ReminderScheduler.afterCountdownFired(countdown(seconds: 60, repeats: true), at: late)

        XCTAssertEqual(ReminderScheduler.countdownDeadline(fired), late.addingTimeInterval(60))
        XCTAssertFalse(ReminderScheduler.isDue(fired, at: late), "刚重开的一轮不该立刻又响")
    }

    func testSummaryShowsDurationAndLoop() {
        XCTAssertEqual(countdown(seconds: 1_500).summary, "25 分钟  一次 · 泡茶")
        XCTAssertEqual(countdown(seconds: 1_500, repeats: true).summary, "25 分钟  循环 · 泡茶")
    }

    func testScheduledSummaryIsUnchanged() {
        let scheduled = Reminder(title: "t", body: "还信用卡", hour: 9, minute: 58, repeatRule: .monthly(day: 15))

        XCTAssertEqual(scheduled.summary, "09:58:00  每月15号 · 还信用卡")
    }
}

final class ReminderMethodsTests: XCTestCase {
    func testDefaultIsBoth() {
        XCTAssertEqual(Reminder.Methods.default, [.bubble, .alert])
    }

    func testTitles() {
        XCTAssertEqual(Reminder.Methods([.bubble, .alert]).title, "宠物提示 + 弹窗")
        XCTAssertEqual(Reminder.Methods.bubble.title, "宠物提示")
        XCTAssertEqual(Reminder.Methods.alert.title, "弹窗")
        XCTAssertEqual(Reminder.Methods([]).title, "不提醒")
    }

    func testCodableRoundTrip() throws {
        for methods in [Reminder.Methods.bubble, .alert, [.bubble, .alert]] as [Reminder.Methods] {
            var reminder = Reminder(title: "t", body: "b", hour: 9, minute: 0)
            reminder.methods = methods

            let data = try JSONEncoder().encode(reminder)
            let decoded = try JSONDecoder().decode(Reminder.self, from: data)

            XCTAssertEqual(decoded.methods, methods)
        }
    }

    /// 存成一个整数，不是 {"rawValue": 3}
    func testEncodesAsASingleValue() throws {
        var reminder = Reminder(title: "t", body: "b", hour: 9, minute: 0)
        reminder.methods = [.bubble, .alert]

        let json = String(decoding: try JSONEncoder().encode(reminder), as: UTF8.self)

        XCTAssertTrue(json.contains("\"methods\":3"), "实际是 \(json)")
    }

    /// 升级上来的旧提醒没有 kind / methods 两个键，必须仍然能解出来，
    /// 否则合成的解码器会抛 keyNotFound，把用户已有的提醒全清空
    func testDecodesLegacyReminderWithoutNewKeys() throws {
        let legacy = """
        {"id":"11111111-2222-3333-4444-555555555555","title":"还信用卡","body":"还信用卡",
         "hour":9,"minute":58,"second":0,"repeatRule":{"monthly":{"day":15}},
         "skipHolidays":false,"anchorDay":"2026-01-01"}
        """

        let reminder = try JSONDecoder().decode(Reminder.self, from: Data(legacy.utf8))

        XCTAssertEqual(reminder.kind, .scheduled)
        XCTAssertEqual(reminder.methods, .default, "旧数据升级后行为要和升级前一致")
        XCTAssertEqual(reminder.countdownSeconds, 0)
        XCTAssertNil(reminder.countdownStartedAt)
        XCTAssertFalse(reminder.repeatsCountdown)
        XCTAssertEqual(reminder.body, "还信用卡")
    }

    /// 最旧的那版连 second / skipHolidays 都没有
    func testDecodesVeryOldReminder() throws {
        let veryOld = """
        {"id":"11111111-2222-3333-4444-555555555555","title":"t","body":"b",
         "hour":9,"minute":0,"repeatRule":{"daily":{}}}
        """

        let reminder = try JSONDecoder().decode(Reminder.self, from: Data(veryOld.utf8))

        XCTAssertEqual(reminder.kind, .scheduled)
        XCTAssertEqual(reminder.methods, .default)
        XCTAssertEqual(reminder.second, 0)
        XCTAssertFalse(reminder.skipHolidays)
    }
}

// MARK: - 气泡到弹窗的等待时间

final class ReminderAcknowledgeOptionTests: XCTestCase {
    /// 用户 2026-09-25 明确要求：60 秒太久，默认 30 秒
    func testDefaultIsThirtySeconds() {
        XCTAssertEqual(ReminderAcknowledgeOption.defaultOption, .thirty)
        XCTAssertEqual(ReminderAcknowledgeOption.defaultOption.rawValue, 30)
    }

    func testOptionsAreOrdered() {
        let values = ReminderAcknowledgeOption.allCases.map(\.rawValue)

        XCTAssertEqual(values, values.sorted())
        XCTAssertTrue(values.contains(30), "默认那档必须在选项里，否则菜单选不中")
    }

    func testTitles() {
        XCTAssertEqual(ReminderAcknowledgeOption.ten.title, "10 秒")
        XCTAssertEqual(ReminderAcknowledgeOption.thirty.title, "30 秒")
        XCTAssertEqual(ReminderAcknowledgeOption.fortyFive.title, "45 秒")
        XCTAssertEqual(ReminderAcknowledgeOption.sixty.title, "1 分钟")
        XCTAssertEqual(ReminderAcknowledgeOption.ninety.title, "1 分 30 秒", "90 秒说成「1 分钟」是错的")
        XCTAssertEqual(ReminderAcknowledgeOption.twoMinutes.title, "2 分钟")
    }

    func testFallbackToDefaultForUnknownPersistedValue() {
        XCTAssertNil(ReminderAcknowledgeOption(rawValue: 7), "存档里的陌生值应当解不出，由调用方回退默认")
    }

    @MainActor
    func testCenterDefaultsToThirtySeconds() throws {
        let suiteName = "AcknowledgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let center = ReminderCenter(store: ReminderStore(defaults: defaults), characterController: FloatingCharacterController())

        XCTAssertEqual(center.acknowledgeWindow, 30)
    }

    @MainActor
    func testCenterTakesTheConfiguredValue() throws {
        let suiteName = "AcknowledgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let center = ReminderCenter(store: ReminderStore(defaults: defaults), characterController: FloatingCharacterController())
        center.acknowledgeWindow = ReminderAcknowledgeOption.ten.rawValue

        XCTAssertEqual(center.acknowledgeWindow, 10)
    }
}


// MARK: - 一条坏数据不能拖垮整份提醒列表

final class ReminderStoreRobustnessTests: XCTestCase {
    @MainActor
    private func store(_ suite: String) throws -> (ReminderStore, UserDefaults) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (ReminderStore(defaults: defaults), defaults)
    }

    /// ⚠️ 回归：以前是整份数组 `try? decode`，一条坏字段 → 内存里变空表 →
    /// 之后任何一次 save() 都把空表写回去，用户其余提醒永久丢失（实测过）。
    /// 现在逐条解码，只丢坏的那条。
    @MainActor
    func testOneBadEntryDoesNotWipeTheOthers() throws {
        let suite = "ReminderRobust.\(UUID().uuidString)"
        let (_, defaults) = try store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let raw = """
        [{"id":"11111111-2222-3333-4444-555555555555","title":"好1","body":"好1","hour":9,"minute":0,"repeatRule":{"daily":{}}},
         {"id":"22222222-2222-3333-4444-555555555555","title":"坏","body":"坏","hour":"九点","minute":0,"repeatRule":{"daily":{}}},
         {"id":"33333333-2222-3333-4444-555555555555","title":"好2","body":"好2","hour":10,"minute":0,"repeatRule":{"daily":{}}}]
        """
        defaults.set(Data(raw.utf8), forKey: "reminders")

        let store = ReminderStore(defaults: defaults)
        XCTAssertEqual(store.reminders.map(\.body), ["好1", "好2"], "只该丢坏的那条")

        // 再做一次写操作，好的那两条必须还在
        store.upsert(Reminder(title: "新", body: "新", hour: 8, minute: 0))

        let reread = ReminderStore(defaults: defaults)
        XCTAssertEqual(reread.reminders.map(\.body).sorted(), ["好1", "好2", "新"])
    }

    /// 整个键被写坏（连数组都解不出）时，保持内存里现有的，别清空
    @MainActor
    func testCompletelyBrokenPayloadKeepsExistingReminders() throws {
        let suite = "ReminderRobust.\(UUID().uuidString)"
        let (store, defaults) = try store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        store.upsert(Reminder(title: "保住我", body: "保住我", hour: 9, minute: 0))
        defaults.set(Data("不是 json".utf8), forKey: "reminders")

        store.reload()

        XCTAssertEqual(store.reminders.map(\.body), ["保住我"], "解不出来时不该把内存清空")
    }

    @MainActor
    func testMissingKeyMeansNoReminders() throws {
        let suite = "ReminderRobust.\(UUID().uuidString)"
        let (store, defaults) = try store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        store.reload()

        XCTAssertTrue(store.reminders.isEmpty)
    }
}
