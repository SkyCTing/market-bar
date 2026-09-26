import Foundation
import XCTest

@testable import MarketBar

final class StockHoldingsTests: XCTestCase {
    private func quote(
        code: String,
        price: String = "0.349",
        raise: Double = 0.001,
        name: String = "测试标的"
    ) -> StockQuote {
        StockQuote(
            code: code, name: name, price: price, raise: raise, raisePercent: raise,
            volume: 0, sessionDate: "2026-09-23"
        )
    }

    // MARK: - 千分位

    func testGroupedInsertsThousandSeparators() {
        XCTAssertEqual(HoldingFormat.grouped("1"), "1")
        XCTAssertEqual(HoldingFormat.grouped("999"), "999")
        XCTAssertEqual(HoldingFormat.grouped("1000"), "1,000")
        XCTAssertEqual(HoldingFormat.grouped("10000"), "10,000")
        XCTAssertEqual(HoldingFormat.grouped("1100000"), "1,100,000")
        XCTAssertEqual(HoldingFormat.grouped("12345678"), "12,345,678")
    }

    func testSharesTextGroupsThePosition() {
        XCTAssertEqual(HoldingFormat.sharesText(1_100_000), "1,100,000")
        XCTAssertEqual(HoldingFormat.sharesText(880_000), "880,000")
        XCTAssertEqual(HoldingFormat.sharesText(435), "435")
    }

    // MARK: - 金额格式

    func testProfitLossTextAlwaysSignsNonZero() {
        XCTAssertEqual(HoldingFormat.profitLossText(1_100), "+1,100")
        XCTAssertEqual(HoldingFormat.profitLossText(-6_160), "-6,160")
        XCTAssertEqual(HoldingFormat.profitLossText(0), "0")
    }

    /// -0.4 取整后是 -0.0，Int(-0.0) 是 0 —— 不能显示成 "-0"。
    func testProfitLossTextNeverProducesNegativeZero() {
        XCTAssertEqual(HoldingFormat.profitLossText(-0.4), "0")
        XCTAssertEqual(HoldingFormat.profitLossText(-0.0), "0")
        XCTAssertEqual(HoldingFormat.profitLossText(0.4), "0")
        XCTAssertFalse(HoldingFormat.profitLossText(-0.49).contains("-"))
    }

    func testProfitLossTextRoundsToWholeYuan() {
        XCTAssertEqual(HoldingFormat.profitLossText(6_160.4), "+6,160")
        XCTAssertEqual(HoldingFormat.profitLossText(-6_160.6), "-6,161")
        XCTAssertEqual(HoldingFormat.profitLossText(0.5), "+1")
    }

    /// 行情字段是直接 Double() 解析的，"nan"/"inf" 都能解析成功；
    /// 没有 guard 的话这里会直接 trap 掉整个测试进程。
    func testProfitLossTextSurvivesNonFiniteInput() {
        XCTAssertEqual(HoldingFormat.profitLossText(.nan), "0")
        XCTAssertEqual(HoldingFormat.profitLossText(.infinity), "0")
        XCTAssertEqual(HoldingFormat.profitLossText(-.infinity), "0")
        XCTAssertEqual(HoldingFormat.profitLossText(Double(Int.max)), "0")
        XCTAssertEqual(HoldingFormat.amount(Double(Int.max)), "—")
    }

    // MARK: - 持仓查找

    func testSharesLookupReturnsNilWithoutPosition() {
        XCTAssertEqual(StockHoldings.shares(for: "sh600036"), 1_500)
        XCTAssertNil(StockHoldings.shares(for: "sh000001"))   // 上证指数只看不持
        XCTAssertNil(StockHoldings.shares(for: "sh999999"))   // 表外代码
    }

    /// 持仓表与自选清单是两份独立的表，必须保持「持仓 ⊆ 自选」：
    /// 否则那只标的既不会有行、也拿不到行情，会静默不计入合计。
    func testEveryHoldingIsAlsoInTheWatchlist() {
        let watchlist = Set(WatchlistConfig.default.watchlist.map(\.code))
        let missing = Set(WatchlistConfig.default.holdings.keys).subtracting(watchlist)
        XCTAssertTrue(missing.isEmpty, "这些持仓不在自选清单里，会静默漏算：\(missing.sorted())")
    }

    // MARK: - 单只盈亏

