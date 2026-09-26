import Foundation
import XCTest

@testable import MarketBar

/// 分组与持仓汇总。两者都依赖 `StockHoldings` 的全局表，所以测试里显式设定并还原。
final class HoldingSummaryTests: XCTestCase {
    private var savedShares: [String: Int] = [:]
    private var savedCosts: [String: Double] = [:]

    override func setUp() {
        super.setUp()
        savedShares = StockHoldings.sharesByCode
        savedCosts = StockHoldings.costsByCode
    }

    override func tearDown() {
        StockHoldings.sharesByCode = savedShares
        StockHoldings.costsByCode = savedCosts
        super.tearDown()
    }

    private func row(_ code: String, price: String, raise: Double = 0, shares: Int? = nil, cost: Double? = nil) -> StockRow {
        // ⚠️ 必须显式设成 nil 而不是「不设」：全局表里可能还留着这台机器上
        // 真实配置的值，不清掉的话「没设成本」的用例会偷偷用上真实成本
        StockHoldings.sharesByCode[code] = shares
        StockHoldings.costsByCode[code] = cost
        return StockRow(
            quote: StockQuote(
                code: code, name: code, price: price, raise: raise, raisePercent: 0,
                volume: 0, sessionDate: "2026-09-26", quotedAt: nil
            ),
            volumeRatio: nil
        )
    }

    // MARK: 分组

    /// 组的顺序固定，不按清单里首次出现的顺序 —— 否则改一下清单顺序，分组标题就跳
    func testGroupsUseFixedOrder() {
        let rows = [
            row("usAAPL", price: "200"),
            row("sh600036", price: "40"),
            row("hk00700", price: "400"),
        ]

        XCTAssertEqual(StockGrouping.groups(rows).map(\.title), ["A股", "港股", "美股"])
    }

