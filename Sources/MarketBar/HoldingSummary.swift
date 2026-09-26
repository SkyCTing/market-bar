import Foundation

/// 自选清单按市场分的组。面板按组显示，每组带一个标题。
/// 注意：不加 Equatable —— `StockRow` 本身不是 Equatable，加不上（测试里按字段断言即可）
struct StockGroup: Sendable {
    /// nil = 代码认不出是哪个市场
    let market: StockMarket?
    let title: String
    var rows: [StockRow]
}

enum StockGrouping {
    /// 组的排列顺序固定：A股 → 港股 → 美股 → 其它。
    /// 不按「首次出现的顺序」—— 那样清单一改顺序，分组标题就跟着跳。
    /// 空组不出现。
    static func groups(_ rows: [StockRow]) -> [StockGroup] {
        var buckets: [StockGroup] = [
            StockGroup(market: .mainland, title: "A股", rows: []),
            StockGroup(market: .hongKong, title: "港股", rows: []),
            StockGroup(market: .unitedStates, title: "美股", rows: []),
            StockGroup(market: nil, title: "其它", rows: []),
        ]

        for row in rows {
            let market = StockMarket.forCode(row.quote.code)
            let index = buckets.firstIndex { $0.market == market } ?? buckets.count - 1
            buckets[index].rows.append(row)
        }

        return buckets.filter { !$0.rows.isEmpty }
    }
}

/// 一个币种的持仓汇总。**不同币种绝不相加** —— 沿用面板既有的口径。
struct HoldingSummary: Equatable, Sendable {
    let currency: String
    /// 市值 = Σ 现价 × 股数
    let marketValue: Double?
    /// 当日盈亏 = Σ 今日涨跌额 × 股数
    let todayProfit: Double?
    /// 浮动盈亏 = Σ（现价 − 成本）× 股数
    let floatingProfit: Double?
    /// 浮动收益率 = 浮动盈亏 ÷ 持仓成本。成本缺失时是 nil
    let floatingPercent: Double?
    /// 计入的标的数
    let counted: Int
}

enum HoldingSummaryBuilder {
    /// 按币种汇总持仓。
    ///
    /// 只统计**有持仓且有现价**的标的 —— 停牌、无行情的跳过。
    /// 三块金额都基于同一批标的，否则「市值涨了但当日盈亏没动」这种自相矛盾会出现。
    ///
    /// 浮动盈亏另需成本：没设成本的标的只进市值和当日盈亏，
    /// 于是收益率的分子分母都只由「有成本的那些」构成，比例才对得上。
    static func summaries(_ rows: [StockRow]) -> [HoldingSummary] {
        var buckets: [String: (market: Double, today: Double, floating: Double, costValue: Double, counted: Int, todayCounted: Int)] = [:]

        for row in rows {
            guard let shares = row.shares, shares > 0,
                  let price = row.quote.numericPrice,
                  let market = StockMarket.forCode(row.quote.code)
            else { continue }

            let currency = market.currency
            var bucket = buckets[currency] ?? (0, 0, 0, 0, 0, 0)
            bucket.market += price * Double(shares)
            bucket.counted += 1
            if let today = row.profitLoss {
                bucket.today += today
                bucket.todayCounted += 1
            }
            if let floating = row.floatingProfit, let cost = row.cost {
                bucket.floating += floating
                bucket.costValue += cost * Double(shares)
            }
            buckets[currency] = bucket
        }

        // 币种顺序固定，免得每次刷新排列都在变
        return ["CNY", "HKD", "USD"].compactMap { currency in
            guard let bucket = buckets[currency], bucket.counted > 0 else { return nil }
            return HoldingSummary(
                currency: currency,
                marketValue: bucket.market,
                // 一个都没算出来时给 nil，别显示成 0 —— 0 和「没数据」分不清
                todayProfit: bucket.todayCounted > 0 ? bucket.today : nil,
                floatingProfit: bucket.costValue > 0 ? bucket.floating : nil,
                floatingPercent: bucket.costValue > 0 ? bucket.floating / bucket.costValue : nil,
                counted: bucket.counted
            )
        }
    }
}
