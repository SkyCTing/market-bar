import AppKit

/// 把一条提醒「呈现」出来：宠物气泡 + 声音，以及可选的置顶弹窗。
///
/// 从 `ReminderCenter` 里抽出来的 —— 定时提醒和价格提醒都要走同一套提醒方式，
/// 而这段逻辑原本只认 `Reminder`。现在只吃「标题 + 正文 + 提醒方式 + 一个 id」，
/// 谁都能用。抽出来之后它也不再依赖任何 store。
@MainActor
final class AlertPresenter {
    /// 顺延间隔。做成实例变量（不是 static）是为了测试能把它调短，
    /// 否则「顺延回来时会议模式已经开了」这条旁路根本没法测
    var snoozeInterval: TimeInterval = 600
    private static let maximumSnoozeCount = 6

    /// 气泡到弹窗的等待时间（菜单「提醒 → 提示后多久弹窗」可调）
    var acknowledgeWindow: TimeInterval = 30

    /// 会议模式：非 nil = 正在抑制，每条交给它攒着，等退出会议模式后补放。
    ///
    /// 用一个闭包而不是「Bool 开关 + 回调」两个成员 —— 那样会出现
    /// 「开关开了却没人接」的错配，提醒就这么无声无息地没了
    var suppressedSink: ((PendingAlert) -> Void)?

    /// 真正弹出模态框那一步。默认 `runModal`（会阻塞主线程一整轮）；
    /// 测试换掉它，补放那条路才能在没有真实窗口的情况下跑完
    var modalResponseProvider: ((NSAlert) -> NSApplication.ModalResponse)?

    /// 补放时每条气泡停留多久。比 `acknowledgeWindow`（默认 30 秒）短得多 ——
    /// 该错过的已经错过了，气泡只是快过一遍，后面还有合并弹窗兜底
    var replayBubbleInterval: TimeInterval = 6

    /// 顺延回来之前问一句「这条提醒还在不在」。
    /// 定时提醒查 `ReminderStore`、价格提醒查 `PriceAlertStore`，所以由持有方注入 ——
    /// 否则删掉的提醒会照样弹（幽灵提醒）
    var stillValid: ((UUID) -> Bool)?

    /// 模态框关闭后回调（模态框开始、结束的时刻）。
    ///
    /// `runModal` 会阻塞主线程一整轮，这期间到点的提醒由调用方负责补响 ——
    /// 呈现层不认识 Reminder，所以只能把时刻交出去
    var onModalFinished: ((_ startedAt: Date, _ finishedAt: Date) -> Void)?

    private let characterController: FloatingCharacterController
    private struct PendingConfirm {
        let timer: Timer
        let token: UUID
    }

    /// 每条提醒各自的「气泡 → 弹窗」待确认定时器
    private var pendingConfirms: [UUID: PendingConfirm] = [:]
    private var visibleBubbleKey: UUID?
    /// 「10 分钟后再提醒」的顺延定时器，留着是为了能取消
    private var snoozeTimers: [UUID: Timer] = [:]
    private var snoozeCounts: [UUID: Int] = [:]

    init(characterController: FloatingCharacterController) {
        self.characterController = characterController
    }

    /// 立即提醒
    func fire(title: String, body: String, methods requested: Reminder.Methods, key: UUID) {
        // 兜底：正常存不出「两个都不勾」，但存档里的脏数据不该变成「静默不提醒」
        let methods = requested.isEmpty ? Reminder.Methods.bubble : requested

        if recordIfSuppressed(title: title, body: body, methods: methods, key: key) { return }

        guard Self.canPresent(methods, characterVisible: characterController.isVisible) else { return }

        if methods.contains(.bubble) {
            NSSound(named: "Sosumi")?.play()
            let text = body.isEmpty ? title : body
            if methods.contains(.alert) {
                characterController.say(
                    text,
                    duration: acknowledgeWindow,
                    onAcknowledge: { [weak self] in self?.acknowledgeVisibleBubble() ?? false }
                )
            } else {
                characterController.say(text)
            }
        }

        guard methods.contains(.alert) else { return }

        // 只勾了弹窗：直接弹（用户就是要被拦住，气泡没必要先飘一下）
        guard methods.contains(.bubble) else {
            presentModal(title: title, body: body, methods: methods, key: key)
            return
        }

        // 两个都勾：先给一段时间让气泡说完，没人理再弹。
        // 只顶掉**这一条**自己的待确认，不碰别人的
        armPendingConfirm(title: title, body: body, methods: methods, key: key, window: acknowledgeWindow)
    }

