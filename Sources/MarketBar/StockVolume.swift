import AppKit
import Foundation

/// A 股交易时段数学。
///
/// 时间基准固定用 UTC+8：A 股时段按北京墙上时间定义，1991 年之后中国不再实行夏令时，
/// 所以固定偏移与 `Asia/Shanghai` 标识符等价，同时免去对本机时区与 tzdata 的依赖
/// （本机可能在任何时区，用 `Calendar.current` 会把整个折算算错）。
enum TradingSession {
    static let timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }()

    /// 09:30 - 11:30 + 13:00 - 15:00，全天 240 分钟
    static let sessionMinutes: Double = 240
    static let openMinutes: Double = 9 * 60 + 30
    static let morningCloseMinutes: Double = 11 * 60 + 30
    static let afternoonOpenMinutes: Double = 13 * 60
    static let afternoonCloseMinutes: Double = 15 * 60
    /// 开盘多久之后才开始按进度折算：更早的样本太少，折算出来的倍数没有参考价值
    static let openingGraceMinutes: Double = 15

    /// 交易时段进度 0...1。
    /// 返回 nil 表示「现在不该显示折算值」：周末、09:30 之前、以及开盘后的宽限期内。
    static func progress(at date: Date, calendar: Calendar = TradingSession.calendar) -> Double? {
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, let hour = parts.hour, let minute = parts.minute else {
            return nil
        }
        // 周末没有任何场次。这里再挡一次，是为了兜住「接口在非交易日盖上当天时间戳」的情况
        guard weekday != 1, weekday != 7 else { return nil }

        let now = Double(hour * 60 + minute)
        guard now >= openMinutes + openingGraceMinutes else { return nil }

        if now <= morningCloseMinutes {
            return (now - openMinutes) / sessionMinutes
        }
        if now < afternoonOpenMinutes {
            // 午休：进度停在上午收市的 120/240
            return (morningCloseMinutes - openMinutes) / sessionMinutes
        }
        if now <= afternoonCloseMinutes {
            return (morningCloseMinutes - openMinutes + now - afternoonOpenMinutes) / sessionMinutes
        }
        return 1
    }

    /// 行情时间戳 `20260923161437` → `2026-09-23`。
    /// 输出与日线日期同格式，可以直接做字符串比较。
    static func sessionDate(fromQuoteTimestamp timestamp: String) -> String? {
        guard timestamp.count >= 8 else { return nil }
        let digits = timestamp.prefix(8)
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }

        let year = digits.prefix(4)
        let month = digits.dropFirst(4).prefix(2)
        let day = digits.dropFirst(6).prefix(2)
        guard let monthValue = Int(month), let dayValue = Int(day),
              (1...12).contains(monthValue), (1...31).contains(dayValue) else { return nil }
        return "\(year)-\(month)-\(day)"
    }

    /// 北京时间的当天日期 `yyyy-MM-dd`
    static func dateString(for date: Date, calendar: Calendar = TradingSession.calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

/// 一根日线里用得到的部分
struct StockDailyBar: Sendable {
    let date: String     // "2026-09-22"
    let volume: Double   // 成交量（手）
}

/// 量能（放量 / 缩量）的选基与判定，纯逻辑，便于单测。
enum StockVolume {
    static let expansionThreshold = 1.2
    static let shrinkageThreshold = 0.8

    /// 昨日全天量 = 日期严格早于会话日的最后一根日线。
    ///
    /// 不能取「倒数第二根」：周六看到的日线最后一根是周五（会话日也是周五），
    /// 倒数第二根会错拿成周四。按会话日比较还带来一个好处——今日那根是否已经生成
    /// 都不影响结果，所以日线每个交易日只需拉一次就能缓存一整天。
    static func previousVolume(from bars: [StockDailyBar], sessionDate: String) -> Double? {
        bars.last(where: { $0.date < sessionDate })?.volume
    }

    /// 量能倍数 = 预估全天量 ÷ 昨日全天量 = (今日累计量 ÷ 进度) ÷ 昨日全天量
    static func ratio(todayVolume: Double, previousVolume: Double?, progress: Double?) -> Double? {
        guard let progress, progress > 0, progress <= 1 else { return nil }
        guard todayVolume > 0, let previousVolume, previousVolume > 0 else { return nil }
        return (todayVolume / progress) / previousVolume
    }

    enum Word: Equatable {
        case expansion   // 放量
        case shrinkage   // 缩量
        case none
    }

    /// 判定与显示共用同一个两位小数值，否则 0.796 会显示成 0.80 却不标「缩量」，自相矛盾。
    static func normalized(_ ratio: Double) -> Double {
        (ratio * 100).rounded() / 100
    }

    static func word(for ratio: Double?) -> Word {
        guard let ratio else { return .none }
        let value = normalized(ratio)
        if value >= expansionThreshold { return .expansion }
        if value <= shrinkageThreshold { return .shrinkage }
        return .none
    }

    /// 倍数本身（右对齐用）："1.95" / "12.3" / "--"
    static func ratioText(_ ratio: Double?) -> String {
        guard let ratio else { return "--" }
        let value = normalized(ratio)
        return value < 10 ? String(format: "%.2f", value) : String(format: "%.1f", value)
    }

    /// 标记（单独一列，左对齐）："放量" / "缩量" / ""（中性不标）
    static func wordText(for ratio: Double?) -> String {
        switch word(for: ratio) {
        case .expansion: return "放量"
        case .shrinkage: return "缩量"
        case .none: return ""
        }
    }

    /// 量能列的完整文本：倍数补齐到固定宽度、后面紧跟标记，读起来像一列文字
    /// "1.83 放量" / "0.63 缩量" / "1.26" / "--"
    static func volumeText(_ ratio: Double?) -> String {
        let number = ratioText(ratio)
        let padded = number.count >= ratioColumnCharacterWidth
            ? number
            : number + String(repeating: " ", count: ratioColumnCharacterWidth - number.count)
        let word = wordText(for: ratio)
        return word.isEmpty ? padded : padded + " " + word
    }

    /// 倍数文本的固定字符宽度（"1.83"、"12.3" 都是 4；"--" 补齐成 4）
    static let ratioColumnCharacterWidth = 4

    /// 名称列后面的尾巴文本：" 0.83" / " 0.47 缩量" / " 12.3 放量" / " --"
    static func tailText(ratio: Double?) -> String {
        guard let ratio else { return " --" }
        let value = normalized(ratio)
        let number = value < 10 ? String(format: "%.2f", value) : String(format: "%.1f", value)
        switch word(for: ratio) {
        case .expansion: return " \(number) 放量"
        case .shrinkage: return " \(number) 缩量"
        case .none: return " \(number)"
        }
    }
}

/// 面板的一行：接口原始数据 + 由时钟与日线缓存派生出的量能倍数。
/// 倍数不放进 `StockQuote`，因为它是时钟和缓存的派生物，不是接口原样数据。
struct StockRow: Sendable {
    let quote: StockQuote
    let volumeRatio: Double?
    /// 当日盈亏是否显示（盘前/收盘后/非交易日为 false，单元格留空）
    var showsProfitLoss: Bool = true

    // 持仓相关都做成计算属性：构造点不用改，也不会和持仓表或行情漂移。

    /// nil = 没有持仓（如指数），或股数非正
    var shares: Int? { StockHoldings.shares(for: quote.code) }

    /// 当日盈亏（元）；无持仓 / 无行情 / 涨跌额异常时为 nil
    var profitLoss: Double? {
        guard showsProfitLoss else { return nil }
        return StockProfitLoss.todayProfit(quote, shares: shares)
    }

    /// 每股成本；没设过就是 nil
    var cost: Double? { StockHoldings.cost(for: quote.code) }

    /// 浮动盈亏（元）=（现价 − 成本）× 股数。
    /// 缺成本或缺现价就是 nil —— 不要显示成 0，那和「不赚不亏」分不清
    var floatingProfit: Double? {
        guard let price = quote.numericPrice, let cost, let shares else { return nil }
        return (price - cost) * Double(shares)
    }

    /// 面板单元格文本：无持仓时是**空串**（留白），不是 "--"
    var sharesText: String { shares.map(HoldingFormat.sharesText) ?? "" }
    var profitLossText: String { profitLoss.map(HoldingFormat.profitLossText) ?? "" }
    var costText: String { HoldingFormat.cost(cost) }

    /// 浮动收益率 =（现价 − 成本）÷ 成本。只要成本与现价，与股数无关
    var floatingProfitPercent: Double? {
        guard let price = quote.numericPrice, let cost, cost > 0 else { return nil }
        return (price - cost) / cost
    }

    /// 面板那一格：「金额  收益率%」。缺成本或缺持仓就是空串（留白），不是 "--"
    var floatingProfitText: String {
        HoldingFormat.floatingProfit(profit: floatingProfit, percent: floatingProfitPercent)
    }
}

/// 悬浮面板的配色与富文本。`NSColor` 不是 Sendable，所以整体限定在主线程。
@MainActor
enum HoverPalette {
    static let rise = NSColor(calibratedRed: 0.95, green: 0.25, blue: 0.22, alpha: 1)
    static let fall = NSColor(calibratedRed: 0.2, green: 0.78, blue: 0.35, alpha: 1)
    static let labelText = NSColor(white: 0.5, alpha: 1)
    static let valueText = NSColor(white: 0.85, alpha: 1)
    static let sectionTitle = NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.0, alpha: 1)

    /// 涨跌配色（红涨绿跌），0 与 nil 走 fallback
    static func trendColor(_ value: Double?, fallback: NSColor) -> NSColor {
        guard let value else { return fallback }
        if value < 0 { return fall }
        if value > 0 { return rise }
        return fallback
    }

    /// 放量红、缩量绿，其余与名称同灰
    static func volumeColor(for word: StockVolume.Word) -> NSColor {
        switch word {
        case .expansion: return rise
        case .shrinkage: return fall
        case .none: return labelText
        }
    }

}
