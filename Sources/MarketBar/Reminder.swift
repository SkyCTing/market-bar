import Foundation

/// 一条提醒：时间 + 重复规则 + 文案
struct Reminder: Codable, Equatable, Identifiable, Sendable {
    enum Repeat: Codable, Equatable, Sendable {
        case daily
        case weekly(weekday: Int)   // 1=周日 … 7=周六（Calendar 的 weekday 约定）
        case monthly(day: Int)      // 1…31，当月没有这一天就跳过

        var title: String {
            switch self {
            case .daily: return "每天"
            case .weekly(let weekday):
                let names = ["", "周日", "周一", "周二", "周三", "周四", "周五", "周六"]
                return "每\(names.indices.contains(weekday) ? names[weekday] : "周")"
            case .monthly(let day): return "每月\(day)号"
            }
        }
    }

    var id: UUID = UUID()
    var title: String = "提醒"
    var body: String
    var hour: Int
    var minute: Int
    var repeatRule: Repeat = .daily

    var timeText: String { String(format: "%02d:%02d", hour, minute) }
    var summary: String { "\(timeText)  \(repeatRule.title) · \(body)" }
}

/// 触发判定：纯逻辑，便于单测
enum ReminderScheduler {
    /// 此刻该不该触发（只判断「到点」与「重复规则匹配」，去重交给调用方）
    static func isDue(_ reminder: Reminder, at date: Date, calendar: Calendar = TradingSession.calendar) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute, .weekday, .day], from: date)
        guard parts.hour == reminder.hour, parts.minute == reminder.minute else { return false }

        switch reminder.repeatRule {
        case .daily:
            return true
        case .weekly(let weekday):
            return parts.weekday == weekday
        case .monthly(let day):
            return parts.day == day
        }
    }

    /// 去重键：同一条提醒同一分钟只触发一次
    static func fireKey(_ reminder: Reminder, at date: Date, calendar: Calendar = TradingSession.calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return "\(reminder.id.uuidString)-\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)-\(parts.hour ?? 0)-\(parts.minute ?? 0)"
    }

    /// 下一次触发时间（菜单里显示用）
    static func nextFireDate(after date: Date, reminder: Reminder, calendar: Calendar = TradingSession.calendar) -> Date? {
        var components = DateComponents()
        components.hour = reminder.hour
        components.minute = reminder.minute

        for offset in 0...370 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: date) else { continue }
            var dayComponents = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            guard let year = dayComponents.year, let month = dayComponents.month, let dayOfMonth = dayComponents.day else { continue }

            switch reminder.repeatRule {
            case .weekly(let weekday) where dayComponents.weekday != weekday:
                continue
            case .monthly(let expected) where dayOfMonth != expected:
                continue
            default:
                break
            }

            components.year = year
            components.month = month
            components.day = dayOfMonth
            guard let candidate = calendar.date(from: components), candidate > date else { continue }
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
