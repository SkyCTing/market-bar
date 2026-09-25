import Foundation

/// 配置页面里的一行：一个自选标的。`shares` 为 nil 表示未持仓。
struct WatchlistRow: Equatable, Sendable {
    var code: String
    var name: String
    var shares: Int?
    /// 每股持仓成本（均价）。nil = 没设过
    var cost: Double?
}

/// 「自选与持仓」配置页面的编辑草稿。
///
/// 纯逻辑，不碰 AppKit：把「页面上的表格」与「配置文件」之间的换算、代码补全、校验
/// 都收在这里，好单测；窗口那边只管画和收键盘。
struct WatchlistDraft: Equatable {
    var rows: [WatchlistRow]

    init(rows: [WatchlistRow] = []) {
        self.rows = rows
    }

    /// 从配置铺开成表格：自选清单决定行序，持仓挂到对应行上。
    ///
    /// 持仓里有、自选里没有的代码补成一行 —— 否则它在页面上看不见，一保存就被静默抹掉。
    init(config: WatchlistConfig) {
        var rows = config.watchlist.map {
            WatchlistRow(
                code: $0.code,
                name: $0.name,
                shares: config.holdings[$0.code],
                cost: config.costs[$0.code]
            )
        }
        let listed = Set(config.watchlist.map(\.code))
        for code in config.holdings.keys.sorted() where !listed.contains(code) {
            rows.append(WatchlistRow(code: code, name: "", shares: config.holdings[code]))
        }
        self.rows = rows
    }

    /// 回写配置。名称为空用代码兜底（面板那一列不能是空白）；
    /// 股数缺省或非正数不进持仓表（与 `StockHoldings.shares(for:)` 的口径一致）。
    func config() -> WatchlistConfig {
        let items = rows.compactMap { row -> WatchlistConfig.Item? in
            guard !row.code.isEmpty else { return nil }
            // 成本只在有持仓时才有意义；没填股数的行不写成本，
            // 免得以后补上股数时冒出一个陈年成本
            let shares = row.shares.flatMap { $0 > 0 ? $0 : nil }
            let cost = shares == nil ? nil : row.cost.flatMap { $0 > 0 ? $0 : nil }
            return WatchlistConfig.Item(
                code: row.code,
                name: row.name.isEmpty ? row.code : row.name,
                shares: shares,
                cost: cost
            )
        }
        return WatchlistConfig(watchlist: items)
    }

    // MARK: - 增删改

    /// 删除若干行。传入的是**删除前**的下标，所以从大到小删，避免下标位移。
    mutating func remove(at indexes: IndexSet) {
        for index in indexes.sorted(by: >) where rows.indices.contains(index) {
            rows.remove(at: index)
        }
    }

    /// 把 `source` 行挪到 `destination`（`NSTableView` 给的语义：目标下标是移动前的）
    mutating func move(from source: Int, to destination: Int) {
        guard rows.indices.contains(source) else { return }
        let row = rows.remove(at: source)
        rows.insert(row, at: min(max(0, destination), rows.count))
    }

    /// 规范化第 `index` 行的代码（用户可能只输了 6 位数字）。返回是否发生了变化。
    @discardableResult
    mutating func normalizeCode(at index: Int) -> Bool {
        guard rows.indices.contains(index) else { return false }
        let normalized = Self.normalizeCode(rows[index].code)
        guard normalized != rows[index].code else { return false }
        rows[index].code = normalized
        return true
    }

    // MARK: - 校验

    struct Issue: Equatable {
        enum Kind: Equatable {
            case emptyCode
            case malformedCode
            case duplicateCode
        }

        var kind: Kind
        /// 0 起的行号
        var row: Int
        var message: String
    }

    /// 能不能保存。空表是合法的（一只都不看），只是面板里那一整段会消失。
    func issues() -> [Issue] {
        var issues: [Issue] = []
        var seen: [String: Int] = [:]

        for (index, row) in rows.enumerated() {
            let display = index + 1
            guard !row.code.isEmpty else {
                issues.append(Issue(kind: .emptyCode, row: index, message: "第 \(display) 行：代码不能为空"))
                continue
            }
            guard Self.isValidCode(row.code) else {
                issues.append(Issue(
                    kind: .malformedCode,
                    row: index,
                    message: "第 \(display) 行：\(row.code) 不是有效代码（如 sh600036、hk00700、usAAPL）"
                ))
                continue
            }
            if let first = seen[row.code] {
                issues.append(Issue(
                    kind: .duplicateCode,
                    row: index,
                    message: "第 \(display) 行：\(row.code) 与第 \(first + 1) 行重复"
                ))
            } else {
                seen[row.code] = index
            }
        }

        return issues
    }

