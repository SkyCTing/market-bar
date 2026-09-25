import Foundation

/// 持仓股数。
///
/// 独立成表而不是塞进 `StockWatchlist.Entry`：持仓与自选是两回事
/// （上证指数只看不持），而且给 `Entry` 加字段会波及解析器与既有测试的构造点。
///
/// 数据来自配置文件（`WatchlistConfig`），默认值见 `WatchlistConfig.default`；
/// 菜单「自选配置 → 编辑自选与持仓…」改的就是它。
///
/// ⚠️ 持仓代码必须是 `StockWatchlist` 的子集：面板的行由自选清单生成，
/// 持仓表里多出来的代码既不会有行、也拿不到行情，会静默不计入合计（有测试锁住这条）。
/// 配置窗口把这份差额补成行显示出来，就是为了让这条约束在界面上看得见。
enum StockHoldings {
    /// 运行时从配置文件读；菜单里「重新载入配置」可刷新。
    /// `nonisolated(unsafe)`：启动时写一次，之后只在主线程通过 reload() 改，读的地方都是主线程
    nonisolated(unsafe) static var sharesByCode: [String: Int] = WatchlistConfig.load().holdings

    static func reload() {
        sharesByCode = WatchlistConfig.load().holdings
    }

    /// nil = 没有持仓（如上证指数），或股数非正
    static func shares(for code: String) -> Int? {
        guard let shares = sharesByCode[code], shares > 0 else { return nil }
        return shares
    }
}

/// 当日盈亏。纯函数，便于单测。
enum StockProfitLoss {
    /// 单只标的的当日盈亏（元）= 今日涨跌额 × 股数。
    ///
    /// 返回 nil 表示「不可用」（无持仓、无行情、涨跌额异常），**不要返回 0** ——
    /// 0 会显示成「0 元」，与「没数据」混淆。
    ///
    /// 非有限值必须挡在这里：行情字段是直接 `Double(fields[31])` 解析的，
    /// `Double("nan")` / `Double("inf")` 都能解析成功；一旦乘上股数再走
    /// `Int(x.rounded())` 会直接 trap 崩溃。
    static func todayProfit(_ quote: StockQuote, shares: Int?) -> Double? {
        guard let shares, shares > 0, quote.price != "--", quote.raise.isFinite else { return nil }
        return quote.raise * Double(shares)
    }

    /// 组合当日盈亏合计（元）。
    ///
    /// 按持仓表遍历（不是按行情字典）：缺行情、无持仓、行情异常的都跳过，
    /// 一个有效标的都没有时返回 nil —— 浮动人物据此退回单行，而不是显示「0」。
    /// 遍历时按代码排序：字典顺序不定，而浮点加法不满足结合律，排序让结果可复现。
    static func totalToday(quotesByCode: [String: StockQuote]) -> Double? {
        var total = 0.0
        var counted = 0

        for code in StockHoldings.sharesByCode.keys.sorted() {
            guard let quote = quotesByCode[code],
                  let profit = todayProfit(quote, shares: StockHoldings.shares(for: code))
            else { continue }
            total += profit
            counted += 1
        }

        return counted > 0 ? total : nil
    }

    /// 取整口径：四舍五入到整数元。计算与显示共用，避免「算一个值、显示另一个值」。
    /// 非有限值返回 nil（与 `todayProfit` 的 guard 构成双重保险）。
    static func roundedYuan(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        return Int(value.rounded())
    }
}

/// 千分位与符号。
///
/// 刻意不用 `NumberFormatter`：它受本机 locale 影响，同一份代码在不同机器上
/// 会输出不同结果（和 `TradingSession` 固定用 UTC+8 是同一个理由）。
enum HoldingFormat {
    /// 股数："1,100,000"
    static func sharesText(_ shares: Int) -> String {
        grouped(String(abs(shares)))
    }

    /// 当日盈亏金额：整数元 + 千分位，非零必带符号。"-6,160" / "+1,100" / "0"
    ///
    /// 符号由**取整后**的整数决定，而不是原始 Double：`(-0.4).rounded() == -0.0` 且
    /// `Int(-0.0) == 0`，所以 -0.4 走的是无符号分支，"-0" 永远不会出现。
    static func profitLossText(_ value: Double) -> String {
        guard let yuan = StockProfitLoss.roundedYuan(value), yuan != 0 else { return "0" }
        return (yuan > 0 ? "+" : "-") + grouped(String(yuan.magnitude))
    }

    /// 三位一组。只喂纯数字串。
    static func grouped(_ digits: String) -> String {
        guard digits.count > 3 else { return digits }

        var result = ""
        for (index, character) in digits.reversed().enumerated() {
            if index > 0, index % 3 == 0 { result.append(",") }
            result.append(character)
        }
        return String(result.reversed())
    }
}