    func testEmptyGroupsAreOmitted() {
        let groups = StockGrouping.groups([row("sh600036", price: "40")])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].title, "A股")
        XCTAssertEqual(groups[0].rows.count, 1)
    }

    func testUnknownCodeGoesToTheLastGroup() {
        let groups = StockGrouping.groups([row("xx123", price: "1")])

        XCTAssertEqual(groups.map(\.title), ["其它"])
        XCTAssertNil(groups[0].market)
    }

    func testRowsKeepTheirOrderInsideAGroup() {
        let groups = StockGrouping.groups([
            row("sh600036", price: "40"),
            row("hk00700", price: "400"),
            row("sh512170", price: "1.2"),
        ])

        XCTAssertEqual(groups[0].rows.map(\.quote.code), ["sh600036", "sh512170"])
        XCTAssertEqual(
            StockGrouping.displayRows([
                row("usAAPL", price: "200"), row("sh600036", price: "40"),
                row("hk00700", price: "400"), row("sh512170", price: "1.2"),
            ]).map(\.quote.code),
            ["sh600036", "sh512170", "hk00700", "usAAPL"]
        )
    }

    // MARK: 分币种汇总

    func testSummariesSplitByCurrency() {
        let rows = [
            row("sh600036", price: "40", raise: 1, shares: 1_000, cost: 38),
            row("hk00700", price: "400", raise: -2, shares: 200, cost: 380),
        ]

        let summaries = HoldingSummaryBuilder.summaries(rows)

        XCTAssertEqual(summaries.map(\.currency), ["CNY", "HKD"])
        XCTAssertEqual(summaries[0].marketValue, 40_000)
        XCTAssertEqual(summaries[0].todayProfit, 1_000)
        XCTAssertEqual(summaries[0].floatingProfit, 2_000)
        XCTAssertEqual(summaries[1].marketValue, 80_000)
        XCTAssertEqual(summaries[1].todayProfit, -400)
        XCTAssertEqual(summaries[1].floatingProfit, 4_000)
    }

    /// 不同币种绝不相加 —— 这是面板一直以来的口径
    func testCurrenciesAreNeverSummed() {
        let summaries = HoldingSummaryBuilder.summaries([
            row("sh600036", price: "40", shares: 1_000, cost: 38),
            row("usAAPL", price: "200", shares: 10, cost: 180),
        ])

        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries[0].marketValue, 40_000, "人民币只算人民币的")
        XCTAssertEqual(summaries[1].marketValue, 2_000, "美元只算美元的")
    }

    /// 浮动收益率的分母只算「有成本的那些」，否则比例对不上
    func testFloatingPercentOnlyCountsPricedHoldings() {
        let rows = [
            row("sh600036", price: "40", shares: 1_000, cost: 38),   // 成本 38,000，浮盈 2,000
            row("sh512170", price: "1.2", shares: 10_000),           // 没设成本，不进比例
        ]

        let summary = HoldingSummaryBuilder.summaries(rows)[0]

        XCTAssertEqual(summary.floatingProfit, 2_000)
        XCTAssertEqual(summary.floatingPercent!, 2_000 / 38_000, accuracy: 1e-9)
        XCTAssertEqual(summary.counted, 2, "没成本的也要计进市值")
    }

    /// 没持仓的（指数）不进汇总
    func testRowsWithoutSharesAreSkipped() {
        let summaries = HoldingSummaryBuilder.summaries([
            row("sh000001", price: "3400"),
            row("sh600036", price: "40", shares: 1_000),
        ])

        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].counted, 1)
        XCTAssertEqual(summaries[0].marketValue, 40_000)
    }

    /// 没行情的（停牌）跳过：算进去会让「市值涨了但当日盈亏没动」这种自相矛盾出现
    func testRowsWithoutPriceAreSkipped() {
        let summaries = HoldingSummaryBuilder.summaries([
            row("sh600036", price: "--", shares: 1_000, cost: 38),
        ])

        XCTAssertTrue(summaries.isEmpty)
    }

    /// 一个都没算出来时给 nil，别显示成 0 —— 0 和「没数据」分不清
    func testMissingNumbersAreNilNotZero() {
        let summary = HoldingSummaryBuilder.summaries([
            row("sh600036", price: "40", shares: 1_000),   // 没成本
        ])[0]

        XCTAssertEqual(summary.marketValue, 40_000)
        XCTAssertNil(summary.floatingProfit)
        XCTAssertNil(summary.floatingPercent)
    }

    func testEmptyInputGivesNoSummaries() {
        XCTAssertTrue(HoldingSummaryBuilder.summaries([]).isEmpty)
    }

    // MARK: 面板那一行的文本

    func testLineText() {
        let summary = HoldingSummary(
            currency: "CNY", marketValue: 1_284_000,
            todayProfit: 1_234, floatingProfit: 8_055, floatingPercent: 0.067,
            counted: 3
        )

        XCTAssertEqual(summary.lineText, "A股   市值 1,284,000   当日 +1,234   浮动 +8,055 (+6.70%)")
    }

    func testLineTextSkipsMissingParts() {
        let summary = HoldingSummary(
            currency: "USD", marketValue: 20_000,
            todayProfit: nil, floatingProfit: nil, floatingPercent: nil,
            counted: 1
        )

        XCTAssertEqual(summary.lineText, "美股   市值 20,000", "缺的项直接不出现，不留「--」")
    }

    func testLineTextForEachCurrency() {
        func title(_ currency: String) -> String {
            HoldingSummary(currency: currency, marketValue: 1, todayProfit: nil,
                           floatingProfit: nil, floatingPercent: nil, counted: 1).marketTitle
        }

        XCTAssertEqual(title("CNY"), "A股")
        XCTAssertEqual(title("HKD"), "港股")
        XCTAssertEqual(title("USD"), "美股")
    }

    func testAmountFormatting() {
        XCTAssertEqual(HoldingFormat.amount(1_284_000), "1,284,000")
        XCTAssertEqual(HoldingFormat.amount(0), "0")
        XCTAssertEqual(HoldingFormat.amount(12.4), "12", "四舍五入到整数元")
        XCTAssertEqual(HoldingFormat.amount(-500), "500", "市值不带符号")
        XCTAssertEqual(HoldingFormat.amount(.nan), "—")
    }
}
