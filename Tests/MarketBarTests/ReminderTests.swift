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
