import AppKit
import XCTest

@testable import MarketBar

// MARK: - 队列与状态

@MainActor
final class MeetingModeTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "MeetingModeTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
    }

    private func alert(
        key: UUID = UUID(), title: String = "喝水", body: String = "起来走两步",
        methods: Reminder.Methods = .default
    ) -> PendingAlert {
        PendingAlert(key: key, title: title, body: body, methods: methods)
    }

    func testStartsOffWhenNothingPersisted() {
        let mode = MeetingMode(defaults: defaults)
        // 缺省的 Bool 读出来是 false —— 不判「存过没有」的话默认值就成了「关」
        XCTAssertFalse(mode.isOn)
        XCTAssertTrue(mode.queue.isEmpty)
    }

    func testModeSurvivesRestart() {
        let mode = MeetingMode(defaults: defaults)
        mode.setOn(true)
        XCTAssertTrue(MeetingMode(defaults: defaults).isOn)
        mode.setOn(false)
        XCTAssertFalse(MeetingMode(defaults: defaults).isOn)
    }

    func testQueueSurvivesRestartInOrder() {
        let mode = MeetingMode(defaults: defaults)
        mode.enqueue(alert(title: "第一条"))
        mode.enqueue(alert(title: "第二条"))
        let reloaded = MeetingMode(defaults: defaults)
        XCTAssertEqual(reloaded.queue.map(\.title), ["第一条", "第二条"])
    }

    func testConsecutiveIdenticalAlertsCollapseIntoOneEntry() {
        let mode = MeetingMode(defaults: defaults)
        let key = UUID()
        // 循环倒计时开两小时会就是连着响很多次，不该补出很多条一样的气泡
        for _ in 0 ..< 24 { mode.enqueue(alert(key: key)) }
        XCTAssertEqual(mode.queue.count, 1)
        XCTAssertEqual(mode.queue.first?.count, 24)
    }

    func testNonConsecutiveRepeatsStaySeparate() {
        let mode = MeetingMode(defaults: defaults)
        let a = UUID(), b = UUID()
        mode.enqueue(alert(key: a, title: "A"))
        mode.enqueue(alert(key: b, title: "B"))
        mode.enqueue(alert(key: a, title: "A"))
        // 顺序不能被打乱，也不能跨着合并
        XCTAssertEqual(mode.queue.map(\.title), ["A", "B", "A"])
    }

    func testTakeAllEmptiesTheQueueAndPersistsThat() {
        let mode = MeetingMode(defaults: defaults)
        mode.enqueue(alert())
        let taken = mode.takeAll()
        XCTAssertEqual(taken.count, 1)
        XCTAssertTrue(mode.queue.isEmpty)
        XCTAssertTrue(MeetingMode(defaults: defaults).queue.isEmpty, "取走要落盘，不能重启又冒出来")
    }

    func testPrependPutsLeftoversBackAtTheFront() {
        let mode = MeetingMode(defaults: defaults)
        mode.enqueue(alert(title: "后来的"))
        mode.prepend([alert(title: "没放完的")])
        XCTAssertEqual(mode.queue.map(\.title), ["没放完的", "后来的"])
    }

    func testQueueDecodeDropsOnlyTheUndecodableEntry() throws {
        let good = alert(title: "好的")
        let encoded = try JSONEncoder().encode([good])
        var array = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        array.insert(["title": "没有 key 的那条"], at: 0)
        defaults.set(try JSONSerialization.data(withJSONObject: array), forKey: MeetingMode.queueKey)

        let mode = MeetingMode(defaults: defaults)
        XCTAssertEqual(mode.queue.map(\.title), ["好的"], "坏的那条丢，好的要留住")
    }

    func testCorruptQueueKeyDoesNotWipeAnything() {
        defaults.set(Data("not json".utf8), forKey: MeetingMode.queueKey)
        let mode = MeetingMode(defaults: defaults)
        // 整份坏掉时保持为空（内存里本来也没有），关键是**别把它当空数组写回去**
        XCTAssertTrue(mode.queue.isEmpty)
        XCTAssertNotNil(defaults.data(forKey: MeetingMode.queueKey), "不该把坏数据也删了")
    }

    func testMissingCountFieldDefaultsToOne() throws {
        let key = UUID()
        let json = try JSONSerialization.data(withJSONObject: [
            ["key": key.uuidString, "title": "老的", "body": "", "methods": 3],
        ])
        defaults.set(json, forKey: MeetingMode.queueKey)
        let mode = MeetingMode(defaults: defaults)
        XCTAssertEqual(mode.queue.first?.count, 1)
        XCTAssertEqual(mode.queue.first?.title, "老的")
    }
}

