import Foundation
import XCTest

@testable import MarketBar

final class StockQuoteParsingTests: XCTestCase {
    /// 腾讯行情返回 GBK 文本，fixture 也按 GBK 生成，保证解析路径与线上一致。
    private static let gb18030 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    )

    private let etf = StockWatchlist.Entry(code: "sh512170", name: "医疗ETF华宝")
    private let index = StockWatchlist.Entry(code: "sh000001", name: "上证指数")

    /// 按线上字段位置造一条记录：3 最新价、6 成交量、30 时间、31 涨跌、32 涨跌幅%。
    private func record(
        code: String,
        bareCode: String,
        price: String,
        raiseValue: String,
        percent: String,
        volume: String = "0",
        timestamp: String = "20260923161437"
    ) -> String {
        var fields = [String](repeating: "0", count: 40)
        fields[1] = "某只标的"  // 名称字段含中文，用来验证 GBK 字节不会破坏后续解析
        fields[2] = bareCode
        fields[3] = price
        fields[4] = "0.348"
        fields[5] = "0.348"
        fields[6] = volume
        fields[30] = timestamp
        fields[31] = raiseValue
        fields[32] = percent
        return "v_\(code)=\"" + fields.joined(separator: "~") + "\";\n"
    }

    private func payload(_ records: String...) -> Data {
        records.joined().data(using: Self.gb18030)!
    }

    /// GBK 名称字节必须不影响数字字段，且涨跌幅按小数存储（面板会再 ×100）。
    func testParsesNumericFieldsFromGBKPayload() throws {
        let data = payload(record(code: "sh512170", bareCode: "512170", price: "0.349", raiseValue: "0.001", percent: "0.29"))

        let quotes = GoldPriceService.parseStockQuotes(data, watchlist: [etf])
        let quote = try XCTUnwrap(quotes["sh512170"])

        XCTAssertEqual(quote.price, "0.349")
        XCTAssertEqual(quote.raise, 0.001, accuracy: 1e-9)
        XCTAssertEqual(quote.raisePercent, 0.0029, accuracy: 1e-9)
        XCTAssertEqual(quote.name, "医疗ETF华宝")  // 名称取自清单，不是响应
    }

    /// 记录之间是 ";\n"，第二条起每段以换行开头，不能漏记录。
    func testParsesEveryRecordInLineSeparatedPayload() {
        let data = payload(
            record(code: "sh000001", bareCode: "000001", price: "3936.52", raiseValue: "-15.61", percent: "-0.39"),
            record(code: "sh512170", bareCode: "512170", price: "0.349", raiseValue: "0.001", percent: "0.29")
        )

        let quotes = GoldPriceService.parseStockQuotes(data, watchlist: [index, etf])

        XCTAssertEqual(quotes.count, 2)
        XCTAssertEqual(quotes["sh000001"]?.price, "3936.52")
        XCTAssertEqual(quotes["sh000001"]?.raisePercent ?? 0, -0.0039, accuracy: 1e-9)
        XCTAssertEqual(quotes["sh512170"]?.price, "0.349")
    }

    /// 空响应、无效代码（v_pv_none_match）、字段不足、代码错位都不应产出条目，也不应崩。
    func testMalformedPayloadsYieldNoEntry() {
        XCTAssertTrue(GoldPriceService.parseStockQuotes(Data(), watchlist: [etf]).isEmpty)

        let noneMatched = payload("v_pv_none_match=\"1\";\n")
        XCTAssertTrue(GoldPriceService.parseStockQuotes(noneMatched, watchlist: [etf]).isEmpty)

        let truncated = payload("v_sh512170=\"1~某只标的~512170~0.349\";\n")
        XCTAssertTrue(GoldPriceService.parseStockQuotes(truncated, watchlist: [etf]).isEmpty)

        let misaligned = payload(record(code: "sh512170", bareCode: "000001", price: "0.349", raiseValue: "0.001", percent: "0.29"))
        XCTAssertTrue(GoldPriceService.parseStockQuotes(misaligned, watchlist: [etf]).isEmpty)
    }

    /// 停牌 / 无成交时价格为 0.000，回落到 "--" 占位，颜色走中性灰。
    func testSuspendedInstrumentFallsBackToPlaceholder() throws {
        let data = payload(record(code: "sh512170", bareCode: "512170", price: "0.000", raiseValue: "0.000", percent: "0.00"))

        let quote = try XCTUnwrap(GoldPriceService.parseStockQuotes(data, watchlist: [etf])["sh512170"])

        XCTAssertEqual(quote.price, "--")
        XCTAssertEqual(quote.raise, 0)
        XCTAssertEqual(quote.raisePercent, 0)
    }

    /// 成交量与交易日必须在「价格为 0 就占位」之前解析：
    /// 否则停牌行的 sessionDate 为空，日线缓存的键永远是空的，日线永远不拉。
    func testSuspendedQuoteStillCarriesVolumeAndSessionDate() throws {
        let data = payload(record(
            code: "sh512170", bareCode: "512170", price: "0.000",
            raiseValue: "0.000", percent: "0.00", volume: "1234567"
        ))

        let quote = try XCTUnwrap(GoldPriceService.parseStockQuotes(data, watchlist: [etf])["sh512170"])

        XCTAssertEqual(quote.price, "--")
        XCTAssertEqual(quote.sessionDate, "2026-09-23")
        XCTAssertEqual(quote.volume, 1_234_567, accuracy: 1e-9)
        XCTAssertEqual(
            quote.quotedAt, ISO8601DateFormatter().date(from: "2026-09-23T08:14:37Z")
        )
    }

    /// 正常行的成交量与交易日
    func testParsesVolumeAndSessionDate() throws {
        let data = payload(record(
            code: "sh512170", bareCode: "512170", price: "0.349",
            raiseValue: "0.001", percent: "0.29", volume: "11704292"
        ))

        let quote = try XCTUnwrap(GoldPriceService.parseStockQuotes(data, watchlist: [etf])["sh512170"])

        XCTAssertEqual(quote.volume, 11_704_292, accuracy: 1e-9)
        XCTAssertEqual(quote.sessionDate, "2026-09-23")
    }

    func testParsesHongKongAndUnitedStatesQuotesWithoutMixingSymbols() throws {
        let hk = StockWatchlist.Entry(code: "hk00700", name: "腾讯控股")
        let us = StockWatchlist.Entry(code: "usBRK.B", name: "伯克希尔B")
        let data = payload(
            record(code: "hk00700", bareCode: "00700", price: "436.600", raiseValue: "-1.8",
                   percent: "-0.41", volume: "9113746", timestamp: "2026/09/25 16:08:20"),
            record(code: "usBRK.B", bareCode: "BRK.B.N", price: "504.34", raiseValue: "3.12",
                   percent: "0.62", volume: "990479", timestamp: "2026-09-25 11:49:40")
        )
        let quotes = GoldPriceService.parseStockQuotes(data, watchlist: [hk, us])

        XCTAssertEqual(quotes["hk00700"]?.sessionDate, "2026-09-25")
        XCTAssertEqual(quotes["hk00700"]?.price, "436.600")
        XCTAssertEqual(
            quotes["hk00700"]?.quotedAt,
            ISO8601DateFormatter().date(from: "2026-09-25T08:08:20Z")
        )
        XCTAssertEqual(quotes["usBRK.B"]?.sessionDate, "2026-09-25")
        XCTAssertEqual(quotes["usBRK.B"]?.raisePercent ?? 0, 0.0062, accuracy: 1e-9)
        XCTAssertEqual(quotes["usBRK.B"]?.volume, 990_479)
        XCTAssertEqual(
            quotes["usBRK.B"]?.quotedAt,
            ISO8601DateFormatter().date(from: "2026-09-25T15:49:40Z")
        )
        XCTAssertTrue(GoldPriceService.parseStockQuotes(
            payload(record(code: "usBRK.B", bareCode: "BRK.A.N", price: "504.34",
                           raiseValue: "3", percent: "0.6")),
            watchlist: [us]
        ).isEmpty)
    }

    func testLiveCrossMarketQuotesWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["MARKETBAR_LIVE_QUOTES"] == "1" else {
            throw XCTSkip("Set MARKETBAR_LIVE_QUOTES=1 to check the public quote endpoint")
        }
        let entries = [
            StockWatchlist.Entry(code: "sh600036", name: "招商银行"),
            StockWatchlist.Entry(code: "hk00700", name: "腾讯控股"),
            StockWatchlist.Entry(code: "usAAPL", name: "苹果"),
        ]
        let quotes = await GoldPriceService().fetchStockQuotes(
            codes: entries.map(\.code), fallback: entries
        )
        for entry in entries {
            let quote = try XCTUnwrap(quotes[entry.code], "接口未返回 \(entry.code)")
            XCTAssertNotNil(quote.numericPrice, "\(entry.code) 无有效价格")
            XCTAssertFalse(quote.sessionDate.isEmpty, "\(entry.code) 无有效交易日期")
            let time = try XCTUnwrap(quote.quotedAt, "\(entry.code) 无法解析报价时间")
            XCTAssertEqual(StockMarket.forCode(entry.code)?.dateString(for: time), quote.sessionDate)
        }
    }

    // MARK: - 日线解析（取昨日全天量用）

    private func klinePayload(code: String, key: String = "day", rows: [[Any]]) -> Data {
        let body: [String: Any] = ["data": [code: [key: rows]]]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private let klineRows: [[Any]] = [
        ["2026-09-21", "0.341", "0.348", "0.349", "0.340", "15431129.000"],
        ["2026-09-22", "0.348", "0.348", "0.352", "0.346", "14150416.000"],
        ["2026-09-23", "0.350", "0.349", "0.352", "0.347", "11704292.000"],
    ]

    /// 个别标的（sz301609 / sz300803）的日线末尾会多带一个对象元素，
    /// 用 [[String]] 解码会整段失败，导致那几只的昨日量永远是空的。
    func testParsesDailyBarsWithTrailingObjectElement() {
        let rows: [[Any]] = [
            ["2026-09-22", "32.000", "31.440", "32.100", "30.890", "23589.000", ["nd": "2026-09-22"]],
            ["2026-09-23", "32.100", "31.440", "32.200", "30.900", "20948.000"],
        ]

        let bars = GoldPriceService.parseDailyBars(klinePayload(code: "sz301609", rows: rows), code: "sz301609")

        XCTAssertEqual(bars.map(\.date), ["2026-09-22", "2026-09-23"])
        XCTAssertEqual(bars.last?.volume ?? 0, 20_948, accuracy: 1e-9)
        XCTAssertEqual(StockVolume.previousVolume(from: bars, sessionDate: "2026-09-23"), 23_589)
    }

    func testParsesDailyBarsFromKlineResponse() {
        let bars = GoldPriceService.parseDailyBars(klinePayload(code: "sh512170", rows: klineRows), code: "sh512170")

        XCTAssertEqual(bars.count, 3)
        XCTAssertEqual(bars.last?.date, "2026-09-23")
        XCTAssertEqual(bars.last?.volume ?? 0, 11_704_292, accuracy: 1e-9)
        XCTAssertEqual(StockVolume.previousVolume(from: bars, sessionDate: "2026-09-23"), 14_150_416)
    }

    /// fqkline 端点对部分代码只给 qfqday，所以统一走 kline/kline（只认 day 键）。
    func testDailyBarsIgnoreOtherKeysAndGarbage() {
        let qfqOnly = klinePayload(code: "sh512880", key: "qfqday", rows: klineRows)
        XCTAssertTrue(GoldPriceService.parseDailyBars(qfqOnly, code: "sh512880").isEmpty)

        XCTAssertTrue(GoldPriceService.parseDailyBars(Data(), code: "sh512170").isEmpty)
        XCTAssertTrue(GoldPriceService.parseDailyBars(Data("{}".utf8), code: "sh512170").isEmpty)
        XCTAssertTrue(GoldPriceService.parseDailyBars(Data("not json".utf8), code: "sh512170").isEmpty)

        // 字段缺列的行被跳过，不影响其它行
        let shortRow = klinePayload(code: "sh512170", rows: [["2026-09-22", "0.348"], klineRows[2]])
        XCTAssertEqual(GoldPriceService.parseDailyBars(shortRow, code: "sh512170").count, 1)
    }

    func testDailyBarsURLValidatesCode() {
        XCTAssertEqual(
            GoldPriceService.dailyBarsURL(code: "sh512170", days: 5)?.absoluteString,
            "https://web.ifzq.gtimg.cn/appstock/app/kline/kline?param=sh512170,day,,,5"
        )
        XCTAssertNil(GoldPriceService.dailyBarsURL(code: "512170"))
        XCTAssertNil(GoldPriceService.dailyBarsURL(code: "sh51217"))
        XCTAssertNil(GoldPriceService.dailyBarsURL(code: "sh512170&x=1"))
        XCTAssertNotNil(GoldPriceService.dailyBarsURL(code: "hk00700"))
        XCTAssertNotNil(GoldPriceService.dailyBarsURL(code: "usBRK.B"))
        XCTAssertNil(GoldPriceService.dailyBarsURL(code: "usAAPL&x=1"))
    }

    /// 清单里写死的 URL 必须带上全部代码，且用逗号拼接。
    func testWatchlistURLContainsEveryCodeAsSingleBatchRequest() {
        let url = StockWatchlist.url.absoluteString

        // 用运行时清单自洽地校验（清单可能来自你改过的配置文件，不该拿默认值去比）
        XCTAssertTrue(url.hasPrefix("https://qt.gtimg.cn/q="))
        for entry in StockWatchlist.entries {
            XCTAssertTrue(url.contains(entry.code), "缺少 \(entry.code)")
        }
        XCTAssertEqual(url.filter { $0 == "," }.count, max(0, StockWatchlist.entries.count - 1))

        // 内置默认值单独校验
        XCTAssertEqual(WatchlistConfig.default.watchlist.count, 16)
    }
}
