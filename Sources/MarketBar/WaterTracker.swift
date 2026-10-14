import Foundation

// 「8 杯水」：一天之内按起止时间均分若干次提醒，并记录今天喝了几杯。
//
// 为什么不并进 `Reminder` 模型：提醒是**事件**（到点响一次），这是**一天内的进度**。
// 塞在一起要动持久化（有清空用户数据的坑），而且两边语义都会变脏。

// MARK: - 配置

struct WaterPlan: Codable, Equatable, Sendable {
    /// 默认关：这是要用户主动开的功能，装上去不该自己开始提醒
    var isEnabled = false
    /// 起止时间存成「从 0 点算起的分钟数」：比 Date 好比较，也天然跨天重建
    var startMinutes = 9 * 60
    var endMinutes = 21 * 60
    var cups = 8
    /// 复用提醒方式（宠物气泡 / 弹窗）
    var methods: Reminder.Methods = .bubble

    /// ⚠️ 这个不是装饰品。会议模式把提醒攒起来时按 UUID 记，补放时会拿它去问
    /// `AlertPresenter.stillValid`「这条还在不在」。喝水提醒不在任何 store 里，
    /// **没有这个 key 就会被当成「已删除」静默丢掉** —— 开会期间该喝的水再也补不回来
    var alertKey = UUID()

    /// 自定义的每一杯时刻（从 0 点算起的分钟数）。
    ///
    /// **空数组 = 按起止时间均分**（默认）。非空时以它为准 ——
    /// 起止时间和杯数这时只是「恢复均分」用的生成参数。
    /// 设置界面保存时会拿它和均分结果比对：一样就存空的（这样以后改起止时间仍然生效），
    /// 不一样才存具体时刻
    var customTimes: [Int] = []

    /// 杯数夹到合理范围：0 或负数会让均分算出除零 / 负间隔
    static let cupRange = 1 ... 16
    /// 用户填的杯数（夹过范围）
    var clampedCups: Int {
        min(max(cups, Self.cupRange.lowerBound), Self.cupRange.upperBound)
    }

    /// 均分出来的时刻。设置界面用它判断「用户改过没有」
    var evenMinutes: [Int] {
        let window = effectiveWindow
        let count = clampedCups
        // 起止相同（用户把结束时间拖到和开始一样）时退化成「就在那一刻一杯」。
        // 返回空列表的话 effectiveCups 会变成 0，表现成「永远不提醒」而且看不出原因
        guard window.end > window.start else { return [window.start] }
        let step = Double(window.end - window.start) / Double(count)
        return (0 ..< count).map { window.start + Int((step * Double($0)).rounded()) }
    }

    /// 今天每一杯的时刻（分钟，升序）。**自定义优先**
    var cupMinutes: [Int] {
        guard !customTimes.isEmpty else { return evenMinutes }
        return Array(customTimes.sorted().prefix(Self.cupRange.upperBound))
    }

    /// 今天实际会响几杯
    var effectiveCups: Int { cupMinutes.count }

    /// 起止反了就换回来 —— 把结束时间调到开始之前是很自然的误操作，
    /// 与其报错，不如按「他就是想要一个区间」来理解
    var effectiveWindow: (start: Int, end: Int) {
        (min(startMinutes, endMinutes), max(startMinutes, endMinutes))
    }

    init() {}

    /// 手写解码：以后加字段不会把老配置整份判死。
    /// 合成解码器遇到缺字段会抛 keyNotFound，**结果是用户的设置被清空**（Reminder 上踩过）
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        startMinutes = try container.decodeIfPresent(Int.self, forKey: .startMinutes) ?? 9 * 60
        endMinutes = try container.decodeIfPresent(Int.self, forKey: .endMinutes) ?? 21 * 60
        cups = try container.decodeIfPresent(Int.self, forKey: .cups) ?? 8
        customTimes = try container.decodeIfPresent([Int].self, forKey: .customTimes) ?? []
        methods = try container.decodeIfPresent(Reminder.Methods.self, forKey: .methods) ?? .bubble
        alertKey = try container.decodeIfPresent(UUID.self, forKey: .alertKey) ?? UUID()
    }
}

