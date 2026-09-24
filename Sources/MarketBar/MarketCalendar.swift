import Foundation

/// 交易日 / 节假日的判断，以及休市时人物牌子上的问候语。纯逻辑，便于单测。
enum MarketCalendar {
    /// 交易日 = 周一~周五 且 不是法定节假日。
    /// 注意「调休补班」的周末（如某个周日要上班）股市**仍然休市**，所以不能把补班日算成交易日。
    static func isTradingDay(
        _ date: Date,
        holidays: [String: String],
        calendar: Calendar = TradingSession.calendar
    ) -> Bool {
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday else { return false }
        guard weekday != 1, weekday != 7 else { return false }   // 周末
        return holidayName(on: date, holidays: holidays, calendar: calendar) == nil
    }

    /// 当天的节假日名（不是节假日返回 nil）
    static func holidayName(
        on date: Date,
        holidays: [String: String],
        calendar: Calendar = TradingSession.calendar
    ) -> String? {
        holidays[TradingSession.dateString(for: date, calendar: calendar)]
    }

    /// 解析 timor.tech 的年接口：只取 `holiday == true`（法定放假）的日期 → 节日名
    static func parseHolidays(_ data: Data) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["holiday"] as? [String: Any] else { return [:] }

        var result: [String: String] = [:]
        for (_, value) in entries {
            guard let node = value as? [String: Any],
                  node["holiday"] as? Bool == true,
                  let date = node["date"] as? String else { continue }
            result[date] = (node["name"] as? String) ?? "节假日"
        }
        return result
    }

    /// 节假日缓存（按年存本地，跨年自动失效）
    enum HolidayCache {
        static func key(for year: Int) -> String { "marketHolidays-\(year)" }
        static func year(of date: Date, calendar: Calendar = TradingSession.calendar) -> Int {
            calendar.dateComponents([.year], from: date).year ?? 0
        }

        static func load(year: Int, from defaults: UserDefaults) -> [String: String] {
            defaults.dictionary(forKey: key(for: year)) as? [String: String] ?? [:]
        }

        static func save(_ holidays: [String: String], year: Int, to defaults: UserDefaults) {
            defaults.set(holidays, forKey: key(for: year))
        }
    }
}

/// 当日盈亏的显示时段：只在交易日的 09:00–15:30 之间显示，
/// 盘前、收盘后、以及非交易日都不显示（用户要求）。
enum TradingDayDisplay {
    static let profitStartMinute = 9 * 60        // 09:00
    static let profitEndMinute = 15 * 60 + 30    // 15:30

    static func showsTodayProfit(
        at date: Date,
        holidays: [String: String],
        calendar: Calendar = TradingSession.calendar
    ) -> Bool {
        guard MarketCalendar.isTradingDay(date, holidays: holidays, calendar: calendar) else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = parts.hour, let minute = parts.minute else { return false }
        let now = hour * 60 + minute
        return now >= profitStartMinute && now <= profitEndMinute
    }
}

/// 休市时举牌上显示的问候语（代替金价与盈亏数字）
enum MarketClosedGreeting {
    static let headlines = ["今天休市"]

    /// 工作日调休/节假日的问候语池，按日期取模，同一天保持稳定
    static let greetings = [
        "好好休息", "出去走走", "陪陪家人", "喝杯茶", "看看书", "放松一下",
    ]

    static func lines(
        for date: Date,
        holidayName: String?,
        calendar: Calendar = TradingSession.calendar
    ) -> (headline: String, greeting: String) {
        let day = calendar.dateComponents([.day], from: date).day ?? 0

        if let holidayName, !holidayName.isEmpty {
            // 节日名里已经带「节」的就不再重复，如「中秋节」→「中秋节快乐」
            let name = holidayName.hasSuffix("节") ? holidayName : "\(holidayName)节"
            return (name, "节日快乐")
        }

        let parts = calendar.dateComponents([.weekday], from: date)
        if parts.weekday == 1 || parts.weekday == 7 {
            return ("周末愉快", greetings[abs(day) % greetings.count])
        }
        return (headlines[0], greetings[abs(day) % greetings.count])
    }
}