    // MARK: - 解析（都是纯函数，好单测）

    /// 把用户输的代码补全成腾讯行情要的形式。
    ///
    /// 6 位数字按首位补沪深北，5 位数字补港股；美股代码转成 `usAAPL`。
    /// 认不出来的原样返回，交给 `issues()` 去报错。
    static func normalizeCode(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.hasPrefix("us") {
            let code = "us" + StockMarket.usSymbol(from: String(trimmed.dropFirst(2)))
            return isValidCode(code) ? code : trimmed
        }
        if lower.hasPrefix("hk"), trimmed.dropFirst(2).first?.isNumber == true {
            return "hk" + String(trimmed.dropFirst(2))
        }
        if (lower.hasPrefix("sh") || lower.hasPrefix("sz") || lower.hasPrefix("bj")),
           trimmed.dropFirst(2).first?.isNumber == true {
            return lower
        }
        if trimmed.count == 5, trimmed.allSatisfy(isASCIIDigit) { return "hk" + trimmed }
        if !trimmed.allSatisfy(isASCIIDigit) {
            let code = "us" + StockMarket.usSymbol(from: trimmed)
            return isValidCode(code) ? code : trimmed
        }
        guard trimmed.count == 6 else { return trimmed }

        // ⚠️ 1 / 5 开头的是基金与 ETF（app 自带清单里 16 只有 4 只是这种），
        // 漏了它们的话，用户按提示只打 6 位数字会被判成非法代码，保存直接被拦。
        // 9 开头故意不猜：900xxx 是沪市 B 股、920xxx 是北交所，得用户自己写前缀。
        switch trimmed.first {
        case "6": return "sh" + trimmed   // 沪市 A 股（含科创板 688）
        case "5": return "sh" + trimmed   // 沪市基金 / ETF
        case "0", "3": return "sz" + trimmed   // 深市 A 股 / 创业板
        case "1": return "sz" + trimmed   // 深市基金 / ETF
        case "2": return "sz" + trimmed   // 深市 B 股
        case "4", "8": return "bj" + trimmed   // 北交所
        default: return trimmed
        }
    }

    static func isValidCode(_ code: String) -> Bool {
        let symbol = code.dropFirst(2)
        switch String(code.prefix(2)) {
        case "sh", "sz", "bj":
            return symbol.count == 6 && symbol.allSatisfy(isASCIIDigit)
        case "hk":
            return symbol.count == 5 && symbol.allSatisfy(isASCIIDigit)
        case "us":
            return (1...10).contains(symbol.count)
                && symbol.first?.isASCII == true && symbol.first?.isLetter == true
                && StockMarket.usSymbol(from: String(symbol)) == String(symbol)
                && symbol.allSatisfy { ($0.isASCII && $0.isUppercase && $0.isLetter)
                    || isASCIIDigit($0) || $0 == "." || $0 == "-" }
        default: return false
        }
    }

    /// 股数文本 → 股数。空串、非数字、负数都当作「没持仓」。
    /// 允许带千分位，因为面板上显示的就是 `1,100,000`，用户很可能直接复制回来。
    static func parseShares(_ text: String) -> Int? {
        let cleaned = text
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(cleaned), value > 0 else { return nil }
        return value
    }

    /// 成本文本 → 成本。空串、非数字、非正数都当作「没设过」
    static func parseCost(_ text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(cleaned), value > 0, value.isFinite else { return nil }
        return value
    }

    /// 成本列怎么显示（和面板同一口径，复制回去能原样解析）
    static func costText(_ cost: Double?) -> String {
        HoldingFormat.cost(cost)
    }

    /// 浮动盈亏 =（现价 − 成本）× 股数。缺成本或缺价格就是 nil（不显示 0）
    static func floatingProfit(price: Double?, cost: Double?, shares: Int?) -> Double? {
        guard let price, let cost, cost > 0, let shares, shares > 0 else { return nil }
        return (price - cost) * Double(shares)
    }

    /// 面板上那一列怎么显示，这里就怎么写 （同一口径，复制回去能原样解析）
    static func sharesText(_ shares: Int?) -> String {
        guard let shares, shares > 0 else { return "" }
        return HoldingFormat.sharesText(shares)
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        // 不用 Character.isNumber：它把 "٣"（阿拉伯数字）也算数字，会放过非法代码
        character.isASCII && character.isNumber
    }
}