// MARK: - 进度

/// 今天的进度。跨天靠 `day` 判断 —— 不看它的话，app 一直开着跨零点会把昨天的杯数算进今天
struct WaterProgress: Codable, Equatable, Sendable {
    var day = ""
    var drunk = 0

    init(day: String = "", drunk: Int = 0) {
        self.day = day
        self.drunk = drunk
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        day = try container.decodeIfPresent(String.self, forKey: .day) ?? ""
        drunk = try container.decodeIfPresent(Int.self, forKey: .drunk) ?? 0
    }
}

// MARK: - 排布与判定（纯函数）

enum WaterSchedule {
    /// 今天每一杯该在几点。
    ///
    /// 间隔 = (结束 − 开始) / 杯数，第一杯落在开始时间。
    /// 于是 9:00–21:00、8 杯 → 每 1.5 小时一杯，最后一杯 19:30。
    /// （除数用「杯数」而不是「杯数 − 1」，是为了让「每 1.5 小时」这个直觉成立；
    /// 用杯数−1 的话间隔会变成 1 小时 43 分，和用户脑子里的数对不上）
    static func times(
        in plan: WaterPlan,
        on day: Date,
        calendar: Calendar = TradingSession.calendar
    ) -> [Date] {
        let base = calendar.startOfDay(for: day)
        return plan.cupMinutes.compactMap { calendar.date(byAdding: .minute, value: $0, to: base) }
    }

    /// 「错过不补」的新鲜度窗口：取**相邻两杯的最小间隔**。
    ///
    /// 自定义时间可能疏密不均，用最小的那个才不会被稀疏的一段把窗口放大 ——
    /// 否则 14:00 和 18:00 之间空出一大段时，18:30 打开 app 还会补响 14:00 那杯
    static func freshnessWindow(_ plan: WaterPlan) -> TimeInterval {
        let minutes = plan.cupMinutes.sorted()
        guard minutes.count > 1 else { return 60 * 60 }   // 只有一杯时给一小时
        let gaps = zip(minutes.dropFirst(), minutes).map { Double($0 - $1) * 60 }
        return max(60, gaps.min() ?? 3600)
    }

    /// 今天还没到、且还没喝够的下一次。喝够了 / 过点了 / 没开 → nil
    static func nextTime(
        after now: Date,
        plan: WaterPlan,
        progress: WaterProgress,
        calendar: Calendar = TradingSession.calendar
    ) -> Date? {
        guard plan.isEnabled, progress.drunk < plan.effectiveCups else { return nil }
        return times(in: plan, on: now, calendar: calendar).first { $0 > now }
    }

    /// 现在该不该为某一杯响一次；返回杯号（0 起），不该响返回 nil。
    ///
    /// ⚠️ **只找「最近刚过」的那一杯，错过的一律不补。** 否则关了三天再打开，
    /// 会被一堆积压的喝水弹窗糊脸。判定用「距今不超过一个间隔」——
    /// 间隔本身跟着配置缩放，不必另设常数
    static func dueCup(
        at now: Date,
        plan: WaterPlan,
        fired: Set<Int>,
        calendar: Calendar = TradingSession.calendar
    ) -> Int? {
        guard plan.isEnabled else { return nil }
        let todays = times(in: plan, on: now, calendar: calendar)
        guard let index = todays.lastIndex(where: { $0 <= now }) else { return nil }
        // 最近这杯已经响过就不再往前找 —— 那些属于「错过」，不补
        guard !fired.contains(index) else { return nil }
        return now.timeIntervalSince(todays[index]) <= freshnessWindow(plan) ? index : nil
    }

    /// "3/8"
    static func text(drunk: Int, cups: Int) -> String { "\(drunk)/\(cups)" }

