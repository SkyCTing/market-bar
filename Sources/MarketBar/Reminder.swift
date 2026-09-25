import Foundation

/// 一条提醒：定时（某时刻 + 重复规则）或倒计时（从现在起一段时长）+ 文案 + 提醒方式
struct Reminder: Codable, Equatable, Identifiable, Sendable {
    /// 触发方式
    enum Kind: String, Codable, Equatable, Sendable {
        /// 定时：某个时刻 + 重复规则
        case scheduled
        /// 倒计时：从现在起一段时长，跑完在人物头顶显示剩余时间
        case countdown
    }

    /// 提醒方式，可多选 —— 用户要求两种能各自单开，也能同时开。
    struct Methods: OptionSet, Codable, Equatable, Sendable {
        let rawValue: Int

        /// 宠物冒气泡说出内容 + 响一声
        static let bubble = Methods(rawValue: 1 << 0)
        /// 置顶模态框（会阻塞主线程一整轮刷新，能不弹就不弹）
        static let alert = Methods(rawValue: 1 << 1)

        /// 两个都开 —— 也就是「先气泡，60 秒没人理再弹窗」那条路
        static let `default`: Methods = [.bubble, .alert]

        var title: String {
            switch (contains(.bubble), contains(.alert)) {
            case (true, true): return "宠物提示 + 弹窗"
            case (true, false): return "宠物提示"
            case (false, true): return "弹窗"
            case (false, false): return "不提醒"
            }
        }

        init(rawValue: Int) { self.rawValue = rawValue }

        // 存成一个整数，比 {"rawValue": 3} 紧凑，也和 UserDefaults 里的旧数据好相处
        init(from decoder: Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(Int.self)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    enum Repeat: Codable, Equatable, Sendable {
        case daily
        case weekly(weekday: Int)   // 1=周日 … 7=周六（Calendar 的 weekday 约定）
        case monthly(day: Int)      // 1…31，当月没有这一天就跳过
        case everyDays(interval: Int)  // 每 N 天（从创建那天算起）

        var title: String {
            switch self {
            case .daily: return "每天"
            case .weekly(let weekday):
                let names = ["", "周日", "周一", "周二", "周三", "周四", "周五", "周六"]
                return "每\(names.indices.contains(weekday) ? names[weekday] : "周")"
            case .monthly(let day): return "每月\(day)号"
            case .everyDays(let interval): return "每\(interval)天"
            }
        }
    }

    var id: UUID = UUID()
    var kind: Kind = .scheduled
    var title: String = "提醒"
    var body: String
    var hour: Int
    var minute: Int
    /// 秒级精度（用户要求）
    var second: Int = 0
    var repeatRule: Repeat = .daily
    /// 勾上 = 节假日（含周末）不提醒；默认不勾 = 照常提醒
    var skipHolidays: Bool = false
    /// 「每 N 天」的起算日（yyyy-MM-dd，北京时间）。创建时写入，编辑不重置
    var anchorDay: String = ""

    // ── 倒计时专用
    /// 时长（秒）
    var countdownSeconds: Int = 0
    /// 本轮计时的起点。为 nil = 没在跑（一次性倒计时响完就置空）
    var countdownStartedAt: Date?
    /// 到点后自动从头再来（番茄钟那种）
    var repeatsCountdown: Bool = false

    /// 提醒方式
    var methods: Methods = .default

    /// 显式声明键：新增字段后要能兼容旧数据（见文件末尾的 init(from:)）
    enum CodingKeys: String, CodingKey {
        case id, kind, title, body, hour, minute, second, repeatRule, skipHolidays, anchorDay
        case countdownSeconds, countdownStartedAt, repeatsCountdown, methods
    }

    var timeText: String { String(format: "%02d:%02d:%02d", hour, minute, second) }

    var summary: String {
        switch kind {
        case .scheduled:
            return "\(timeText)  \(repeatRule.title) · \(body)"
        case .countdown:
            // 与定时那条格式对齐：<前缀>  <重复> · <正文>
            let loop = repeatsCountdown ? "循环" : "一次"
            return "\(CountdownFormat.duration(countdownSeconds))  \(loop) · \(body)"
        }
    }
}

/// 倒计时的时长格式化（纯函数，好单测）
enum CountdownFormat {
    /// 剩余时间："24:59" / "1:02:33" / "1天 02:03:04"
    ///
    /// 秒数向上取整：还剩 0.4 秒时显示 "00:01" 而不是 "00:00"，
    /// 免得「显示 0 了但还没响」这一下让人困惑。
    static func remaining(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.up)))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60

        if days > 0 { return String(format: "%d天 %02d:%02d:%02d", days, hours, minutes, seconds) }
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// 时长的人话说法（菜单与摘要用）："25 分钟" / "1 小时 30 分钟" / "45 秒"
    static func duration(_ seconds: Int) -> String {
        guard seconds > 0 else { return "0 秒" }

        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60

        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) 小时") }
        if minutes > 0 { parts.append("\(minutes) 分钟") }
        // 有小时的时候不再报秒，太啰嗦
        if remainder > 0, hours == 0 { parts.append("\(remainder) 秒") }
        return parts.joined(separator: " ")
    }
}