    /// 正在抑制（会议模式）就把这条记下来并返回 true，调用方直接 return。
    /// 写法同 `canPresent`：传进来的状态，在每个可能触发的点上重新判定
    private func recordIfSuppressed(title: String, body: String,
                                    methods: Reminder.Methods, key: UUID) -> Bool {
        guard let sink = suppressedSink else { return false }
        sink(PendingAlert(key: key, title: title, body: body, methods: methods))
        return true
    }

    static func canPresent(_ methods: Reminder.Methods, characterVisible: Bool) -> Bool {
        characterVisible || !methods.contains(.bubble)
    }

    /// 取消所有还在等确认 / 等顺延的提醒（配置变了、或者用户清空了）
    func cancelAll() {
        for pending in pendingConfirms.values { pending.timer.invalidate() }
        pendingConfirms.removeAll()
        if visibleBubbleKey != nil { characterController.dismissSpeechBubble() }
        visibleBubbleKey = nil
        for timer in snoozeTimers.values { timer.invalidate() }
        snoozeTimers.removeAll()
    }

    /// 点击气泡或人物只确认当前显示的那条，不取消其它提醒或已经顺延的定时器。
    @discardableResult
    func acknowledgeVisibleBubble() -> Bool {
        guard let key = visibleBubbleKey,
              let pending = pendingConfirms.removeValue(forKey: key) else { return false }
        pending.timer.invalidate()
        visibleBubbleKey = nil
        // 补放中点一下气泡/人物：直接跳下一条。用 Task 而不是同步调用 ——
        // 点击的调用方拿到 true 之后会去 dismiss 气泡面板，
        // 同步跳会让它把**下一条**的气泡给关掉
        if isReplaying {
            Task { @MainActor [weak self] in self?.advanceReplay() }
        }
        return true
    }

    // MARK: - 会议模式补放

    private var isReplaying = false
    private var replayBubbles: [PendingAlert] = []
    private var replayModalItems: [PendingAlert] = []
    /// 正在冒的那一条。取消补放时要连它一起还回去 —— 它还没放完
    private var replayCurrent: PendingAlert?

    /// 散会后把会议期间攒下的提醒补上。
    ///
    /// 气泡逐条冒（自己会消失，不用点），要弹模态框的**合并成一条** ——
    /// 开两小时会可能积十几条，挨个点模态框不可接受。
    ///
    /// ⚠️ 绝不能像 `fire` 那样连着放：`visibleBubbleKey` 只有一个槽，
    /// 连着 fire 会互相覆盖，但 `pendingConfirms` 会把计时器全排上，
    /// 结果就是弹窗在队列里堆成一串
    func replay(_ items: [PendingAlert]) {
        guard !isReplaying else { return }
        // store 里已经查不到的（会议期间被删掉了）静默丢掉，连气泡都不冒 ——
        // 和 stillValid 现有行为一致（ReminderCenter.swift:69/133、本文件顺延那处）
        let live = items.filter { stillValid?($0.key) ?? true }
        replayBubbles = live.filter { $0.methods.contains(.bubble) }
        replayModalItems = live.filter { $0.methods.contains(.alert) }
        guard !replayBubbles.isEmpty || !replayModalItems.isEmpty else { return }
        isReplaying = true
        advanceReplay()
    }

    /// 补放途中又被拉进会议模式（或用户删了提醒）：把还没放完的还回去，
    /// 让调用方重新入队 —— 既不能丢，也不能重
    func cancelReplay() -> [PendingAlert] {
        guard isReplaying else { return [] }
        isReplaying = false
        cancelAll()
        // 正在冒的那条也要还回去：它还没放完
        let leftovers = [replayCurrent].compactMap { $0 } + replayBubbles + replayModalItems
        replayCurrent = nil
        replayBubbles = []
        replayModalItems = []
        return leftovers
    }

    private func advanceReplay() {
        // 人物被用户收起来了（或本来就没显示）：气泡没地方冒，但合并弹窗照弹
        guard characterController.isVisible else {
            replayBubbles = []
            finishReplay()
            return
        }
        guard let next = replayBubbles.first else {
            replayCurrent = nil
            finishReplay()
            return
        }
        replayBubbles.removeFirst()
        replayCurrent = next

        NSSound(named: "Sosumi")?.play()
        let text = next.body.isEmpty ? next.title : next.body
        characterController.say(
            text,
            duration: replayBubbleInterval,
            onAcknowledge: { [weak self] in self?.acknowledgeVisibleBubble() ?? false }
        )
        // 即便这条只勾了气泡，也挂一个计时器 —— 它是唯一的「该下一条了」信号
        // （计时器到点后走上面那条 isReplaying 分支，不会真的弹窗）
        armPendingConfirm(title: next.title, body: next.body, methods: next.methods,
                          key: next.key, window: replayBubbleInterval)
    }