// MARK: - 合并弹窗的文案

final class MeetingReplaySummaryTests: XCTestCase {
    private func alert(title: String, body: String, count: Int = 1) -> PendingAlert {
        PendingAlert(key: UUID(), title: title, body: body, methods: .alert, count: count)
    }

    func testTitleMentionsTheTotal() {
        XCTAssertEqual(MeetingReplaySummary.title(count: 3), "会议期间错过了 3 条提醒")
    }

    func testListsTitleAndBodyForEachItem() {
        let text = MeetingReplaySummary.text(for: [
            alert(title: "开会", body: "10 点站会"),
            alert(title: "喝水", body: "起来走两步"),
        ])
        XCTAssertTrue(text.contains("• 开会：10 点站会"))
        XCTAssertTrue(text.contains("• 喝水：起来走两步"))
        XCTAssertEqual(text.components(separatedBy: "\n").count, 2)
    }

    func testOmitsBodyWhenItEqualsTheTitle() {
        let text = MeetingReplaySummary.text(for: [alert(title: "喝水", body: "喝水")])
        XCTAssertEqual(text, "• 喝水")
    }

    func testCollapsesNewlinesInBody() {
        // 正文里的换行会把 NSAlert 的版式搞乱
        let text = MeetingReplaySummary.text(for: [alert(title: "标题", body: "第一行\n\n第二行")])
        XCTAssertEqual(text, "• 标题：第一行 第二行")
    }

    func testTruncatesLongLines() {
        let text = MeetingReplaySummary.text(for: [alert(title: "标题", body: String(repeating: "字", count: 200))])
        XCTAssertTrue(text.hasSuffix("…"))
        XCTAssertLessThanOrEqual(text.count, MeetingReplaySummary.maximumLineLength + 4)
    }

    func testCapsTheListAndCountsTheRemainder() {
        let items = (1 ... 12).map { alert(title: "第 \($0) 条", body: "") }
        let text = MeetingReplaySummary.text(for: items)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, MeetingReplaySummary.maximumItems + 1)
        XCTAssertTrue(lines.last?.contains("另有 4 条") == true, lines.last ?? "")
    }

    func testAnnotatesCollapsedRepeats() {
        let text = MeetingReplaySummary.text(for: [alert(title: "倒计时", body: "", count: 7)])
        XCTAssertEqual(text, "• 倒计时（连续 7 次）")
    }
}

// MARK: - 抑制与补放