/// 触发判定：纯逻辑，便于单测
enum ReminderScheduler {
    /// 此刻该不该触发（只判断「到点」与「重复规则匹配」，去重交给调用方）
    static func isDue(
        _ reminder: Reminder,
        at date: Date,
        holidays: [String: String] = [:],
        makeupWorkdays: Set<String> = [],
        calendar: Calendar = TradingSession.calendar
    ) -> Bool {
        // 倒计时不看重复规则也不看节假日 —— 它就是「从现在起 N 分钟后叫我」
        if reminder.kind == .countdown {
            guard let deadline = countdownDeadline(reminder) else { return false }
            return date >= deadline
        }

        // 勾了「智能跳过节假日」时，休息日整天不触发。
        // 注意用的是 isRestDay 而不是 isTradingDay：**调休补班的周六/周日算工作日**，照常提醒
        if reminder.skipHolidays,
           MarketCalendar.isRestDay(date, holidays: holidays, makeupWorkdays: makeupWorkdays, calendar: calendar) {
            return false
        }

        let parts = calendar.dateComponents([.hour, .minute, .second, .weekday, .day], from: date)
        guard parts.hour == reminder.hour,
              parts.minute == reminder.minute,
              (parts.second ?? 0) == reminder.second else { return false }

        switch reminder.repeatRule {
        case .daily:
            return true
        case .weekly(let weekday):
            return parts.weekday == weekday
        case .monthly(let day):
            return parts.day == day
        case .everyDays(let interval):
            // 锚点缺失时按「该触发」处理，避免因为数据缺字段漏提醒
            guard let elapsed = daysBetween(reminder.anchorDay, and: date, calendar: calendar) else { return true }
            return elapsed % max(1, interval) == 0
        }
    }

    // MARK: - 倒计时

    /// 倒计时的到点时刻。没在跑（`startedAt` 为空）或时长为 0 时返回 nil。
    static func countdownDeadline(_ reminder: Reminder) -> Date? {
        guard reminder.kind == .countdown,
              let startedAt = reminder.countdownStartedAt,
              reminder.countdownSeconds > 0
        else { return nil }
        return startedAt.addingTimeInterval(TimeInterval(reminder.countdownSeconds))
    }

    /// 头顶那行倒计时文本；没有正在跑的倒计时就返回 nil
    static func remainingText(_ reminder: Reminder, at date: Date) -> String? {
        guard let deadline = countdownDeadline(reminder) else { return nil }
        return CountdownFormat.remaining(deadline.timeIntervalSince(date))
    }

    /// 倒计时响过之后的新状态：勾了循环就从现在重新起算，否则停掉（`startedAt` 置空）。
    ///
    /// 重新起算用「实际响的时刻」而不是「原定到点时刻」：app 睡了一觉醒来发现
    /// 早就过点了的话，用原定时刻会连着补响好几轮。
    static func afterCountdownFired(_ reminder: Reminder, at date: Date) -> Reminder {
        var updated = reminder
        updated.countdownStartedAt = reminder.repeatsCountdown ? date : nil
        return updated
    }

