import Foundation
import XCTest

@testable import MarketBar

final class StockMarketTests: XCTestCase {
    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    func testMarketCurrenciesAndLocalDates() {
        XCTAssertEqual(StockMarket.forCode("sh600036")?.currency, "CNY")
        XCTAssertEqual(StockMarket.forCode("hk00700")?.currency, "HKD")
        XCTAssertEqual(StockMarket.forCode("usAAPL")?.currency, "USD")
        let instant = date("2026-09-25T02:00:00Z")
        XCTAssertEqual(StockMarket.hongKong.dateString(for: instant), "2026-09-25")
        XCTAssertEqual(StockMarket.unitedStates.dateString(for: instant), "2026-09-24")
    }

    func testHongKongLunchBreakAndClose() {
        let market = StockMarket.hongKong
        XCTAssertEqual(market.progress(at: date("2026-09-25T04:30:00Z")) ?? 0,
                       150.0 / 330, accuracy: 1e-9)
        XCTAssertEqual(market.progress(at: date("2026-09-25T06:00:00Z")) ?? 0,
                       210.0 / 330, accuracy: 1e-9)
        XCTAssertEqual(market.progress(at: date("2026-09-25T08:00:00Z")), 1)
    }

    func testUsMarketRespectsNewYorkDaylightSavingTime() {
        let market = StockMarket.unitedStates
        let summer = date("2026-07-01T13:45:00Z") // 09:45 EDT
        let winter = date("2026-01-05T14:45:00Z") // 09:45 EST
        XCTAssertEqual(market.progress(at: summer) ?? 0, 15.0 / 390, accuracy: 1e-9)
        XCTAssertEqual(market.progress(at: winter) ?? 0, 15.0 / 390, accuracy: 1e-9)
        XCTAssertNil(market.progress(at: date("2026-07-04T15:00:00Z"))) // Saturday
    }

    func testForeignProfitRequiresTodayActualQuoteAndRegularSession() {
        let market = StockMarket.unitedStates
        let active = date("2026-07-01T15:00:00Z")
        XCTAssertTrue(market.showsTodayProfit(at: active, quoteDate: "2026-07-01"))
        XCTAssertTrue(market.showsTodayProfit(
            at: date("2026-07-01T13:31:00Z"), quoteDate: "2026-07-01"
        ), "开盘前 15 分钟只应跳过量能估算，盈亏不能一起隐藏")
        XCTAssertFalse(market.showsTodayProfit(at: active, quoteDate: "2026-06-30"))
        XCTAssertFalse(market.showsTodayProfit(
            at: date("2026-07-01T21:00:00Z"), quoteDate: "2026-07-01"
        ))
        XCTAssertFalse(StockMarket.hongKong.showsTodayProfit(
            at: date("2026-09-25T04:30:00Z"), quoteDate: "2026-09-25"
        ), "港股午休不显示当日盈亏")
    }

    func testStaleOverseasDailyVolumeIsNotUsedForProjection() {
        let bars = [
            StockDailyBar(date: "2011-06-02", volume: 100),
            StockDailyBar(date: "2026-09-25", volume: 200),
        ]
        XCTAssertNil(StockVolume.previousVolume(
            from: bars, sessionDate: "2026-09-25", maximumAgeDays: 10
        ))
        XCTAssertEqual(StockVolume.previousVolume(
            from: [StockDailyBar(date: "2026-09-24", volume: 300)],
            sessionDate: "2026-09-25", maximumAgeDays: 10
        ), 300)
    }

    func testTencentQuoteTimesUseEachMarketsActualTimeZone() {
        XCTAssertEqual(
            StockMarket.mainland.quoteTime(from: "20260925094500"),
            date("2026-09-25T01:45:00Z")
        )
        XCTAssertEqual(
            StockMarket.hongKong.quoteTime(from: "2026/09/25 14:03:21"),
            date("2026-09-25T06:03:21Z")
        )
        XCTAssertEqual(
            StockMarket.unitedStates.quoteTime(from: "2026-07-01 09:45:00"),
            date("2026-07-01T13:45:00Z")
        )
        XCTAssertEqual(
            StockMarket.unitedStates.quoteTime(from: "2026-01-05 09:45:00"),
            date("2026-01-05T14:45:00Z")
        )
        XCTAssertNil(StockMarket.unitedStates.quoteTime(from: "2026-07-01 25:45:00"))
        XCTAssertNil(StockMarket.hongKong.quoteTime(from: "yesterday"))
    }

    func testQuoteFreshnessSeparatesCurrentDelayedClosedAndPreviousDay() {
        let time = date("2026-07-01T14:01:00Z")
        let quote = StockQuote(
            code: "usAAPL", name: "苹果", price: "338.35", raise: 2.43, raisePercent: 0.0072,
            volume: 100, sessionDate: "2026-07-01", quotedAt: time
        )
        XCTAssertEqual(QuoteFreshness.evaluate(quote, at: time.addingTimeInterval(180)), .current)
        XCTAssertEqual(QuoteFreshness.evaluate(quote, at: time.addingTimeInterval(181)), .delayed)
        XCTAssertEqual(QuoteFreshness.evaluate(quote, at: date("2026-07-01T21:00:00Z")), .closed)
        XCTAssertEqual(QuoteFreshness.evaluate(quote, at: date("2026-07-02T14:05:00Z")), .previousSession)
        XCTAssertEqual(QuoteFreshness.evaluate(quote, at: time.addingTimeInterval(-61)), .unknownTime)

        let row = StockRow(quote: quote, volumeRatio: nil)
        XCTAssertEqual(row.displayName(at: time.addingTimeInterval(181)), "延迟 · 苹果 · US")
        XCTAssertTrue(row.quoteTooltip(at: time.addingTimeInterval(181)).contains(
            "报价时间：2026-07-01 10:01:00（纽约时间）"
        ))
        XCTAssertEqual(
            row.quoteTimeSummary(at: time.addingTimeInterval(181)),
            "usAAPL · 2026-07-01 10:01:00 纽约时间 · 延迟"
        )
    }

    func testMissingTimePriceAndHolidayAreNeverLabeledCurrent() {
        let active = date("2026-09-25T02:00:00Z")
        let noTime = StockQuote(
            code: "sh600036", name: "招商银行", price: "40.69", raise: 0.09, raisePercent: 0.0022,
            volume: 100, sessionDate: "2026-09-25"
        )
        XCTAssertEqual(QuoteFreshness.evaluate(noTime, at: active), .unknownTime)
        XCTAssertTrue(StockRow(quote: noTime, volumeRatio: nil)
            .quoteTimeSummary(at: active).contains("时间未知"))
        XCTAssertEqual(QuoteFreshness.evaluate(
            .placeholder(code: "sh600036", name: "招商银行"), at: active
        ), .unavailable)
        var holidayQuote = noTime
        holidayQuote.quotedAt = active
        XCTAssertEqual(QuoteFreshness.evaluate(
            holidayQuote, at: active, holidays: ["2026-09-25": "假日"]
        ), .closed)
    }
}
