import AppKit
import Foundation
import XCTest

@testable import MarketBar

final class MarketSnapshotPromptTests: XCTestCase {
    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private func quote(code: String, name: String, price: String, day: String) -> StockQuote {
        StockQuote(
            code: code, name: name, price: price, raise: 2.43, raisePercent: 0.0072,
            volume: 100, sessionDate: day
        )
    }

    func testPromptMarksStaleQuotesAndIncludesNoCustomNamesOrPositions() {
        let prompt = MarketSnapshotPrompt.make(
            goldPrice: 926.41,
            quotes: [
                quote(code: "usAAPL", name: "我的私人标签", price: "338.35", day: "2026-09-24"),
                quote(code: "hk00700", name: "腾讯", price: "--", day: ""),
            ],
            fetchedAt: date("2026-09-25T10:00:00Z"),
            now: date("2026-09-25T10:00:00Z")
        )

        XCTAssertTrue(prompt.contains("usAAPL：338.35 USD"))
        XCTAssertTrue(prompt.contains("非当地今日"))
        XCTAssertTrue(prompt.contains("hk00700：-- HKD，涨跌 --"))
        XCTAssertTrue(prompt.contains("只有我点击「发送」才会提交"))
        XCTAssertFalse(prompt.contains("我的私人标签"))
        XCTAssertFalse(prompt.contains("股数："))
        XCTAssertFalse(prompt.contains("成本："))
    }

    func testPromptLimitsSizeAndShowsUnavailableState() {
        let quotes = (0..<25).map {
            quote(code: "usA\($0)", name: "N", price: "1", day: "2026-09-25")
        }
        let prompt = MarketSnapshotPrompt.make(
            goldPrice: nil, quotes: quotes, fetchedAt: nil,
            now: date("2026-09-25T16:00:00Z")
        )
        XCTAssertTrue(prompt.contains("另有 5 只自选未列出"))
        XCTAssertFalse(prompt.contains("usA24："))
        XCTAssertTrue(prompt.contains("尚未更新"))
        XCTAssertTrue(MarketSnapshotPrompt.make(
            goldPrice: nil, quotes: [], fetchedAt: nil
        ).contains("自选行情尚未取得有效报价"))
    }

    @MainActor
    func testDraftInsertionDoesNotOverwriteExistingChatInput() {
        let view = ClaudeChatView(frame: NSRect(x: 0, y: 0, width: 420, height: 520))
        view.insertDraft("先前的问题")
        view.insertDraft("当前行情")
        XCTAssertEqual(view.inputText, "先前的问题\n\n当前行情")
    }

    @MainActor
    func testLongDraftCanScrollWithinCappedInputArea() throws {
        let view = ClaudeChatView(frame: NSRect(x: 0, y: 0, width: 420, height: 520))
        view.insertDraft(String(repeating: "需要核对这条行情和报价时间。\n", count: 30))
        view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? NSScrollView }
            .first { $0.documentView is ChatInputTextView })
        XCTAssertLessThanOrEqual(scroll.frame.height, ClaudeChatPanelLayout.inputMaximumHeight)
        XCTAssertGreaterThan(scroll.documentView?.frame.height ?? 0, scroll.contentSize.height)
    }
}


// MARK: - 快照带不带持仓

/// 默认**不带**：持仓是本机数据（股数/成本/盈亏），发不发由用户决定
final class MarketSnapshotHoldingsTests: XCTestCase {
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

    private func quote(_ code: String) -> StockQuote {
        StockQuote(code: code, name: code, price: "40.000", raise: 1, raisePercent: 0.01,
                   volume: 0, sessionDate: "2026-09-26", quotedAt: nil)
    }

    func testHoldingsAreExcludedByDefault() {
        StockHoldings.sharesByCode["sh600036"] = 1_500
        StockHoldings.costsByCode["sh600036"] = 38.123

        let text = MarketSnapshotPrompt.make(goldPrice: 900, quotes: [quote("sh600036")], fetchedAt: nil)

        // 用我加的那句具体标题来断言：单独的「持仓」两字可能出现在别的地方
        XCTAssertFalse(text.contains("以下是我当前的持仓"), "默认不该出现持仓段落")
        XCTAssertFalse(text.contains("1,500"))
        XCTAssertFalse(text.contains("38.123"))
    }

    func testHoldingsAreIncludedWhenAsked() {
        StockHoldings.sharesByCode["sh600036"] = 1_500
        StockHoldings.costsByCode["sh600036"] = 38.123

        let text = MarketSnapshotPrompt.make(
            goldPrice: 900, quotes: [quote("sh600036")], fetchedAt: nil, includesHoldings: true
        )

        XCTAssertTrue(text.contains("以下是我当前的持仓"))
        XCTAssertTrue(text.contains("1,500 股"))
        XCTAssertTrue(text.contains("成本 38.123"))
        // (40 - 38.123) × 1500 = 2815.5 → 取整 2816… 实际按四舍五入
        XCTAssertTrue(text.contains("浮动盈亏"), "有成本有现价就要算浮动盈亏")
    }

    /// 没设成本的只说股数，不编一个成本出来
    func testHoldingWithoutCostOmitsProfit() {
        StockHoldings.sharesByCode["sh600036"] = 1_500
        StockHoldings.costsByCode["sh600036"] = nil

        let text = MarketSnapshotPrompt.make(
            goldPrice: 900, quotes: [quote("sh600036")], fetchedAt: nil, includesHoldings: true
        )

        XCTAssertTrue(text.contains("1,500 股"))
        XCTAssertTrue(text.contains("未设成本"))
        XCTAssertFalse(text.contains("浮动盈亏"))
    }

    /// 没持仓的标的不进持仓段
    func testRowsWithoutSharesAreNotListedAsHoldings() {
        StockHoldings.sharesByCode["sh600036"] = nil
        StockHoldings.costsByCode["sh600036"] = nil

        let text = MarketSnapshotPrompt.make(
            goldPrice: 900, quotes: [quote("sh600036")], fetchedAt: nil, includesHoldings: true
        )

        XCTAssertFalse(text.contains("以下是我当前的持仓"))
    }
}
