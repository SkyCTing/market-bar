import XCTest
@testable import MarketBar

final class QuoteRefreshGateTests: XCTestCase {
    func testProviderSwitchRejectsOldResponseAndSchedulesNewRefresh() throws {
        var gate = QuoteRefreshGate()
        let old = try XCTUnwrap(gate.begin())
        XCTAssertNil(gate.begin(), "Only one batch can run at a time")
        gate.invalidate()
        XCTAssertFalse(gate.accepts(old))
        XCTAssertNil(gate.begin(), "Wait for outstanding child requests before restarting")
        XCTAssertTrue(gate.finish(old))
        let fresh = try XCTUnwrap(gate.begin())
        XCTAssertNotEqual(old, fresh)
        XCTAssertTrue(gate.accepts(fresh))
        XCTAssertFalse(gate.finish(old), "Late old completion cannot release the fresh slot")
        XCTAssertTrue(gate.accepts(fresh))
        XCTAssertFalse(gate.finish(fresh))
    }

    func testSwitchingAwayAndBackStillInvalidatesTheOldBatch() throws {
        var gate = QuoteRefreshGate()
        let token = try XCTUnwrap(gate.begin())
        gate.invalidate()
        gate.invalidate()
        XCTAssertFalse(gate.accepts(token))
        XCTAssertTrue(gate.finish(token))
    }

    func testResettingGoldHistoryPreservesStockSamples() {
        var history = PriceHistory()
        let start = Date()
        history.record(price: 1_000, for: "gold", at: start, window: 600)
        history.record(price: 40, for: "sh600036", at: start, window: 600)
        history.remove(key: "gold")
        let now = start.addingTimeInterval(60)
        history.record(price: 1_030, for: "gold", at: now, window: 600)
        XCTAssertNil(history.referencePrice(for: "gold", minutes: 1, at: now))
        XCTAssertEqual(history.referencePrice(for: "sh600036", minutes: 1, at: now), 40)
    }

    func testEveryStockAlertRequiresFreshRegularSessionQuote() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-01T14:01:00Z"))
        let quote = StockQuote(
            code: "usAAPL", name: "Apple", price: "100", raise: 1, raisePercent: 0.01,
            volume: 100, sessionDate: "2026-07-01", quotedAt: now
        )
        XCTAssertEqual(PriceAlertEvaluator.currentStockPrice(quote, at: now, holidays: [:]), 100)
        XCTAssertEqual(PriceAlertEvaluator.currentStockPrice(quote, at: now.addingTimeInterval(180), holidays: [:]), 100)
        let delays: [TimeInterval] = [181, 7 * 3_600, 24 * 3_600]
        for later in delays {
            XCTAssertNil(PriceAlertEvaluator.currentStockPrice(quote, at: now.addingTimeInterval(later), holidays: [:]))
        }
        var unknown = quote
        unknown.quotedAt = nil
        XCTAssertNil(PriceAlertEvaluator.currentStockPrice(unknown, at: now, holidays: [:]))
        let mainland = StockQuote(
            code: "sh600036", name: "Test", price: "100", raise: 1, raisePercent: 0.01,
            volume: 100, sessionDate: "2026-07-01", quotedAt: now.addingTimeInterval(-7 * 3_600)
        )
        XCTAssertNil(PriceAlertEvaluator.currentStockPrice(
            mainland, at: mainland.quotedAt!, holidays: ["2026-07-01": "休市"]
        ))
    }
}
