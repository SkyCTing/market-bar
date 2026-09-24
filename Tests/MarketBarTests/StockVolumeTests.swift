import Foundation
import XCTest

@testable import MarketBar

final class StockVolumeTests: XCTestCase {
    private let shanghai = TradingSession.calendar

    /// 用北京时间构造瞬时点，避免测试依赖运行机器的时区
    private func beijing(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        shanghai.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func assertProgress(
        _ hour: Int, _ minute: Int, _ expected: Double?,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        // 2026-09-23 是周三
        let value = TradingSession.progress(at: beijing(2026, 9, 23, hour, minute))
        if let expected {
            XCTAssertEqual(value ?? -1, expected, accuracy: 1e-9, "\(hour):\(minute)", file: file, line: line)
        } else {
            XCTAssertNil(value, "\(hour):\(minute)", file: file, line: line)
        }
    }

    // MARK: - 交易时段进度

    func testProgressReturnsNilBeforeOpenAndDuringOpeningGrace() {
        assertProgress(0, 1, nil)
        assertProgress(9, 15, nil)   // 集合竞价
        assertProgress(9, 29, nil)
        assertProgress(9, 30, nil)   // 刚开盘
        assertProgress(9, 44, nil)   // 宽限期内
    }

    func testProgressAdvancesThroughTheMorningSession() {
        assertProgress(9, 45, 15.0 / 240)
        assertProgress(10, 30, 0.25)
        assertProgress(11, 29, 119.0 / 240)
        assertProgress(11, 30, 0.5)
    }

    func testProgressPausesOverLunchBreak() {
        assertProgress(12, 0, 0.5)
        assertProgress(12, 59, 0.5)
        assertProgress(13, 0, 0.5)
        assertProgress(13, 1, 121.0 / 240)
    }

    func testProgressReachesOneAtClose() {
        assertProgress(14, 59, 239.0 / 240)
        assertProgress(15, 0, 1.0)
        assertProgress(23, 59, 1.0)
    }

    func testProgressIsNilOnWeekends() {
        // 2026-09-26 是周六，2026-09-27 是周日
        XCTAssertNil(TradingSession.progress(at: beijing(2026, 9, 26, 10, 30)))
        XCTAssertNil(TradingSession.progress(at: beijing(2026, 9, 27, 10, 30)))
    }

    /// 本机时区不能影响折算结果：这条测试挡住「改用 Calendar.current」的改动。
    func testProgressIgnoresMachineTimeZone() {
        let original = NSTimeZone.default
        addTeardownBlock { NSTimeZone.default = original }
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!

        XCTAssertEqual(TradingSession.progress(at: beijing(2026, 9, 23, 10, 30)) ?? -1, 0.25, accuracy: 1e-9)
        XCTAssertEqual(TradingSession.dateString(for: beijing(2026, 9, 23, 10, 30)), "2026-09-23")
    }

    // MARK: - 行情时间戳

    func testSessionDateParsesTencentTimestamp() {
        XCTAssertEqual(TradingSession.sessionDate(fromQuoteTimestamp: "20260923161437"), "2026-09-23")
        XCTAssertEqual(TradingSession.sessionDate(fromQuoteTimestamp: "20260923"), "2026-09-23")
        XCTAssertNil(TradingSession.sessionDate(fromQuoteTimestamp: ""))
        XCTAssertNil(TradingSession.sessionDate(fromQuoteTimestamp: "abc"))
        XCTAssertNil(TradingSession.sessionDate(fromQuoteTimestamp: "20261323"))  // 13 月
        XCTAssertNil(TradingSession.sessionDate(fromQuoteTimestamp: "20260900"))  // 0 日
    }

    // MARK: - 昨日全天量的选取

    private func bars(_ pairs: [(String, Double)]) -> [StockDailyBar] {
        pairs.map { StockDailyBar(date: $0.0, volume: $0.1) }
    }

    func testPreviousVolumeUsesTheLastBarBeforeTheSessionDate() {
        let history = bars([
            ("2026-09-21", 100), ("2026-09-22", 200), ("2026-09-23", 300),
        ])
        XCTAssertEqual(StockVolume.previousVolume(from: history, sessionDate: "2026-09-23"), 200)
    }

    /// 周六场景：日线最后一根是周五，会话日也是周五，昨日必须是周四而不是周五自己。
    func testPreviousVolumeOnSaturdaySessionDoesNotReuseTheSameBar() {
        let history = bars([
            ("2026-09-23", 100), ("2026-09-24", 200), ("2026-09-25", 300),
        ])
        XCTAssertEqual(StockVolume.previousVolume(from: history, sessionDate: "2026-09-25"), 200)
    }

    /// 今日那根还没生成时（早盘拉取），基准仍然是会话日的前一根。
    func testPreviousVolumeWorksWhenTodaysBarIsMissing() {
        let history = bars([("2026-09-24", 100), ("2026-09-25", 200)])
        XCTAssertEqual(StockVolume.previousVolume(from: history, sessionDate: "2026-09-28"), 200)
    }

    /// 长假后第一天：基准是节前最后一个交易日，不会落到节假日上。
    func testPreviousVolumeSkipsHolidays() {
        let history = bars([("2026-09-29", 100), ("2026-09-30", 200)])
        XCTAssertEqual(StockVolume.previousVolume(from: history, sessionDate: "2026-10-09"), 200)
    }

    func testPreviousVolumeIsNilWithoutHistory() {
        XCTAssertNil(StockVolume.previousVolume(from: [], sessionDate: "2026-09-23"))
        XCTAssertNil(StockVolume.previousVolume(from: bars([("2026-09-23", 100)]), sessionDate: "2026-09-23"))
    }

    // MARK: - 倍数

    func testRatioNeedsProgressVolumeAndBase() {
        XCTAssertNil(StockVolume.ratio(todayVolume: 100, previousVolume: 200, progress: nil))
        XCTAssertNil(StockVolume.ratio(todayVolume: 100, previousVolume: 200, progress: 0))
        XCTAssertNil(StockVolume.ratio(todayVolume: 0, previousVolume: 200, progress: 1))     // 停牌 / 无成交
        XCTAssertNil(StockVolume.ratio(todayVolume: 100, previousVolume: nil, progress: 1))
        XCTAssertNil(StockVolume.ratio(todayVolume: 100, previousVolume: 0, progress: 1))
    }

    func testRatioProjectsFullDayVolume() {
        XCTAssertEqual(StockVolume.ratio(todayVolume: 25, previousVolume: 200, progress: 0.25) ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(StockVolume.ratio(todayVolume: 100, previousVolume: 200, progress: 1) ?? -1, 0.5, accuracy: 1e-9)
    }

    // MARK: - 阈值与文案（fixture 取自 2026-09-23 收盘后的真实数据）

    func testRealCloseFixturesProduceExpectedTailText() {
        XCTAssertEqual(StockVolume.tailText(ratio: StockVolume.ratio(todayVolume: 466_913_933, previousVolume: 506_148_369, progress: 1)), " 0.92")
        XCTAssertEqual(StockVolume.tailText(ratio: StockVolume.ratio(todayVolume: 11_704_292, previousVolume: 14_150_416, progress: 1)), " 0.83")
        XCTAssertEqual(StockVolume.tailText(ratio: StockVolume.ratio(todayVolume: 1_850_206, previousVolume: 3_968_577, progress: 1)), " 0.47 缩量")
        XCTAssertEqual(StockVolume.tailText(ratio: StockVolume.ratio(todayVolume: 25_371_195, previousVolume: 40_000_652, progress: 1)), " 0.63 缩量")
        XCTAssertEqual(StockVolume.tailText(ratio: StockVolume.ratio(todayVolume: 14_189_328, previousVolume: 14_994_965, progress: 1)), " 0.95")
    }

    func testWordThresholds() {
        XCTAssertEqual(StockVolume.word(for: 1.2), .expansion)
        XCTAssertEqual(StockVolume.word(for: 1.19), .none)
        XCTAssertEqual(StockVolume.word(for: 0.8), .shrinkage)
        XCTAssertEqual(StockVolume.word(for: 0.81), .none)
        XCTAssertEqual(StockVolume.word(for: nil), .none)
    }

    /// 判定和显示必须用同一个四舍五入后的值，否则 0.796 会显示 0.80 却不标缩量。
    func testRoundingHappensBeforeClassification() {
        XCTAssertEqual(StockVolume.tailText(ratio: 0.796), " 0.80 缩量")
        XCTAssertEqual(StockVolume.tailText(ratio: 1.196), " 1.20 放量")
    }

    func testTailTextFormattingAndPlaceholder() {
        XCTAssertEqual(StockVolume.tailText(ratio: nil), " --")
        XCTAssertEqual(StockVolume.tailText(ratio: 12.34), " 12.3 放量")
        XCTAssertEqual(StockVolume.tailText(ratio: 1.0), " 1.00")
    }

    // MARK: - 名称列富文本

}

/// 量能拆成「倍数」和「标记」两列后的文本规则
final class StockVolumeColumnTests: XCTestCase {
    func testRatioTextKeepsTwoDecimalsBelowTen() {
        XCTAssertEqual(StockVolume.ratioText(1.954), "1.95")
        XCTAssertEqual(StockVolume.ratioText(0.827), "0.83")
        XCTAssertEqual(StockVolume.ratioText(12.34), "12.3")
        XCTAssertEqual(StockVolume.ratioText(nil), "--")
    }

    /// 倍数补齐到固定宽度，这样每行的标记都从同一列开始
    func testVolumeTextPadsRatioToFixedWidth() {
        XCTAssertEqual(StockVolume.volumeText(1.83), "1.83 放量")
        XCTAssertEqual(StockVolume.volumeText(0.63), "0.63 缩量")
        XCTAssertEqual(StockVolume.volumeText(1.10), "1.10")   // 中性区间不标词
        XCTAssertEqual(StockVolume.volumeText(12.34), "12.3 放量")
        XCTAssertEqual(StockVolume.volumeText(nil), "--  ")

        // 有标记的几行，标记都必须从第 6 个字符开始
        for ratio in [1.83, 0.63, 12.34] {
            let text = StockVolume.volumeText(ratio)
            let wordIndex = text.distance(from: text.startIndex, to: text.firstIndex { $0 == "放" || $0 == "缩" }!)
            XCTAssertEqual(wordIndex, 5, "\(text) 的标记应该从固定位置开始")
        }
    }

    func testWordTextOnlyForExpansionAndShrinkage() {
        XCTAssertEqual(StockVolume.wordText(for: 1.5), "放量")
        XCTAssertEqual(StockVolume.wordText(for: 0.5), "缩量")
        XCTAssertEqual(StockVolume.wordText(for: 1.0), "")
        XCTAssertEqual(StockVolume.wordText(for: nil), "")
    }
}