    private func finishReplay() {
        isReplaying = false
        replayCurrent = nil
        let items = replayModalItems
        replayBubbles = []
        replayModalItems = []
        guard !items.isEmpty else { return }

        // 只有一条就退回普通弹窗：它带着「10 分钟后再提醒」，
        // 为一条也搞个「汇总」框没意义
        if items.count == 1, let only = items.first {
            presentModal(title: only.title, body: only.body, methods: only.methods, key: only.key)
            return
        }
        presentMergedModal(items)
    }

    private func presentMergedModal(_ items: [PendingAlert]) {
        let alert = NSAlert()
        alert.messageText = MeetingReplaySummary.title(count: items.reduce(0) { $0 + $1.count })
        alert.informativeText = MeetingReplaySummary.text(for: items)
        alert.alertStyle = .critical
        // 只有一个按钮：不给「稍后」——那等于给 N 条各挂一个顺延计时器，
        // 十分钟后再来一次，正是我们要躲开的场面
        alert.addButton(withTitle: "知道了")
        NSSound(named: "Sosumi")?.play()

        let modalStartedAt = Date()
        _ = modalResponseProvider?(alert) ?? alert.runModal()
        // 这个回调不能省：模态框阻塞主线程这一轮里到点的提醒，得由它补算
        onModalFinished?(modalStartedAt, Date())
    }

    var pendingConfirmationCount: Int { pendingConfirms.count }

    private func armPendingConfirm(title: String, body: String, methods: Reminder.Methods,
                                   key: UUID, window: TimeInterval) {
        pendingConfirms[key]?.timer.invalidate()
        let token = UUID()
        let timer = Timer.scheduledTimer(withTimeInterval: window, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.pendingConfirms[key]?.token == token else { return }
                self.pendingConfirms[key] = nil
                if self.visibleBubbleKey == key {
                    self.visibleBubbleKey = nil
                    self.characterController.dismissSpeechBubble()
                }
                // ⚠️ 补放这条支路必须在 canPresent 之前：人物被用户收起来时
                // canPresent 会 return，那样补放就永远卡在这一条上，
                // 后面的气泡和合并弹窗再也出不来
                if self.isReplaying {
                    self.advanceReplay()
                    return
                }
                guard Self.canPresent(methods, characterVisible: self.characterController.isVisible) else { return }
                self.presentModal(title: title, body: body, methods: methods, key: key)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pendingConfirms[key] = PendingConfirm(timer: timer, token: token)
        visibleBubbleKey = key
    }

    /// 置顶模态框。注意 runModal 会阻塞主线程一整轮（这期间金价刷新暂停），
    /// 与 monthly-reminder.sh 的行为一致，可接受。
    private func presentModal(title: String, body: String, methods: Reminder.Methods, key: UUID) {
        // ⚠️ 闸门要放两处，不能只堵 fire：会议模式打开之前就冒完气泡、
        // 正在等确认的那条，是 armPendingConfirm 的计时器**直接**调到这里的
        if recordIfSuppressed(title: title, body: body, methods: methods, key: key) { return }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .critical
        alert.addButton(withTitle: "知道了")
        alert.addButton(withTitle: "10 分钟后再提醒")
        NSSound(named: "Sosumi")?.play()

        let modalStartedAt = Date()
        let response = modalResponseProvider?(alert) ?? alert.runModal()
        onModalFinished?(modalStartedAt, Date())

        guard response == .alertSecondButtonReturn else {
            snoozeCounts[key] = 0
            return
        }

        let count = (snoozeCounts[key] ?? 0) + 1
        snoozeCounts[key] = count
        guard count < Self.maximumSnoozeCount else {
            snoozeCounts[key] = 0
            return
        }

        let timer = Timer.scheduledTimer(withTimeInterval: snoozeInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.snoozeTimers[key] = nil
                // 顺延期间这条被删掉/清空了就别再响
                guard self.stillValid?(key) ?? true else { return }
                // 重放原来那套方式：原来就是 fire(reminder)，会重新冒一次气泡
                self.fire(title: title, body: body, methods: methods, key: key)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        snoozeTimers[key] = timer
    }
}
