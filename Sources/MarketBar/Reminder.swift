import Foundation

/// 一条提醒：时间 + 重复规则 + 文案
struct Reminder: Codable, Equatable, Identifiable, Sendable {
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

    /// 显式声明键：新增字段后要能兼容旧数据（见文件末尾的 init(from:)）
    enum CodingKeys: String, CodingKey {
        case id, title, body, hour, minute, second, repeatRule, skipHolidays, anchorDay
    }

    var timeText: String { String(format: "%02d:%02d:%02d", hour, minute, second) }
    var summary: String { "\(timeText)  \(repeatRule.title) · \(body)" }
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
        var components = DateComponents()
        components.hour = reminder.hour
        components.minute = reminder.minute
        components.second = reminder.second

        for offset in 0...370 {
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

    func reload() {
        guard let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([Reminder].self, from: data) else {
            reminders = []
            return
        }
        reminders = decoded
    }

    func save() {
        defaults.set(try? JSONEncoder().encode(reminders), forKey: Self.key)
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
    /// 容忍缺字段的解码：`second` / `skipHolidays` 是后加的，
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
        second = try container.decodeIfPresent(Int.self, forKey: .second) ?? 0
        skipHolidays = try container.decodeIfPresent(Bool.self, forKey: .skipHolidays) ?? false
        anchorDay = try container.decodeIfPresent(String.self, forKey: .anchorDay) ?? ""
    }
}
