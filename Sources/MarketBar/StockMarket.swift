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

    private var timeZone: TimeZone {
        switch self {
        case .mainland: return TradingSession.timeZone
        case .hongKong: return TimeZone(identifier: "Asia/Hong_Kong")!
        case .unitedStates: return TimeZone(identifier: "America/New_York")!
        }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    var timeZoneName: String {
        switch self {
        case .mainland: return "北京时间"
        case .hongKong: return "香港时间"
        case .unitedStates: return "纽约时间"
        }
    }

    func dateString(for date: Date) -> String {
        TradingSession.dateString(for: date, calendar: calendar)
    }

    func quoteTime(from timestamp: String) -> Date? {
        let format: String
        if timestamp.range(of: "^[0-9]{14}$", options: .regularExpression) != nil {
            format = "yyyyMMddHHmmss"
        } else if timestamp.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$",
                                  options: .regularExpression) != nil {
            format = "yyyy-MM-dd HH:mm:ss"
        } else if timestamp.range(of: "^[0-9]{4}/[0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$",
                                  options: .regularExpression) != nil {
            format = "yyyy/MM/dd HH:mm:ss"
        } else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.isLenient = false
        formatter.dateFormat = format
        return formatter.date(from: timestamp)
    }

    func formattedQuoteTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    func isRegularSession(at date: Date, holidays: [String: String] = [:]) -> Bool {
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, weekday != 1, weekday != 7,
              let hour = parts.hour, let minute = parts.minute else { return false }
        if self == .mainland, !MarketCalendar.isTradingDay(date, holidays: holidays) { return false }
        let now = hour * 60 + minute
        switch self {
        case .mainland:
            return (9 * 60 + 30..<11 * 60 + 30).contains(now)
                || (13 * 60..<15 * 60).contains(now)
        case .hongKong:
            return (9 * 60 + 30..<12 * 60).contains(now)
                || (13 * 60..<16 * 60).contains(now)
        case .unitedStates:
            return (9 * 60 + 30..<16 * 60).contains(now)
        }
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
        return isRegularSession(at: date)
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

enum QuoteFreshness: Equatable, Sendable {
    case unavailable
    case unknownTime
    case previousSession
    case closed
    case delayed
    case current

    static func evaluate(
        _ quote: StockQuote,
        at now: Date,
        holidays: [String: String] = [:]
    ) -> QuoteFreshness {
        guard quote.numericPrice != nil else { return .unavailable }
        guard let market = StockMarket.forCode(quote.code),
              !quote.sessionDate.isEmpty, let quotedAt = quote.quotedAt else { return .unknownTime }
        guard quote.sessionDate == market.dateString(for: now) else { return .previousSession }
        guard market.isRegularSession(at: now, holidays: holidays) else { return .closed }
        let age = now.timeIntervalSince(quotedAt)
        guard age >= -60 else { return .unknownTime }
        return age > 180 ? .delayed : .current
    }

    var badge: String {
        switch self {
        case .unavailable: return "无价"
        case .unknownTime: return "未核时"
        case .previousSession: return "旧"
        case .closed: return "休市"
        case .delayed: return "延迟"
        case .current: return ""
        }
    }

    var explanation: String {
        switch self {
        case .unavailable: return "没有可用价格"
        case .unknownTime: return "报价时间缺失或异常，不能确认时效"
        case .previousSession: return "不是该市场当地今天的报价"
        case .closed: return "当前不在该市场正常交易时段"
        case .delayed: return "交易时段内，报价超过 3 分钟未更新"
        case .current: return "正常交易时段内，报价时间距现在不超过 3 分钟"
        }
    }
}
