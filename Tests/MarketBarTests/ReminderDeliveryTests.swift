import AppKit
import XCTest

@testable import MarketBar

@MainActor
final class ReminderDeliveryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var store: ReminderStore!
    private var center: ReminderCenter!

    override func setUp() async throws {
        suite = "ReminderDeliveryTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        store = ReminderStore(defaults: defaults)
        center = ReminderCenter(
            store: store,
            characterController: FloatingCharacterController(defaults: defaults, idleTimeProvider: { 0 })
        )
    }

    override func tearDown() async throws {
        center = nil
        store = nil
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
    }

    private var due: Date {
        TradingSession.calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 28, hour: 9, minute: 0, second: 0
        ))!
    }

    private func add(_ rule: Reminder.Repeat, second: Int = 0) -> Reminder {
        var reminder = Reminder(body: "测试", hour: 9, minute: 0, second: second, repeatRule: rule)
        reminder.anchorDay = "2026-09-28"
        store.upsert(reminder)
        return reminder
    }

    func testLateCallbackDeliversOneTimeReminderAndDoesNotRepeat() {
        let reminder = add(.once)
        let late = due.addingTimeInterval(2.4)
        XCTAssertFalse(ReminderScheduler.isDue(reminder, at: late))
        XCTAssertEqual(center.takeDueReminders(scheduledFor: due, at: late).map(\.id), [reminder.id])
        XCTAssertTrue(center.takeDueReminders(scheduledFor: due, at: late.addingTimeInterval(1)).isEmpty)
        XCTAssertEqual(store.reminders, [reminder], "确认或补响不删除原记录")
    }

    func testExactAndEarlyCallbacks() {
        let reminder = add(.once)
        XCTAssertTrue(center.takeDueReminders(scheduledFor: due, at: due.addingTimeInterval(-0.2)).isEmpty)
        XCTAssertEqual(center.takeDueReminders(scheduledFor: due, at: due).map(\.id), [reminder.id])
    }

    func testWakeCatchesAllDueRemindersButNotFutureOnes() {
        let first = add(.daily)
        let second = add(.once, second: 15)
        _ = add(.once, second: 50)
        XCTAssertEqual(
            center.takeDueReminders(scheduledFor: due, at: due.addingTimeInterval(40)).map(\.id),
            [first.id, second.id]
        )
        XCTAssertTrue(center.takeDueReminders(scheduledFor: due, at: due.addingTimeInterval(41)).isEmpty)
    }

    func testDeletedReminderIsNotDeliveredByOldSchedule() {
        let reminder = add(.once)
        store.remove(id: reminder.id)
        XCTAssertTrue(center.takeDueReminders(scheduledFor: due, at: due.addingTimeInterval(2)).isEmpty)
    }

    func testLateRepeatingCountdownRestartsFromActualDeliveryTime() {
        var reminder = Reminder(body: "测试倒计时", hour: 9, minute: 0)
        reminder.kind = .countdown
        reminder.countdownSeconds = 60
        reminder.countdownStartedAt = due.addingTimeInterval(-60)
        reminder.repeatsCountdown = true
        store.upsert(reminder)
        let late = due.addingTimeInterval(600)
        XCTAssertEqual(center.takeDueReminders(scheduledFor: due, at: late).map(\.id), [reminder.id])
        XCTAssertEqual(store.reminders.first?.countdownStartedAt, late)
        XCTAssertTrue(center.takeDueReminders(scheduledFor: due, at: late).isEmpty)
    }

    func testActualTimerConsumesReminderAfterMainThreadStall() async throws {
        let calendar = TradingSession.calendar
        let target = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.up) + 1)
        let parts = calendar.dateComponents([.hour, .minute, .second], from: target)
        var reminder = Reminder(
            body: "隔离调度测试", hour: parts.hour!, minute: parts.minute!,
            second: parts.second!, repeatRule: .once
        )
        reminder.anchorDay = ReminderScheduler.anchorDayString(from: target)
        reminder.methods = .bubble
        store.upsert(reminder)
        center.start()

        blockMainThread(until: target.addingTimeInterval(1.2))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(
            center.takeDueReminders(scheduledFor: target, at: Date()).isEmpty,
            "真实 Timer 回调应已补算并登记这条提醒"
        )
    }

    private func blockMainThread(until date: Date) {
        Thread.sleep(until: date)
    }
}
