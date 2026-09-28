import XCTest
@testable import MarketBar

final class StockTrendTests: XCTestCase {
    private func payload(code: String, node: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["code": 0, "data": [code: node]])
    }

    func testIntradayUsesMarketLocalTimestampAndOnlyRegularSession() throws {
        for (code, market, rows) in [
            ("sh600036", StockMarket.mainland, ["0929 10.0 1", "1129 40.67 5", "1130 41.5 6", "1300 40.85 8", "1500 41.0 9"]),
            ("hk00700", StockMarket.hongKong, ["1159 441.4 8", "1200 446 4", "1300 444.6 7", "1608 439.8 2"]),
        ] {
            let data = try payload(code: code, node: ["data": ["date": "20260928", "data": rows]])
            let trend = try StockTrendService.parse(data, code: code, market: market, range: .today)
            XCTAssertEqual(trend.points.count, 2)
            XCTAssertEqual(market.dateString(for: trend.points[0].date), "2026-09-28")
            XCTAssertEqual(trend.high?.price, code == "sh600036" ? 40.85 : 444.6)
            XCTAssertEqual(trend.segments.count, 1, "Adjacent trading minutes should connect over lunch")
            let minutes = market.regularSessionMinuteCount
            XCTAssertEqual(trend.plotFractions[1] - trend.plotFractions[0],
                           1 / Double(minutes - 1), accuracy: 1e-9)
        }
    }

    func testFiveDaysSortsSessionsAndNeverConnectsOvernight() throws {
        let data = try payload(code: "hk00700", node: [
            "data": [
                ["date": "20260928", "data": ["0930 443 10", "0931 444 12"]],
                ["date": "20260925", "data": ["1558 437 10", "1559 438 12"]],
            ],
        ])
        let trend = try StockTrendService.parse(data, code: "hk00700", market: .hongKong, range: .fiveDays)
        XCTAssertEqual(trend.points.map(\.price), [437, 438, 443, 444])
        XCTAssertEqual(trend.segments.map(\.count), [4])
        XCTAssertEqual(trend.plotFractions[2] - trend.plotFractions[1],
                       1 / Double(2 * StockMarket.hongKong.regularSessionMinuteCount - 1), accuracy: 1e-9,
                       "Weekends and overnight should be compressed, not drawn as long holes")
        XCTAssertEqual(trend.low?.price, 437)
        XCTAssertEqual(trend.high?.price, 444)
    }

    func testMonthUsesUnadjustedDailyCloseNotHighOrLow() throws {
        let data = try payload(code: "sh600036", node: [
            "day": [
                ["2026-09-25", "40.00", "40.60", "42.90", "39.10", "1000", ["note": "extra"]],
                ["2026-09-28", "40.67", "41.20", "43.00", "40.10", "1000"],
            ],
        ])
        let trend = try StockTrendService.parse(data, code: "sh600036", market: .mainland, range: .month)
        XCTAssertEqual(trend.points.map(\.price), [40.60, 41.20])
        XCTAssertTrue(trend.range.isDailyClose)
        XCTAssertEqual(trend.segments.count, 1, "Adjacent trading-day closes may be joined over a weekend")
    }

    func testMonthClosesConnectAcrossNonTradingDays() throws {
        let month = try payload(code: "hk00700", node: ["day": [
            ["2026-09-25", "440", "441", "445", "439", "10"],
            ["2026-10-06", "445", "448", "450", "440", "20"],
        ]])
        let trend = try StockTrendService.parse(month, code: "hk00700", market: .hongKong, range: .month)
        XCTAssertEqual(trend.segments.map(\.count), [2])
        XCTAssertEqual(trend.plotFractions, [0, 1])
        XCTAssertEqual(trend.latest?.price, 448)
    }

    func testMissingTradingMinuteStillMakesAnHonestGap() throws {
        let data = try payload(code: "sh600036", node: [
            "data": ["date": "20260928", "data": [
                "0930 40.1 5", "0931 40.2 7", "0934 40.4 8", "0935 40.5 9",
            ]],
        ])
        let trend = try StockTrendService.parse(data, code: "sh600036", market: .mainland, range: .today)
        XCTAssertEqual(trend.segments.map(\.count), [2, 2])
        XCTAssertEqual(trend.plotFractions[2] - trend.plotFractions[1],
                       3 / 239.0, accuracy: 1e-9)
    }

    func testMalformedDatesPricesAndMissingSeriesAreNotDrawn() throws {
        let data = try payload(code: "sh600036", node: [
            "data": ["date": "20260928", "data": ["0930 0", "0931 NaN", "0932 -1", "0933 bad", "2560 10"]],
        ])
        XCTAssertThrowsError(try StockTrendService.parse(data, code: "sh600036", market: .mainland, range: .today))
        XCTAssertThrowsError(try StockTrendService.parse(Data("{}".utf8), code: "sh600036", market: .mainland, range: .today))
        let wrongCode = try payload(code: "sh600036", node: ["data": ["date": "20260928", "data": ["0930 40.6"]]])
        XCTAssertThrowsError(try StockTrendService.parse(wrongCode, code: "hk00700", market: .hongKong, range: .today))
    }

    func testUSAndInvalidCodesAreRejectedBeforeTransport() async throws {
        let calls = TrendRequestCount()
        let service = StockTrendService(transport: { request in
            await calls.record(request.url!)
            throw StockTrendError.unavailable("unexpected request")
        })
        for code in ["usAAPL", "usBRK.B", "sh600036&x=1", "hk123"] {
            do {
                _ = try await service.fetch(code: code, range: .today)
                XCTFail("Invalid/unsupported code \(code)")
            } catch StockTrendError.unsupported {}
        }
        do {
            _ = try await service.fetch(code: "bj830799", range: .today)
            XCTFail("Beijing exchange placeholder should not become a trend")
        } catch StockTrendError.unsupportedBeijing {}
        let count = await calls.count
        XCTAssertEqual(count, 0)
    }

    func testRequestURLsAndCacheOnlySuccessfulResponses() async throws {
        let calls = TrendRequestCount()
        let response = try payload(code: "sh600036", node: ["data": ["date": "20260928", "data": ["0930 40.6"]]])
        let service = StockTrendService(transport: { request in
            await calls.record(request.url!)
            return (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-28T01:30:00Z"))
        let first = try await service.fetch(code: "sh600036", range: .today, at: start)
        let again = try await service.fetch(code: "sh600036", range: .today, at: start.addingTimeInterval(30))
        XCTAssertEqual(first.points, again.points)
        let count = await calls.count
        XCTAssertEqual(count, 1)
        _ = try await service.fetch(code: "sh600036", range: .today, at: start.addingTimeInterval(61))
        let urls = await calls.urls
        XCTAssertEqual(urls.count, 2)
        XCTAssertTrue(urls.allSatisfy { $0.absoluteString.hasSuffix("minute/query?code=sh600036") })
    }

    func testAllThreeRangesUseDistinctValidURLsAndHttpErrorsStayVisible() async throws {
        let calls = TrendRequestCount()
        let minute = try payload(code: "hk00700", node: ["data": ["date": "20260928", "data": ["0930 441.4 8"]]])
        let five = try payload(code: "hk00700", node: ["data": [["date": "20260928", "data": ["0930 441.4 8"]]]])
        let month = try payload(code: "hk00700", node: ["day": [["2026-09-28", "440", "441.4", "445", "439", "8"]]])
        let service = StockTrendService(transport: { request in
            let url = request.url!
            await calls.record(url)
            let data: Data
            if url.path.hasSuffix("minute/query") { data = minute }
            else if url.path.hasSuffix("day/query") { data = five }
            else { data = month }
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        for range in StockTrendRange.allCases {
            let trend = try await service.fetch(code: "hk00700", range: range)
            XCTAssertEqual(trend.points.count, 1)
        }
        let urls = await calls.urls.map(\.absoluteString)
        XCTAssertEqual(urls.count, 3)
        XCTAssertTrue(urls[0].contains("minute/query?code=hk00700"))
        XCTAssertTrue(urls[1].contains("day/query?code=hk00700"))
        XCTAssertTrue(urls[2].contains("kline/kline?param=hk00700,day,,,31"))
        let bad = StockTrendService(transport: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        })
        do {
            _ = try await bad.fetch(code: "hk00700", range: .today)
            XCTFail("Should show a failed request rather than silently draw a blank chart")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("503"))
        }
    }

    func testLiveAAndHKTrendsWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["MARKETBAR_LIVE_QUOTES"] == "1" else {
            throw XCTSkip("Set MARKETBAR_LIVE_QUOTES=1 to test public trend endpoints")
        }
        let service = StockTrendService()
        for (code, market) in [("sh600036", StockMarket.mainland), ("hk00700", StockMarket.hongKong)] {
            for range in StockTrendRange.allCases {
                let trend = try await service.fetch(code: code, range: range)
                XCTAssertEqual(trend.market, market)
                XCTAssertGreaterThan(trend.points.count, 1, "\(code) \(range.title) returned too few valid points")
                XCTAssertTrue(trend.points.allSatisfy { $0.price > 0 && $0.price.isFinite })
                XCTAssertEqual(trend.segments.count, 1,
                               "\(code) \(range.title) should connect adjacent trading observations")
                XCTAssertEqual(trend.plotFractions.count, trend.points.count)
            }
        }
    }
}

private actor TrendRequestCount {
    private(set) var urls: [URL] = []
    var count: Int { urls.count }
    func record(_ url: URL) { urls.append(url) }
}
