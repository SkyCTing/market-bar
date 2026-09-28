import AppKit
import XCTest
@testable import MarketBar

@MainActor
final class GoldHoverSparklineTests: XCTestCase {
    private func makeData(provider: String = "浙商积存金") -> HoverPanelData {
        HoverPanelData(
            provider: provider, price: "899.23", changeAmount: "+1.20", changePercent: "+0.13%",
            isNegative: false, updateTime: "21:00:00", refreshInterval: "1 秒",
            alertInfo: "未设置", market: .empty,
            stocks: [StockRow(quote: .placeholder(code: "sh600036", name: "测试股票"), volumeRatio: nil)],
            summaries: [], holidays: [:]
        )
    }

    private func panelWindow(provider: String) throws -> NSPanel {
        try XCTUnwrap(NSApp.windows.compactMap { $0 as? NSPanel }.first {
            $0.isVisible && $0.contentView?.subviews.contains {
                ($0 as? NSTextField)?.stringValue == provider
            } == true
        })
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<50 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Hover chart did not update")
    }

    func testBankTrendAppearsBesideGoldPriceAndRangeSelectionKeepsStockRows() async throws {
        _ = NSApplication.shared
        let now = Date()
        let recent = GoldHistorySample(provider: .zheShang, sampledAt: now.addingTimeInterval(-70), price: 899.23)
        let earlier = GoldHistorySample(provider: .zheShang, sampledAt: now.addingTimeInterval(-2 * 86_400), price: 904.45)
        let old = GoldHistorySample(provider: .zheShang, sampledAt: now.addingTimeInterval(-10 * 86_400), price: 891.07)
        let panel = HoverPanel()
        panel.goldProvider = .zheShang
        panel.loadGoldTrend = { provider, start, end in
            let points = [old, earlier, recent].filter { start <= $0.sampledAt && $0.sampledAt <= end }
            return GoldTrend(provider: provider, start: start, end: end, samples: points)
        }
        let screen = try XCTUnwrap(NSScreen.main)
        panel.show(below: NSRect(x: screen.frame.midX, y: screen.frame.maxY - 30, width: 60, height: 24), data: makeData())
        defer { panel.dismiss() }
        let window = try panelWindow(provider: "浙商积存金")
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let labels = content.subviews.compactMap { $0 as? NSTextField }
        let price = try XCTUnwrap(labels.first { $0.stringValue == "¥ 899.23" })
        let stock = try XCTUnwrap(labels.first { $0.stringValue.contains("测试股票") })
        let spark = try XCTUnwrap(content.subviews.compactMap { $0 as? GoldHoverSparkline }.first)
        let summary = try XCTUnwrap(labels.first { $0.identifier?.rawValue == "goldTrendSummary" })
        let ranges = try XCTUnwrap(content.subviews.compactMap { $0 as? NSSegmentedControl }.first)
        try await waitUntil { spark.trend?.samples.count == 1 }
        XCTAssertTrue(summary.stringValue.contains("最高 ¥899.23 · 最低 ¥899.23"))
        XCTAssertTrue(summary.stringValue.contains("始 "))
        XCTAssertTrue(summary.toolTip?.contains("仅显示已采集时段") == true)
        XCTAssertEqual(spark.xCoordinate(for: recent), spark.bounds.midX, accuracy: 1)
        XCTAssertEqual(ranges.segmentCount, 4)
        XCTAssertGreaterThan(spark.frame.minX, price.frame.maxX)
        XCTAssertGreaterThan(spark.frame.minY, stock.frame.maxY)
        let panelHeight = window.frame.height

        ranges.selectedSegment = GoldTrendRange.week.rawValue
        _ = NSApp.sendAction(try XCTUnwrap(ranges.action), to: ranges.target, from: ranges)
        try await waitUntil { spark.trend?.samples.count == 2 }
        XCTAssertTrue(summary.stringValue.contains("最高 ¥904.45 · 最低 ¥899.23"))
        XCTAssertLessThan(spark.xCoordinate(for: earlier), spark.bounds.midX)
        XCTAssertGreaterThan(spark.xCoordinate(for: recent), spark.bounds.midX)
        panel.updateContent(data: makeData())
        XCTAssertEqual(window.frame.height, panelHeight, accuracy: 0.5)
        XCTAssertTrue(stock.stringValue.contains("测试股票"))

        ranges.selectedSegment = GoldTrendRange.month.rawValue
        _ = NSApp.sendAction(try XCTUnwrap(ranges.action), to: ranges.target, from: ranges)
        try await waitUntil { spark.trend?.samples.count == 3 }
        XCTAssertTrue(summary.stringValue.contains("最低 ¥891.07"))
    }

    func testPointerShowsAcquisitionTimeWithoutInventingMissingPoints() async throws {
        let now = Date()
        let point = GoldHistorySample(provider: .minSheng, sampledAt: now.addingTimeInterval(-80), price: 896.18)
        let panel = HoverPanel()
        panel.goldProvider = .minSheng
        panel.loadGoldTrend = { provider, start, end in
            GoldTrend(provider: provider, start: start, end: end, samples: [point])
        }
        let screen = try XCTUnwrap(NSScreen.main)
        panel.show(below: NSRect(x: screen.frame.midX, y: screen.frame.maxY - 30, width: 60, height: 24), data: makeData(provider: "民生积存金"))
        defer { panel.dismiss() }
        let window = try panelWindow(provider: "民生积存金")
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let spark = try XCTUnwrap(content.subviews.compactMap { $0 as? GoldHoverSparkline }.first)
        let labels = content.subviews.compactMap { $0 as? NSTextField }
        let summary = try XCTUnwrap(labels.first { $0.identifier?.rawValue == "goldTrendSummary" })
        try await waitUntil { spark.trend?.samples.count == 1 }
        let spot = content.convert(NSPoint(x: spark.xCoordinate(for: point), y: spark.bounds.midY), from: spark)
        let screenPoint = window.convertToScreen(NSRect(origin: content.convert(spot, to: nil), size: .zero)).origin
        panel.updateHoveredQuote(at: screenPoint)
        XCTAssertTrue(summary.stringValue.contains("¥896.18 / 克"))
        let gap = content.convert(NSPoint(x: 8, y: spark.bounds.midY), from: spark)
        panel.updateHoveredQuote(at: window.convertToScreen(NSRect(origin: content.convert(gap, to: nil), size: .zero)).origin)
        XCTAssertTrue(summary.stringValue.contains("最高 ¥896.18"))
    }

