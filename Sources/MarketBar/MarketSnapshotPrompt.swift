import Foundation

enum MarketSnapshotPrompt {
    static func make(
        goldPrice: Double?,
        quotes: [StockQuote],
        fetchedAt: Date?,
        now: Date = Date()
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TradingSession.timeZone
        let fetched = fetchedAt.map(formatter.string(from:)) ?? "尚未更新"

        var lines = [
            "请根据这份行情快照，分别梳理 A 股、港股、美股的主要变化与值得进一步核实的问题。",
            "先指出过期或缺失的报价；不要假设数据实时，不要给出买卖指令或保证收益。",
            "以下数据来自公开报价接口，可能延迟。抓取时间（北京时间）：\(fetched)。",
        ]
        if let goldPrice, goldPrice.isFinite, goldPrice > 0 {
            lines.append("积存金：\(String(format: "%.2f", goldPrice)) CNY/克")
        }

        let limited = quotes.prefix(20)
        for quote in limited {
            let market = StockMarket.forCode(quote.code)
            let currency = market?.currency ?? "未知币种"
            let percent = quote.numericPrice == nil || !quote.raisePercent.isFinite
                ? "--"
                : String(format: "%+.2f%%", quote.raisePercent * 100)
            let session = quote.sessionDate.isEmpty ? "日期未知" : quote.sessionDate
            let stale = market.map { quote.sessionDate != $0.dateString(for: now) } ?? true
            lines.append(
                "\(quote.code)：\(quote.price) \(currency)，涨跌 \(percent)，报价日 \(session)"
                    + (stale ? "（非当地今日）" : "")
            )
        }
        if quotes.count > limited.count {
            lines.append("另有 \(quotes.count - limited.count) 只自选未列出。")
        }
        if limited.isEmpty { lines.append("自选行情尚未取得有效报价。") }
        lines.append("这份草稿不包含持仓股数、成本或盈亏；只有我点击「发送」才会提交。")
        return lines.joined(separator: "\n")
    }
}