    func testTodayProfitMultipliesRaiseByShares() {
        XCTAssertEqual(StockProfitLoss.todayProfit(quote(code: "sh512170", raise: 0.001), shares: 1_100_000) ?? 0, 1_100, accuracy: 1e-6)
        XCTAssertEqual(StockProfitLoss.todayProfit(quote(code: "sh513130", raise: -0.007), shares: 880_000) ?? 0, -6_160, accuracy: 1e-6)
    }

    func testTodayProfitIsNilWithoutSharesOrQuote() {
        XCTAssertNil(StockProfitLoss.todayProfit(quote(code: "sh512170"), shares: nil))
        XCTAssertNil(StockProfitLoss.todayProfit(quote(code: "sh512170"), shares: 0))
        XCTAssertNil(StockProfitLoss.todayProfit(quote(code: "sh512170"), shares: -100))
        // 占位行情（停牌 / 取数失败）不能当成 0 元盈亏
        XCTAssertNil(StockProfitLoss.todayProfit(quote(code: "sh512170", price: "--"), shares: 1_000))
        XCTAssertNil(StockProfitLoss.todayProfit(quote(code: "sh512170", raise: .nan), shares: 1_000))
    }

    // MARK: - 组合合计

    func testTotalSkipsUnusableEntries() {
        XCTAssertNil(StockProfitLoss.totalToday(quotesByCode: [:]))

        // 只有指数（无持仓）→ 没有可统计的，返回 nil 而不是 0
        let indexOnly = ["sh000001": quote(code: "sh000001", raise: -15.61, name: "上证指数")]
        XCTAssertNil(StockProfitLoss.totalToday(quotesByCode: indexOnly))
    }

    func testTotalIgnoresPlaceholderQuotesInsteadOfCountingThemAsZero() {
        let withPlaceholder = [
            "sh512170": quote(code: "sh512170", raise: 0.001),
            "sh513130": quote(code: "sh513130", price: "--", raise: 0),
        ]
        XCTAssertEqual(StockProfitLoss.totalToday(quotesByCode: withPlaceholder) ?? 0, 1_100, accuracy: 1e-6)
    }

    /// 真实收盘数据：合计 -8,055（恒生科技 -6,160 + 医疗 +1,100 + 其余个股）
    func testRealCloseTotalMatchesLiveData() {
        let quotes: [String: StockQuote] = [
            "sh600036": quote(code: "sh600036", raise: -0.22),
            "sz300803": quote(code: "sz300803", raise: 0.39),
            "sz000034": quote(code: "sz000034", raise: -0.36),
            "sz300339": quote(code: "sz300339", raise: -0.78),
            "sz002657": quote(code: "sz002657", raise: -0.53),
            "sz300468": quote(code: "sz300468", raise: -0.83),
            "sz300657": quote(code: "sz300657", raise: -0.76),
            "sz000564": quote(code: "sz000564", raise: -0.04),
            "sh603406": quote(code: "sh603406", raise: -0.08),
            "sz300375": quote(code: "sz300375", raise: -0.02),
            "sz301609": quote(code: "sz301609", raise: -1.01),
            "sh513130": quote(code: "sh513130", raise: -0.007),
            "sh512170": quote(code: "sh512170", raise: 0.001),
            "sz159813": quote(code: "sz159813", raise: -0.002),
            "sz159567": quote(code: "sz159567", raise: 0.003),
        ]

        let total = StockProfitLoss.totalToday(quotesByCode: quotes)
        XCTAssertEqual(total ?? 0, -8_055, accuracy: 1)
        XCTAssertEqual(HoldingFormat.profitLossText(total ?? 0), "-8,055")
    }

    // MARK: - 面板行

    func testRowWithoutPositionShowsBlankCells() {
        let row = StockRow(quote: quote(code: "sh000001", name: "上证指数"), volumeRatio: 0.92)

        XCTAssertNil(row.shares)
        XCTAssertNil(row.profitLoss)
        XCTAssertEqual(row.sharesText, "")
        XCTAssertEqual(row.profitLossText, "")
    }

    func testRowWithPositionFormatsSharesAndProfit() {
        let row = StockRow(quote: quote(code: "sh513130", raise: -0.007), volumeRatio: 0.63)

        XCTAssertEqual(row.shares, 880_000)
        XCTAssertEqual(row.sharesText, "880,000")
        XCTAssertEqual(row.profitLossText, "-6,160")
    }

