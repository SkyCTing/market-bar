import AppKit
import XCTest
@testable import MarketBar

@MainActor
final class StockKlineWindowTests: XCTestCase {
    private func sampleTrend(_ code: String, _ range: StockTrendRange) throws -> StockTrend {
        let market = try XCTUnwrap(StockMarket.forCode(code))
        let first = try XCTUnwrap(market.quoteTime(from: "20260925150000"))
        let last = try XCTUnwrap(market.quoteTime(from: "20260928150000"))
        let high: Double
        switch range {
        case .dailyCandles: high = 0.360
        case .weeklyCandles: high = 0.380
        case .monthlyCandles: high = 0.410
        default: throw StockTrendError.unsupported
        }
        let bars = [
            StockCandle(date: first, open: 0.342, high: high, low: 0.341, close: 0.345),
            StockCandle(date: last, open: 0.345, high: high - 0.002, low: 0.343, close: 0.349),
        ]
        return StockTrend(code: code, market: market, range: range,
                          points: bars.map { StockTrendPoint(date: $0.date, price: $0.close) }, candles: bars)
    }

    private func window(named name: String) throws -> NSWindow {
        try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.title == "\(name) · K 线" })
    }

    private func field(_ id: String, in window: NSWindow) throws -> NSTextField {
        try XCTUnwrap(window.contentView?.subviews.compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == id })
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<75 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("K-line window did not reach the expected state")
    }

    func testSeparateWindowSwitchesDailyWeeklyMonthlyAndShowsETFPrecision() async throws {
        _ = NSApplication.shared
        let calls = KlineRequests()
        let controller = StockKlineWindowController { [self] code, range, force in
            await calls.record(code: code, range: range, forced: force)
            return try sampleTrend(code, range)
        }
        defer { controller.close() }
        let name = "医疗ETF-\(UUID())"
        var quote = StockQuote(code: "sh512170", name: name, price: "0.349",
                               raise: 0, raisePercent: 0, volume: 0, sessionDate: "2026-09-28")
        try controller.show(quote: quote)
        let window = try window(named: name)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        let content = try XCTUnwrap(window.contentView)
        let chart = try XCTUnwrap(content.subviews.compactMap { $0 as? StockTrendPlot }.first)
        let price = try field("klineWindowPrice", in: window)
        let summary = try field("klineWindowSummary", in: window)
        let detail = try field("klineWindowDetail", in: window)
        let modes = try XCTUnwrap(content.subviews.compactMap { $0 as? NSSegmentedControl }.first)
        try await waitUntil { summary.stringValue.contains("最高 0.360 · 最低 0.341") }
        XCTAssertEqual(price.stringValue, "最近价格 0.349 CNY")
        XCTAssertEqual(chart.decimalPlaces, 3)
        content.layoutSubtreeIfNeeded()
        XCTAssertLessThan(chart.frame.maxY, price.frame.minY, "K-line chart sits below recent price")
        XCTAssertEqual(modes.segmentCount, 3)
        XCTAssertEqual(chart.trend?.candles.count, 2)

        chart.updateHover(at: NSPoint(x: 53, y: chart.bounds.midY))
        XCTAssertTrue(detail.stringValue.contains("开 0.342  高 0.360  低 0.341  收 0.345"))
        modes.selectedSegment = 1
        _ = NSApp.sendAction(try XCTUnwrap(modes.action), to: modes.target, from: modes)
        try await waitUntil { summary.stringValue.contains("周 K · 2 根 · 最高 0.380") }
        modes.selectedSegment = 2
        _ = NSApp.sendAction(try XCTUnwrap(modes.action), to: modes.target, from: modes)
        try await waitUntil { summary.stringValue.contains("月 K · 2 根 · 最高 0.410") }
        let requests = await calls.requests
        XCTAssertEqual(requests.map(\.range), [.dailyCandles, .weeklyCandles, .monthlyCandles])
        XCTAssertTrue(requests.allSatisfy { !$0.forced && $0.code == quote.code })

        quote = StockQuote(code: quote.code, name: name, price: "0.3490",
                           raise: 0, raisePercent: 0, volume: 0, sessionDate: "2026-09-28")
        controller.updateQuote(quote)
        XCTAssertEqual(price.stringValue, "最近价格 0.3490 CNY")
        XCTAssertEqual(chart.decimalPlaces, 4)
        XCTAssertTrue(summary.stringValue.contains("最高 0.4100 · 最低 0.3410"))
    }

    func testManualRefreshUsesForceAndStaleRequestsCannotReplaceNewStock() async throws {
        let calls = KlineRequests()
        let controller = StockKlineWindowController { [self] code, range, force in
            await calls.record(code: code, range: range, forced: force)
            if code == "sh512170" {
                try? await Task.sleep(for: .milliseconds(200))
            }
            return try sampleTrend(code, range)
        }
        defer { controller.close() }
        let old = StockQuote(code: "sh512170", name: "旧ETF", price: "0.349",
                             raise: 0, raisePercent: 0, volume: 0, sessionDate: "")
        let new = StockQuote(code: "hk00700", name: "新港股", price: "439.80",
                             raise: 0, raisePercent: 0, volume: 0, sessionDate: "")
        try controller.show(quote: old)
        try controller.show(quote: new)
        let window = try window(named: "新港股")
        let summary = try field("klineWindowSummary", in: window)
        try await waitUntil { summary.stringValue.contains("日 K · 2 根 · 最高 0.36") }
        try await Task.sleep(for: .milliseconds(260))
        XCTAssertEqual(controller.code, "hk00700")
        XCTAssertEqual(try field("klineWindowPrice", in: window).stringValue, "最近价格 439.80 HKD")

        let refresh = try XCTUnwrap(window.contentView?.subviews.compactMap { $0 as? NSButton }
            .first { $0.title == "刷新" })
        refresh.performClick(nil)
        for _ in 0..<75 {
            let requests = await calls.requests
            if requests.contains(where: { $0.code == "hk00700" && $0.forced }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let requests = await calls.requests
        XCTAssertTrue(requests.contains { $0.code == "hk00700" && $0.forced })
    }

    func testUnavailableMarketsReportErrorsInsteadOfOpeningEmptyKWindow() {
        let controller = StockKlineWindowController { _, _, _ in
            throw StockTrendError.unavailable("unexpected network request")
        }
        defer { controller.close() }
        for code in ["usAAPL", "bj830799"] {
            let quote = StockQuote(code: code, name: code, price: "100",
                                   raise: 0, raisePercent: 0, volume: 0, sessionDate: "")
            XCTAssertThrowsError(try controller.show(quote: quote))
        }
        XCTAssertFalse(controller.isVisible)
    }
}

private actor KlineRequests {
    private(set) var requests: [(code: String, range: StockTrendRange, forced: Bool)] = []
    func record(code: String, range: StockTrendRange, forced: Bool) {
        requests.append((code, range, forced))
    }
}
