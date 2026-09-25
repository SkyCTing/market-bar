import AppKit

/// 提醒的调度与呈现。
///
/// 呈现方式按每条提醒自己勾的 `methods` 走（用户要求两种能各自单开、也能同时开）：
/// - 只勾「宠物提示」：冒气泡 + 响一声
/// - 只勾「弹窗」：直接弹置顶模态框
/// - 两个都勾：先气泡，等一段时间（默认 30 秒，菜单里可调）没人理再弹
///   —— 弹窗会阻塞主线程一整轮，能不弹就不弹
///
/// 模态框里的「知道了 / 10 分钟后再提醒」顺延最多 6 次，沿用 monthly-reminder.sh 的语义。
///
/// 另外负责倒计时：有倒计时在跑时每秒把剩余时间推给人物显示在头顶。
@MainActor
final class ReminderCenter {
    /// 气泡到弹窗的等待时间。用户可以调（菜单「提醒 → 提示后多久弹窗」），默认 30 秒
    var acknowledgeWindow: TimeInterval = 30
    private static let snoozeInterval: TimeInterval = 600
    private static let maximumSnoozeCount = 6

    private let store: ReminderStore
    private let characterController: FloatingCharacterController
    private var timer: Timer?
    private var pendingConfirm: Timer?
    /// 有倒计时在跑时才存在：每秒刷一下头顶那行
    private var countdownTicker: Timer?
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

    /// 调休补班日（这些日子照常提醒）
    private var makeupWorkdays: Set<String> {
        MarketCalendar.HolidayCache.loadMakeupWorkdays(
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
            .compactMap { ReminderScheduler.nextFireDate(after: now, reminder: $0, holidays: holidays, makeupWorkdays: makeupWorkdays, calendar: calendar) }
            .min()

        // 提前 0.2 秒唤醒，落到目标秒时判定命中
        if let next {
            let interval = max(0.2, next.timeIntervalSince(now) - 0.2)
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.checkDueReminders()
                    self?.scheduleNext()
                }
            }
            if let timer { RunLoop.main.add(timer, forMode: .common) }
        }
        // 没有下一条（比如都删了）也要走到这儿：得把倒计时显示刷新掉
        refreshCountdownDisplay()
    }

    // MARK: - 倒计时

    /// 正在跑的倒计时里最早到点的那条 —— 头顶只放得下一条
    var nearestCountdown: Reminder? {
        store.reminders
            .compactMap { reminder -> (reminder: Reminder, deadline: Date)? in
                guard let deadline = ReminderScheduler.countdownDeadline(reminder) else { return nil }
                return (reminder, deadline)
            }
            .min { $0.deadline < $1.deadline }?
            .reminder
    }

    /// 头顶那行文本；没有正在跑的倒计时就返回 nil
    func countdownText(at date: Date = Date()) -> String? {
        guard let reminder = nearestCountdown,
              let deadline = ReminderScheduler.countdownDeadline(reminder) else { return nil }
        return CountdownFormat.remaining(deadline.timeIntervalSince(date))
    }

    /// 有倒计时在跑就起一个 1 秒的定时器刷头顶；没有就停掉，不留空转的定时器
    private func refreshCountdownDisplay() {
        let isRunning = nearestCountdown != nil

        if isRunning, countdownTicker == nil {
            let ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.publishCountdown() }
            }
            RunLoop.main.add(ticker, forMode: .common)
            countdownTicker = ticker
        } else if !isRunning {
            countdownTicker?.invalidate()
            countdownTicker = nil
        }

        publishCountdown()
    }

    private func publishCountdown() {
        characterController.updateCountdown(countdownText())
    }

    private func checkDueReminders() {
        let now = Date()
        for reminder in store.reminders
        where ReminderScheduler.isDue(reminder, at: now, holidays: holidays, makeupWorkdays: makeupWorkdays) {
            if reminder.kind == .countdown {
                // 倒计时不靠 fireKey 去重：响完立刻推进状态（停掉或重新起算），
                // 于是它自然就不再 isDue 了。循环计时每秒一次地去重反而会把 firedKeys 撑爆。
                store.upsert(ReminderScheduler.afterCountdownFired(reminder, at: now))
                fire(reminder)
                continue
            }

            let key = ReminderScheduler.fireKey(reminder, at: now)
            guard !firedKeys.contains(key) else { continue }
            firedKeys.insert(key)
            fire(reminder)
        }
    }

    /// 立即提醒（菜单里的「测试」也走这条）
    func fire(_ reminder: Reminder) {
        // 兜底：正常存不出「两个都不勾」，但存档里的脏数据不该变成「静默不提醒」
        let methods = reminder.methods.isEmpty ? Reminder.Methods.bubble : reminder.methods

        pendingConfirm?.invalidate()
        pendingConfirm = nil

        if methods.contains(.bubble) {
            NSSound(named: "Sosumi")?.play()
            characterController.say(reminder.body.isEmpty ? reminder.title : reminder.body)
        }

        guard methods.contains(.alert) else { return }

        // 只勾了弹窗：直接弹（用户就是要被拦住，气泡没必要先飘一下）
        guard methods.contains(.bubble) else {
            presentModal(reminder)
            return
        }

        // 两个都勾：先给 60 秒让气泡说完，没人理再弹
        pendingConfirm = Timer.scheduledTimer(withTimeInterval: acknowledgeWindow, repeats: false) { [weak self] _ in
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