@MainActor
final class AlertPresenterMeetingTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var character: FloatingCharacterController!
    private var presenter: AlertPresenter!
    private var mode: MeetingMode!

    override func setUp() async throws {
        suite = "AlertPresenterMeetingTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        character = FloatingCharacterController(defaults: defaults)
        presenter = AlertPresenter(characterController: character)
        mode = MeetingMode(defaults: defaults)
    }

    override func tearDown() async throws {
        presenter.cancelAll()
        // 一定要把人物收掉：气泡和人物都是真窗口，会留在 NSApp.windows 里，
        // 而别的测试（FloatingCharacterTests）是靠 `NSApp.windows.first` 找自己的窗口的，
        // 留下一扇就等于把它们指到别人身上
        character.setVisible(false)
        defaults.removePersistentDomain(forName: suite)
        presenter = nil
        character = nil
        mode = nil
        defaults = nil
    }

    /// 相当于生产的 `setMeetingMode`：装上 sink 才是「正在抑制」
    private func beginSuppressing() {
        mode.setOn(true)
        presenter.suppressedSink = { [weak self] alert in self?.mode.enqueue(alert) }
    }

    /// 把模态框那一步换成不阻塞的假实现，否则测试会一直挂在 runModal 上
    private func stubModals(_ response: NSApplication.ModalResponse = .alertFirstButtonReturn) -> () -> Int {
        var count = 0
        presenter.modalResponseProvider = { _ in
            count += 1
            return response
        }
        return { count }
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func waitForQueue(_ count: Int) async {
        await waitUntil { self.mode.queue.count >= count }
    }

    func testUnsuppressedPresenterStillPresentsNormally() {
        // 没装 sink（= 会议模式没开）就该照常走
        character.setVisible(true)
        presenter.fire(title: "正常", body: "", methods: [.bubble, .alert], key: UUID())
        XCTAssertTrue(mode.queue.isEmpty, "没在抑制就不该攒")
        XCTAssertEqual(presenter.pendingConfirmationCount, 1, "该排的确认照旧")
    }

    func testFireIsRecordedInsteadOfPresentedWhileSuppressed() {
        character.setVisible(true)
        beginSuppressing()

        presenter.fire(title: "标题", body: "正文", methods: .default, key: UUID())

        XCTAssertEqual(mode.queue.count, 1)
        XCTAssertEqual(mode.queue.first?.title, "标题")
        XCTAssertEqual(mode.queue.first?.body, "正文")
        XCTAssertEqual(mode.queue.first?.methods, .default)
        // 没有冒气泡、没有排确认
        XCTAssertEqual(presenter.pendingConfirmationCount, 0)
    }

    func testSuppressedAlertOnlyReminderIsRecordedExactlyOnce() {
        character.setVisible(true)
        beginSuppressing()
        _ = stubModals()

        presenter.fire(title: "只弹窗", body: "", methods: .alert, key: UUID())

        // 堵了 fire 又堵了 presentModal，但这条只该记一次
        XCTAssertEqual(mode.queue.count, 1)
    }

    func testConfirmArmedBeforeTheModeTurnedOnIsRecordedWhenItsWindowElapses() async {
        character.setVisible(true)
        _ = stubModals()
        presenter.acknowledgeWindow = 0.05

        // 会议模式打开**之前**就冒完气泡、排上了确认
        presenter.fire(title: "早就在等的", body: "", methods: .default, key: UUID())
        XCTAssertEqual(presenter.pendingConfirmationCount, 1)

        // 中途进了会议模式
        beginSuppressing()
        await waitForQueue(1)

        // 确认计时器到点走的是 presentModal，那条旁路也得堵住
        XCTAssertEqual(mode.queue.count, 1)
        XCTAssertEqual(mode.queue.first?.title, "早就在等的")
    }

    func testAcknowledgeAdvancesToTheNextReplayBubble() async {
        character.setVisible(true)
        _ = stubModals()
        presenter.replayBubbleInterval = 30   // 长到只能靠点击推进

        presenter.replay([
            PendingAlert(key: UUID(), title: "一", body: "", methods: .bubble),
            PendingAlert(key: UUID(), title: "二", body: "", methods: .bubble),
        ])
        XCTAssertEqual(presenter.pendingConfirmationCount, 1)

        XCTAssertTrue(self.presenter.acknowledgeVisibleBubble())
        // 第一条确认掉之后，第二条要顶上来（是在 Task 里跳的，等一拍）
        await waitUntil { self.presenter.pendingConfirmationCount == 1 }
        XCTAssertTrue(self.presenter.acknowledgeVisibleBubble())
        await waitUntil { self.presenter.pendingConfirmationCount == 0 }
    }

    func testReplayBubblesThenPresentsOneMergedModal() async {
        character.setVisible(true)
        let modalCount = stubModals()
        presenter.replayBubbleInterval = 0.05

        presenter.replay([
            PendingAlert(key: UUID(), title: "一", body: "", methods: [.bubble, .alert]),
            PendingAlert(key: UUID(), title: "二", body: "内容二", methods: .alert),
            PendingAlert(key: UUID(), title: "三", body: "", methods: [.bubble, .alert]),
        ])

        await waitUntil { modalCount() > 0 }
        XCTAssertEqual(modalCount(), 1, "三条要合并成一个弹窗，不是三个")
        XCTAssertEqual(presenter.pendingConfirmationCount, 0)
    }

    func testReplayDropsItemsWhoseStoreEntryWasDeleted() async {
        character.setVisible(true)
        let modalCount = stubModals()

        let alive = UUID()
        presenter.stillValid = { $0 == alive }
        presenter.replay([
            PendingAlert(key: UUID(), title: "已经被删了", body: "", methods: .alert),
            PendingAlert(key: alive, title: "还在", body: "", methods: .alert),
        ])

        await waitUntil { modalCount() > 0 }
        // 只剩一条 → 退回普通弹窗（带「10 分钟后再提醒」），不是汇总框
        XCTAssertEqual(modalCount(), 1)
    }

    func testReplaySkipsBubblesWhenTheCharacterIsHiddenButStillShowsTheModal() async {
        // 人物收起来了：气泡没地方冒，但汇总弹窗必须照弹 ——
        // 这条支路如果放在 canPresent 后面，补放会永远卡死
        character.setVisible(false)
        let modalCount = stubModals()

        presenter.replay([
            PendingAlert(key: UUID(), title: "一", body: "", methods: [.bubble, .alert]),
        ])

        await waitUntil { modalCount() > 0 }
        XCTAssertEqual(modalCount(), 1)
        XCTAssertEqual(presenter.pendingConfirmationCount, 0)
    }

    func testReplayOfNothingDoesNothing() {
        let modalCount = stubModals()
        presenter.replay([])
        XCTAssertEqual(modalCount(), 0)
        XCTAssertEqual(presenter.pendingConfirmationCount, 0)
    }

    func testCancelReplayHandsBackWhatWasNotPlayedYet() {
        character.setVisible(true)
        _ = stubModals()
        presenter.replayBubbleInterval = 30

        presenter.replay([
            PendingAlert(key: UUID(), title: "一", body: "", methods: .bubble),
            PendingAlert(key: UUID(), title: "二", body: "", methods: .bubble),
        ])

        let leftovers = presenter.cancelReplay()
        // 「一」正在冒、还没放完，「二」排在后面 —— 两条都得还回来，
        // 既不能丢，也不能等会儿重放一遍
        XCTAssertEqual(leftovers.map(\.title), ["一", "二"])
        XCTAssertEqual(presenter.pendingConfirmationCount, 0)
        XCTAssertTrue(presenter.cancelReplay().isEmpty, "没在补放时返回空")
    }

    func testSuppressionLeavesThePresentationTruthTableAlone() {
        // canPresent 的真值表是另一条测试钉住的，这里确认加闸门没改它
        XCTAssertTrue(AlertPresenter.canPresent([.bubble, .alert], characterVisible: true))
        XCTAssertFalse(AlertPresenter.canPresent([.bubble, .alert], characterVisible: false))
        XCTAssertTrue(AlertPresenter.canPresent(.alert, characterVisible: false))
        XCTAssertFalse(AlertPresenter.canPresent(.bubble, characterVisible: false))
    }
}

