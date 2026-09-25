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
}
