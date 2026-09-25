import AppKit

/// 提醒的调度与呈现。
///
/// 流程（用户定的「两个都要」）：人物冒气泡说正文 + 响三声 → 60 秒没人理 → 弹置顶模态框
/// （「知道了」/「10 分钟后再提醒」，顺延最多 6 次，沿用 monthly-reminder.sh 的语义）。
@MainActor
final class ReminderCenter {
    private static let acknowledgeWindow: TimeInterval = 60
    private static let snoozeInterval: TimeInterval = 600
    private static let maximumSnoozeCount = 6

    private let store: ReminderStore
    private let characterController: FloatingCharacterController
    private var timer: Timer?
    private var pendingConfirm: Timer?
    private var snoozeCounts: [UUID: Int] = [:]
    private var firedKeys: Set<String> = []

    init(store: ReminderStore, characterController: FloatingCharacterController) {
        self.store = store
        self.characterController = characterController
    }

    func start() {
        scheduleNext()
    }

    /// 配置变化后重新排程（菜单里增删改之后调用）
    func reload() {
        scheduleNext()
    }

    private var holidays: [String: String] {
        MarketCalendar.HolidayCache.load(
            year: MarketCalendar.HolidayCache.year(of: Date()),
            from: .standard
        )
    }

    /// 精确排程：算出所有提醒里最早的下一次触发时刻，定一个一次性 Timer 到那一刻。
    /// 秒级精度靠这个，轮询做不到（30 秒扫一次最多会晚 30 秒）。
    private func scheduleNext() {
        timer?.invalidate()
        timer = nil

        let now = Date()
        let calendar = TradingSession.calendar
        let next = store.reminders
            .compactMap { ReminderScheduler.nextFireDate(after: now, reminder: $0, holidays: holidays, calendar: calendar) }
            .min()
        // 没有下一条（比如都删了）就不排
        guard let next else { return }

        // 提前 0.2 秒唤醒，落到目标秒时判定命中
        let interval = max(0.2, next.timeIntervalSince(now) - 0.2)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkDueReminders()
                self?.scheduleNext()
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func checkDueReminders() {
        let now = Date()
        for reminder in store.reminders
        where ReminderScheduler.isDue(reminder, at: now, holidays: holidays) {
            let key = ReminderScheduler.fireKey(reminder, at: now)
            guard !firedKeys.contains(key) else { continue }
            firedKeys.insert(key)
            fire(reminder)
        }
    }

    /// 立即提醒（菜单里的「测试」也走这条）
    func fire(_ reminder: Reminder) {
        NSSound(named: "Sosumi")?.play()
        characterController.say(reminder.body.isEmpty ? reminder.title : reminder.body)

        // 气泡先提示；60 秒内没被确认再弹模态框
        pendingConfirm?.invalidate()
        pendingConfirm = Timer.scheduledTimer(withTimeInterval: Self.acknowledgeWindow, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.presentModal(reminder) }
        }
        if let pendingConfirm { RunLoop.main.add(pendingConfirm, forMode: .common) }
    }

    func acknowledge() {
        pendingConfirm?.invalidate()
        pendingConfirm = nil
    }

    /// 置顶模态框。注意 runModal 会阻塞主线程一整轮（这期间金价刷新暂停），
    /// 与 monthly-reminder.sh 的行为一致，可接受。
    private func presentModal(_ reminder: Reminder) {
        // 模态期间先停调度，避免堆叠
        let alert = NSAlert()
        alert.messageText = reminder.title
        alert.informativeText = reminder.body
        alert.alertStyle = .critical
        alert.addButton(withTitle: "知道了")
        alert.addButton(withTitle: "10 分钟后再提醒")
        NSSound(named: "Sosumi")?.play()

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            let count = (snoozeCounts[reminder.id] ?? 0) + 1
            snoozeCounts[reminder.id] = count
            guard count < Self.maximumSnoozeCount else {
                snoozeCounts[reminder.id] = 0
                return
            }
            Timer.scheduledTimer(withTimeInterval: Self.snoozeInterval, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in self?.fire(reminder) }
            }
        } else {
            snoozeCounts[reminder.id] = 0
        }
    }
}
