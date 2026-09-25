import Foundation

enum StockMarket: Sendable {
    case mainland
    case hongKong
    case unitedStates

    static func forCode(_ code: String) -> StockMarket? {
        if code.hasPrefix("sh") || code.hasPrefix("sz") || code.hasPrefix("bj") { return .mainland }
        if code.hasPrefix("hk") { return .hongKong }
        if code.hasPrefix("us") { return .unitedStates }
        return nil
    }

    var currency: String {
        switch self {
        case .mainland: return "CNY"
        case .hongKong: return "HKD"
        case .unitedStates: return "USD"
        }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        switch self {
        case .mainland: calendar.timeZone = TradingSession.timeZone
        case .hongKong: calendar.timeZone = TimeZone(identifier: "Asia/Hong_Kong")!
        case .unitedStates: calendar.timeZone = TimeZone(identifier: "America/New_York")!
        }
        return calendar
    }

    func dateString(for date: Date) -> String {
        TradingSession.dateString(for: date, calendar: calendar)
    }

    /// 正常交易时段的进度；盘前或周末返回 nil，收盘后返回 1。
    /// 美股使用纽约时区，夏令时由系统日历处理，不用固定北京时间偏移。
    func progress(at date: Date) -> Double? {
        if self == .mainland { return TradingSession.progress(at: date) }
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, weekday != 1, weekday != 7,
              let hour = parts.hour, let minute = parts.minute else { return nil }
        let now = hour * 60 + minute
        let open = 9 * 60 + 30

        switch self {
        case .hongKong:
            guard now >= open + 15 else { return nil }
            if now < 12 * 60 { return Double(now - open) / 330 }
            if now < 13 * 60 { return 150.0 / 330 }
            return min(1, Double(150 + now - 13 * 60) / 330)
        case .unitedStates:
            guard now >= open + 15 else { return nil }
            return min(1, Double(now - open) / 390)
        case .mainland:
            return TradingSession.progress(at: date)
        }
    }

    /// 外盘只在当地当日有新行情、且正处于正常交易时段时显示当日盈亏。
    func showsTodayProfit(at date: Date, quoteDate: String) -> Bool {
        guard self != .mainland, quoteDate == dateString(for: date) else { return false }
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, weekday != 1, weekday != 7,
              let hour = parts.hour, let minute = parts.minute else { return false }
        let now = hour * 60 + minute
        switch self {
        case .hongKong:
            return (9 * 60 + 30..<12 * 60).contains(now)
                || (13 * 60..<16 * 60).contains(now)
        case .unitedStates:
            return (9 * 60 + 30..<16 * 60).contains(now)
        case .mainland:
            return false
        }
    }

    /// 腾讯美股搜索返回 `AAPL.OQ` / `BRK.B.N`，行情请求用 `usAAPL` / `usBRK.B`。
    static func usSymbol(from raw: String) -> String {
        let upper = raw.uppercased()
        for suffix in [".OQ", ".N", ".AM", ".PS", ".PK"] where upper.hasSuffix(suffix) {
            return String(upper.dropLast(suffix.count))
        }
        return upper
    }
}