// MARK: - 提醒「还会不会响」

final class ReminderLivenessTests: XCTestCase {
    private let calendar = TradingSession.calendar
    private let now = Date(timeIntervalSince1970: 1_760_000_000)   // 固定时刻，不受跑测试的日子影响

    private func scheduled(hour: Int, minute: Int, rule: Reminder.Repeat, anchorDay: String = "") -> Reminder {
        var reminder = Reminder(title: "t", body: "b", hour: hour, minute: minute, repeatRule: rule)
        reminder.anchorDay = anchorDay
        return reminder
    }

    private func countdown(startedAt: Date?, seconds: Int, repeats: Bool) -> Reminder {
        var reminder = Reminder(title: "t", body: "b", hour: 0, minute: 0)
        reminder.kind = .countdown
        reminder.countdownSeconds = seconds
        reminder.countdownStartedAt = startedAt
        reminder.repeatsCountdown = repeats
        return reminder
    }

    func testNormalRemindersAreLive() {
        XCTAssertEqual(ReminderScheduler.liveness(of: scheduled(hour: 9, minute: 0, rule: .daily), now: now), .live)
        XCTAssertEqual(ReminderScheduler.liveness(of: countdown(startedAt: now, seconds: 300, repeats: false), now: now), .live)
    }

    func testFinishedNonRepeatingCountdownIsReported() {
        // 跑完会把 countdownStartedAt 清掉 —— 用户看到的就是「这条怎么不响了」
        XCTAssertEqual(ReminderScheduler.liveness(of: countdown(startedAt: nil, seconds: 300, repeats: false), now: now),
                       .finishedCountdown)
        XCTAssertEqual(ReminderScheduler.Liveness.finishedCountdown.note, "已结束")
    }

    func testNeverStartedRepeatingCountdownIsReported() {
        XCTAssertEqual(ReminderScheduler.liveness(of: countdown(startedAt: nil, seconds: 300, repeats: true), now: now),
                       .idleCountdown)
        XCTAssertEqual(ReminderScheduler.Liveness.idleCountdown.note, "未启动")
    }

    func testOnceReminderWithoutADateIsReported() {
        // 这条就是用户数据里那条「京东京豆活动」：repeat=once 但 anchorDay 是空的
        let reminder = scheduled(hour: 9, minute: 0, rule: .once)
        XCTAssertEqual(ReminderScheduler.liveness(of: reminder, now: now), .missingDate)
        XCTAssertEqual(ReminderScheduler.Liveness.missingDate.note, "没设日期")
    }

    func testExpiredOnceReminderIsReported() {
        // 用一个肯定已经过去的日期
        let past = Date(timeIntervalSince1970: 1_600_000_000)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = calendar
        let reminder = scheduled(hour: 9, minute: 0, rule: .once, anchorDay: formatter.string(from: past))
        XCTAssertEqual(ReminderScheduler.liveness(of: reminder, now: now), .expiredOnce)
        XCTAssertEqual(ReminderScheduler.Liveness.expiredOnce.note, "已过期")
    }

    func testLiveRemindersShowNoNote() {
        XCTAssertNil(ReminderScheduler.Liveness.live.note, "正常的什么都不显示，别在列表里加噪音")
    }
}