    func testMissingHistoryAndDatabaseErrorAreVisible() async throws {
        let panel = HoverPanel()
        panel.goldProvider = .zheShang
        panel.loadGoldTrend = { provider, start, end in
            GoldTrend(provider: provider, start: start, end: end, samples: [])
        }
        let screen = try XCTUnwrap(NSScreen.main)
        panel.show(below: NSRect(x: screen.frame.midX, y: screen.frame.maxY - 30, width: 60, height: 24), data: makeData(provider: "空记录测试"))
        defer { panel.dismiss() }
        let window = try panelWindow(provider: "空记录测试")
        let content = try XCTUnwrap(window.contentView)
        let labels = content.subviews.compactMap { $0 as? NSTextField }
        let summary = try XCTUnwrap(labels.first { $0.identifier?.rawValue == "goldTrendSummary" })
        try await waitUntil { summary.stringValue.contains("暂无采集记录") }
        panel.loadGoldTrend = { _, _, _ in throw GoldHistoryError.database("测试读取错误") }
        let ranges = try XCTUnwrap(content.subviews.compactMap { $0 as? NSSegmentedControl }.first)
        ranges.selectedSegment = GoldTrendRange.week.rawValue
        _ = NSApp.sendAction(try XCTUnwrap(ranges.action), to: ranges.target, from: ranges)
        try await waitUntil { summary.stringValue.contains("读取失败") }
        XCTAssertTrue(summary.toolTip?.contains("测试读取错误") == true)
    }

    func testOldAsyncRangeResultCannotReplaceNewSelection() async throws {
        let now = Date()
        let recent = GoldHistorySample(provider: .zheShang, sampledAt: now.addingTimeInterval(-60), price: 900)
        let old = GoldHistorySample(provider: .zheShang, sampledAt: now.addingTimeInterval(-2 * 86_400), price: 880)
        let panel = HoverPanel()
        panel.goldProvider = .zheShang
        panel.loadGoldTrend = { provider, start, end in
            if end.timeIntervalSince(start) < 2 * 86_400 {
                try? await Task.sleep(for: .milliseconds(160))
                return GoldTrend(provider: provider, start: start, end: end, samples: [recent])
            }
            return GoldTrend(provider: provider, start: start, end: end, samples: [old, recent])
        }
        let screen = try XCTUnwrap(NSScreen.main)
        panel.show(below: NSRect(x: screen.frame.midX, y: screen.frame.maxY - 30, width: 60, height: 24),
                   data: makeData(provider: "异步测试"))
        defer { panel.dismiss() }
        let content = try XCTUnwrap(panelWindow(provider: "异步测试").contentView)
        let spark = try XCTUnwrap(content.subviews.compactMap { $0 as? GoldHoverSparkline }.first)
        let ranges = try XCTUnwrap(content.subviews.compactMap { $0 as? NSSegmentedControl }.first)
        ranges.selectedSegment = GoldTrendRange.week.rawValue
        _ = NSApp.sendAction(try XCTUnwrap(ranges.action), to: ranges.target, from: ranges)
        try await waitUntil { spark.trend?.samples.count == 2 }
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(spark.trend?.samples, [old, recent])
        XCTAssertEqual(ranges.selectedSegment, GoldTrendRange.week.rawValue)
    }

    func testHeaderChartDoesNotGrowPanelWithFullWatchlist() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let data = HoverPanelData(
            provider: "全量清单测试", price: "899.23", changeAmount: "0", changePercent: "0%",
            isNegative: nil, updateTime: "22:00:00", refreshInterval: "1 秒",
            alertInfo: "未设置", market: .empty,
            stocks: StockWatchlist.entries.map {
                StockRow(quote: .placeholder(code: $0.code, name: $0.name), volumeRatio: nil)
            }, summaries: [], holidays: [:]
        )
        let panel = HoverPanel()
        panel.show(below: NSRect(x: screen.frame.midX, y: screen.frame.maxY - 30, width: 60, height: 24), data: data)
        defer { panel.dismiss() }
        let window = try panelWindow(provider: "全量清单测试")
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let labels = content.subviews.compactMap { $0 as? NSTextField }
        let price = try XCTUnwrap(labels.first { $0.stringValue == "¥ 899.23" })
        let stockSection = try XCTUnwrap(labels.first { $0.stringValue == "自选行情" })
        let spark = try XCTUnwrap(content.subviews.compactMap { $0 as? GoldHoverSparkline }.first)
        let range = try XCTUnwrap(content.subviews.compactMap { $0 as? NSSegmentedControl }.first)
        XCTAssertGreaterThan(spark.frame.minX, price.frame.maxX)
        XCTAssertGreaterThan(spark.frame.minY, stockSection.frame.maxY)
        XCTAssertGreaterThanOrEqual(window.frame.height, content.fittingSize.height - 1)
        XCTAssertEqual(range.segmentCount, 4)
        XCTAssertEqual(labels.filter { $0.stringValue == "报价时间" }.count, 1)
    }
}
