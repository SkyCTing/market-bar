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

    private static let snoozeInterval: TimeInterval = 600
    private static let maximumSnoozeCount = 6

    private let store: ReminderStore
    private let characterController: FloatingCharacterController
    /// 呈现层。价格提醒也复用它 —— 这样「气泡 → 弹窗等待时间」全 app 只有一份
    let presenter: AlertPresenter
    private var timer: Timer?
    /// 有倒计时在跑时才存在：每秒刷一下头顶那行
    private var countdownTicker: Timer?
    private var snoozeCounts: [UUID: Int] = [:]
    private var firedKeys: Set<String> = []

    init(
        store: ReminderStore,
        priceAlertStore: PriceAlertStore? = nil,
        characterController: FloatingCharacterController
    ) {
        self.store = store
        self.characterController = characterController
        self.presenter = AlertPresenter(characterController: characterController)
        // 顺延回来之前确认对应的定时或价格提醒还在
        presenter.stillValid = { [weak store, weak priceAlertStore] id in
            store?.reminders.contains(where: { $0.id == id }) == true
                || priceAlertStore?.alerts.contains(where: { $0.id == id }) == true
        }
        // 模态框会阻塞主线程一整轮，期间到点的提醒原来就永远丢了 —— 关掉之后补响
        presenter.onModalFinished = { [weak self] startedAt, finishedAt in
            self?.fireMissedReminders(between: startedAt, and: finishedAt)
        }
    }

    /// 补响被模态框挡住的那几条。
    /// 放到下一轮 runloop 再响：现在还在 checkDueReminders 的循环里，
    /// 直接 fire 会在刚关掉的模态框上再叠一个嵌套模态框
    private func fireMissedReminders(between start: Date, and end: Date) {
        let missed = ReminderScheduler.missedScheduled(
            in: store.reminders,
            between: start,
            and: end,
            firedKeys: firedKeys,
            holidays: holidays,
            makeupWorkdays: makeupWorkdays
        )
        guard !missed.isEmpty else { return }

        for (reminder, fireDate) in missed {
            firedKeys.insert(ReminderScheduler.fireKey(reminder, at: fireDate))
        }
        Task { @MainActor [weak self] in
            for (reminder, _) in missed {
                guard let self, self.store.reminders.contains(where: { $0.id == reminder.id }) else { continue }
                self.fire(reminder)
            }
        }
    }

    /// 气泡到弹窗的等待时间（转发给 presenter，菜单和测试都还用这个名字）
    var acknowledgeWindow: TimeInterval {
        get { presenter.acknowledgeWindow }
        set { presenter.acknowledgeWindow = newValue }
    }

    func start() {
        scheduleNext()
    }

    /// 配置变化后重新排程（菜单里增删改之后调用）
    func reload() {
        // 提醒被删了/清空了，还在等确认、等顺延的就都别响了 —— 否则会出现
        // 「已经删掉的提醒照样弹窗」的幽灵提醒
        cancelAllPending()
        scheduleNext()
    }

    private func cancelAllPending() {
        presenter.cancelAll()
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
        presenter.fire(
            title: reminder.title,
            body: reminder.body.isEmpty ? reminder.title : reminder.body,
            methods: reminder.methods,
            key: reminder.id
        )
    }

    @discardableResult
    func acknowledge() -> Bool {
        presenter.acknowledgeVisibleBubble()
    }
}
