import AppKit

/// 把一条提醒「呈现」出来：宠物气泡 + 声音，以及可选的置顶弹窗。
///
/// 从 `ReminderCenter` 里抽出来的 —— 定时提醒和价格提醒都要走同一套提醒方式，
/// 而这段逻辑原本只认 `Reminder`。现在只吃「标题 + 正文 + 提醒方式 + 一个 id」，
/// 谁都能用。抽出来之后它也不再依赖任何 store。
@MainActor
final class AlertPresenter {
    private static let snoozeInterval: TimeInterval = 600
    private static let maximumSnoozeCount = 6

    /// 气泡到弹窗的等待时间（菜单「提醒 → 提示后多久弹窗」可调）
    var acknowledgeWindow: TimeInterval = 30

    /// 顺延回来之前问一句「这条提醒还在不在」。
    /// 定时提醒查 `ReminderStore`、价格提醒查 `PriceAlertStore`，所以由持有方注入 ——
    /// 否则删掉的提醒会照样弹（幽灵提醒）
    var stillValid: ((UUID) -> Bool)?

    private let characterController: FloatingCharacterController
    /// 每条提醒各自的「气泡 → 弹窗」待确认定时器
    private var pendingConfirms: [UUID: Timer] = [:]
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

        // 人物被收起来时「宠物提示」整个不响：气泡看不见，只剩一声「叮」更让人困惑。
        // 用户明确要求开会时完全隐藏就别有任何提示，所以连声音也一起省掉。
        // 只勾了弹窗的不受影响 —— 那是另一条独立选择的通道
        if methods.contains(.bubble), characterController.isVisible {
            NSSound(named: "Sosumi")?.play()
            characterController.say(body.isEmpty ? title : body)
        }

        guard methods.contains(.alert) else { return }

        // 只勾了弹窗：直接弹（用户就是要被拦住，气泡没必要先飘一下）
        guard methods.contains(.bubble) else {
            presentModal(title: title, body: body, methods: methods, key: key)
            return
        }

        // 两个都勾：先给一段时间让气泡说完，没人理再弹。
        // 只顶掉**这一条**自己的待确认，不碰别人的
        armPendingConfirm(title: title, body: body, methods: methods, key: key)
    }

    /// 取消所有还在等确认 / 等顺延的提醒（配置变了、或者用户清空了）
    func cancelAll() {
        for timer in pendingConfirms.values { timer.invalidate() }
        pendingConfirms.removeAll()
        for timer in snoozeTimers.values { timer.invalidate() }
        snoozeTimers.removeAll()
    }

    private func armPendingConfirm(title: String, body: String, methods: Reminder.Methods, key: UUID) {
        pendingConfirms[key]?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: acknowledgeWindow, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingConfirms[key] = nil
                self.presentModal(title: title, body: body, methods: methods, key: key)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pendingConfirms[key] = timer
    }

    /// 置顶模态框。注意 runModal 会阻塞主线程一整轮（这期间金价刷新暂停），
    /// 与 monthly-reminder.sh 的行为一致，可接受。
    private func presentModal(title: String, body: String, methods: Reminder.Methods, key: UUID) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .critical
        alert.addButton(withTitle: "知道了")
        alert.addButton(withTitle: "10 分钟后再提醒")
        NSSound(named: "Sosumi")?.play()

        let response = alert.runModal()
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

        let timer = Timer.scheduledTimer(withTimeInterval: Self.snoozeInterval, repeats: false) { [weak self] _ in
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
