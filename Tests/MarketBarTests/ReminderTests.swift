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