    /// 两个「天」之间差几天（按北京时间的日历日算）；锚点为空/非法返回 nil
    static func daysBetween(_ anchorDay: String, and date: Date, calendar: Calendar = TradingSession.calendar) -> Int? {
        guard !anchorDay.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TradingSession.timeZone
        guard let anchor = formatter.date(from: anchorDay) else { return nil }

        let from = calendar.startOfDay(for: anchor)
        let to = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: from, to: to).day
    }

    /// 去重键：同一条提醒同一分钟只触发一次
    static func fireKey(_ reminder: Reminder, at date: Date, calendar: Calendar = TradingSession.calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return "\(reminder.id.uuidString)-\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
            + "-\(parts.hour ?? 0)-\(parts.minute ?? 0)-\(parts.second ?? 0)"
    }

    /// 下一次触发时间（菜单里显示用）
    static func nextFireDate(
        after date: Date,
        reminder: Reminder,
        holidays: [String: String] = [:],
        makeupWorkdays: Set<String> = [],
        calendar: Calendar = TradingSession.calendar
    ) -> Date? {
        if reminder.kind == .countdown {
            guard let deadline = countdownDeadline(reminder) else { return nil }
            // 已经过期就立刻触发（比如 app 关着的时候到点了），返回 date 让上层马上排一次
            return max(deadline, date)
        }

        var components = DateComponents()
        components.hour = reminder.hour
        components.minute = reminder.minute
        components.second = reminder.second

        // 「每 N 天」的搜索窗口要跟着 N 走：固定 370 天时，N > 370 永远找不到下一次，
        // 那条提醒就成了菜单上看着正常、却永远不响的死条（填个 400 天就会踩到）。
        // 下一次最多在 N 天内出现（对齐到锚点），再加几天余量兜住「跳过节假日」连跳
        var horizon = 370
        if case .everyDays(let interval) = reminder.repeatRule {
            horizon = max(horizon, max(1, interval) + 7)
        }

        for offset in 0...horizon {
            guard let day = calendar.date(byAdding: .day, value: offset, to: date) else { continue }
            var dayComponents = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            guard let year = dayComponents.year, let month = dayComponents.month, let dayOfMonth = dayComponents.day else { continue }

            switch reminder.repeatRule {
            case .weekly(let weekday) where dayComponents.weekday != weekday:
                continue
            case .monthly(let expected) where dayOfMonth != expected:
                continue
            case .everyDays(let interval):
                guard let elapsed = daysBetween(reminder.anchorDay, and: day, calendar: calendar) else { break }
                if elapsed % max(1, interval) != 0 { continue }
            default:
                break
            }

            components.year = year
            components.month = month
            components.day = dayOfMonth
            guard let candidate = calendar.date(from: components), candidate > date else { continue }
            // 勾了「节假日不提醒」时，落在非交易日的那次直接跳到下一天再看
            if reminder.skipHolidays,
               MarketCalendar.isRestDay(candidate, holidays: holidays, makeupWorkdays: makeupWorkdays, calendar: calendar) {
                continue
            }
            return candidate
        }
        return nil
    }
}

/// 提醒的增删改查（存 UserDefaults）
@MainActor
final class ReminderStore {
    private static let key = "reminders"
    private let defaults: UserDefaults
    private(set) var reminders: [Reminder] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
    }

    /// 逐条解码：数组里某一条解不出来（类型不符、或是更高版本写出的新值）时
    /// **只丢那一条**，不能让整份列表归零 —— 归零之后任何一次 save() 都会把空表
    /// 写回 UserDefaults，用户其余提醒就永久没了（有测试钉住这条）。
    private struct LossyReminder: Decodable {
        let value: Reminder?
        init(from decoder: Decoder) throws {
            value = try? Reminder(from: decoder)
        }
    }

    func reload() {
        guard let data = defaults.data(forKey: Self.key) else {
            reminders = []      // 这个键本来就没有 = 用户没有提醒
            return
        }
        guard let decoded = try? JSONDecoder().decode([LossyReminder].self, from: data) else {
            // 连数组都解不出来（整个键被写坏）—— 保持内存里现有的，别清空。
            // 之后再存一次就会把好的那份写回去，相当于自愈
            return
        }
        reminders = decoded.compactMap(\.value)
    }

    func save() {
        // 编码失败时绝不能 set(nil)：那会把整个 key 删掉，等于清空所有提醒
        guard let data = try? JSONEncoder().encode(reminders) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func upsert(_ reminder: Reminder) {
        if let index = reminders.firstIndex(where: { $0.id == reminder.id }) {
            reminders[index] = reminder
        } else {
            reminders.append(reminder)
        }
        save()
    }

    func remove(id: UUID) {
        reminders.removeAll { $0.id == id }
        save()
    }

    func removeAll() {
        reminders.removeAll()
        save()
    }
}


extension Reminder {
    /// 容忍缺字段的解码：`second` / `skipHolidays` / `kind` / `methods` 都是后加的，
    /// 用编译器合成的 init(from:) 遇到旧数据会直接抛 keyNotFound，导致**已有提醒全被清空**。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? "提醒",
            body: try container.decodeIfPresent(String.self, forKey: .body) ?? "提醒",
            hour: try container.decodeIfPresent(Int.self, forKey: .hour) ?? 9,
            minute: try container.decodeIfPresent(Int.self, forKey: .minute) ?? 0,
            repeatRule: try container.decodeIfPresent(Repeat.self, forKey: .repeatRule) ?? .daily
        )
        // 旧数据没有 kind —— 一律当定时提醒，行为与升级前完全一致
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .scheduled
        second = try container.decodeIfPresent(Int.self, forKey: .second) ?? 0
        skipHolidays = try container.decodeIfPresent(Bool.self, forKey: .skipHolidays) ?? false
        anchorDay = try container.decodeIfPresent(String.self, forKey: .anchorDay) ?? ""
        countdownSeconds = try container.decodeIfPresent(Int.self, forKey: .countdownSeconds) ?? 0
        countdownStartedAt = try container.decodeIfPresent(Date.self, forKey: .countdownStartedAt)
        repeatsCountdown = try container.decodeIfPresent(Bool.self, forKey: .repeatsCountdown) ?? false
        // 旧数据没有 methods —— 用默认的「两个都开」，也就是升级前那条路
        methods = try container.decodeIfPresent(Methods.self, forKey: .methods) ?? .default
    }
}