    @MainActor
    func testOverseasPositionUsesNativeCurrencyWithoutMixingIntoYuanTotal() {
        let previous = StockHoldings.sharesByCode
        let previousCosts = StockHoldings.costsByCode
        defer {
            StockHoldings.sharesByCode = previous
            StockHoldings.costsByCode = previousCosts
        }
        StockHoldings.sharesByCode = ["sh600036": 100, "usAAPL": 10, "hk00700": 20]
        StockHoldings.costsByCode = ["usAAPL": 300]
        let a = quote(code: "sh600036", price: "40", raise: 1)
        let us = quote(code: "usAAPL", price: "338", raise: 2.43)
        let hk = quote(code: "hk00700", price: "436", raise: -1.8)

        XCTAssertEqual(StockRow(quote: us, volumeRatio: nil).profitLossText, "USD +24")
        XCTAssertEqual(StockRow(quote: hk, volumeRatio: nil).profitLossText, "HKD -36")
        XCTAssertEqual(StockRow(quote: us, volumeRatio: nil).displayName, "测试标的 · US")
        XCTAssertEqual(StockRow(quote: hk, volumeRatio: nil).displayName, "测试标的 · HK")
        XCTAssertTrue(StockRow(quote: us, volumeRatio: nil).floatingProfitText.hasPrefix("USD +380"))
        XCTAssertEqual(StockProfitLoss.totalToday(quotesByCode: [
            "sh600036": a, "usAAPL": us, "hk00700": hk,
        ]), 100)
    }
}

/// 配置文件（自选清单 + 持仓）
final class WatchlistConfigTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("watchlist-\(UUID().uuidString).json")
    }

    /// 文件不存在时按默认值生成一份，返回默认配置
    func testLoadCreatesFileFromDefaults() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let config = WatchlistConfig.load(from: url)

        XCTAssertEqual(config.watchlist.count, 16)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "应该顺手生成配置文件")
        XCTAssertEqual(config, WatchlistConfig.default)
    }

    /// 改过的配置能读回来
    func testRoundTrip() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let custom = WatchlistConfig(
            watchlist: [.init(code: "sh600519", name: "贵州茅台")],
            holdings: ["sh600519": 100]
        )
        custom.write(to: url)

        let loaded = WatchlistConfig.load(from: url)

        XCTAssertEqual(loaded.watchlist.map(\.code), ["sh600519"])
        XCTAssertEqual(loaded.holdings["sh600519"], 100)
    }

    /// 配置文件损坏时回退默认值，并把坏文件改名留证
    func testCorruptFileFallsBackToDefaults() throws {
        let url = tempURL()
        let brokenURL = url.deletingPathExtension().appendingPathExtension("broken.json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: brokenURL)
        }
        try Data("这不是 json".utf8).write(to: url)

        let config = WatchlistConfig.load(from: url)

        XCTAssertEqual(config, WatchlistConfig.default)
        XCTAssertTrue(FileManager.default.fileExists(atPath: brokenURL.path), "坏文件应该被改名保留")
    }

    /// ⚠️ 回归：原来坏文件改名成 broken.json，已经有同名副本时 moveItem 会失败被吞掉，
    /// 紧接着就被默认值覆盖 —— 用户这份配置一个字节都不剩
    func testCorruptFileIsBackedUpEvenWhenAnOlderBackupExists() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchlist-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("watchlist.json")
        let olderBackup = dir.appendingPathComponent("watchlist.broken.json")
        try Data("上一轮就坏了的配置".utf8).write(to: olderBackup)
        try Data("这一轮坏掉的配置".utf8).write(to: url)

        _ = WatchlistConfig.load(from: url)

        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains("broken") }
        XCTAssertGreaterThanOrEqual(backups.count, 2, "本次这份必须也留下副本，实际只有 \(backups)")

        let contents = try backups.compactMap { try? String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) }
        XCTAssertTrue(contents.contains("这一轮坏掉的配置"), "本次的内容没被保住：\(contents)")
        XCTAssertTrue(contents.contains("上一轮就坏了的配置"), "旧副本不该被覆盖")
    }

    /// 内置默认值里，持仓必须是自选的子集（否则那只既不显示也不计入合计）
    func testDefaultHoldingsAreSubsetOfDefaultWatchlist() {
        let watchlist = Set(WatchlistConfig.default.watchlist.map(\.code))
        let missing = Set(WatchlistConfig.default.holdings.keys).subtracting(watchlist)
        XCTAssertTrue(missing.isEmpty, "这些持仓不在自选清单里：\(missing.sorted())")
    }
}
