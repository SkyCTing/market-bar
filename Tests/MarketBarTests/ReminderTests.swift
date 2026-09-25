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