    /// yyyy-MM-dd
    static func dayString(for date: Date, calendar: Calendar = TradingSession.calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

// MARK: - 状态

/// 存盘的整体。**顶层类型**，不嵌进 `WaterTracker` ——
/// 把 Codable 模型嵌进 @MainActor 类型，Swift 6 下会把全局 actor 隔离带进合成的解码器里
private struct WaterState: Codable {
    var plan = WaterPlan()
    var progress = WaterProgress()
    /// 今天已经响过的杯号（0 起）。跨天时和 progress 一起清
    var firedCups: [Int] = []

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plan = try container.decodeIfPresent(WaterPlan.self, forKey: .plan) ?? WaterPlan()
        progress = try container.decodeIfPresent(WaterProgress.self, forKey: .progress) ?? WaterProgress()
        firedCups = try container.decodeIfPresent([Int].self, forKey: .firedCups) ?? []
    }
}

@MainActor
final class WaterTracker {
    static let stateKey = "waterState"

    private let defaults: UserDefaults
    private var state: WaterState

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.stateKey),
           let decoded = try? JSONDecoder().decode(WaterState.self, from: data) {
            state = decoded
        } else {
            // 解不出来就回默认值。**不顺手把那个 key 删掉** ——
            // 留着，用户改回正确配置后下一版还读得到
            state = WaterState()
        }
    }

    var plan: WaterPlan { state.plan }
    var progress: WaterProgress { state.progress }
    var isEnabled: Bool { state.plan.isEnabled }
    /// 会议模式补放时用它认领这条提醒（见 `WaterPlan.alertKey` 的注释）
    var alertKey: UUID { state.plan.alertKey }

    /// 头顶牌子上显示的进度。没开就 nil —— 不占人物头顶那个位置
    var plaqueText: String? {
        guard state.plan.isEnabled else { return nil }
        return "💧 " + WaterSchedule.text(drunk: state.progress.drunk, cups: state.plan.effectiveCups)
    }

    /// 菜单里那行状态
    var menuStatusText: String {
        guard state.plan.isEnabled else { return "未开启" }
        return WaterSchedule.text(drunk: state.progress.drunk, cups: state.plan.effectiveCups)
    }

    /// 改配置。`alertKey` 强制保留原值 —— 它一变，会议模式攒下的那条就认不出来了
    func setPlan(_ plan: WaterPlan) {
        var next = plan
        next.alertKey = state.plan.alertKey
        state.plan = next
        save()
    }

    func setEnabled(_ enabled: Bool) {
        var next = state.plan
        next.isEnabled = enabled
        setPlan(next)
    }

    /// 跨天就归零。app 一直开着跨零点也要正确重置。返回是否真的重置了
    @discardableResult
    func resetIfNewDay(now: Date = Date(), calendar: Calendar = TradingSession.calendar) -> Bool {
        let today = WaterSchedule.dayString(for: now, calendar: calendar)
        guard state.progress.day != today else { return false }
        state.progress = WaterProgress(day: today, drunk: 0)
        // 已响的杯号要一起清，否则第二天会「这一杯已经响过了」
        state.firedCups = []
        save()
        return true
    }

    /// 记一杯。已经喝够就返回 false，不改状态
    @discardableResult
    func record(now: Date = Date()) -> Bool {
        resetIfNewDay(now: now)
        guard state.progress.drunk < state.plan.effectiveCups else { return false }
        state.progress.drunk += 1
        save()
        return true
    }

    /// 现在该不该提醒；返回该响的杯号
    func dueCup(at now: Date = Date(), calendar: Calendar = TradingSession.calendar) -> Int? {
        WaterSchedule.dueCup(at: now, plan: state.plan, fired: Set(state.firedCups), calendar: calendar)
    }

    func markFired(_ cup: Int) {
        state.firedCups.append(cup)
        save()
    }

    private func save() {
        // 编码失败绝不能 set(nil)：那会把整个 key 删掉，等于清空用户的配置和进度
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.stateKey)
    }
}
