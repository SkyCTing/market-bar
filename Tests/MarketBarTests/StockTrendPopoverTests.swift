import AppKit
import XCTest
@testable import MarketBar

@MainActor
final class StockTrendPopoverTests: XCTestCase {
    private func data(_ suffix: String) -> HoverPanelData {
        func row(_ code: String, _ name: String) -> StockRow {
            let price: String
            switch code {
            case "sh600036": price = "40.64"
            case "hk00700": price = "439.80"
            default: price = "339.46"
            }
            return StockRow(quote: StockQuote(
                code: code, name: name + suffix, price: price,
                raise: 0, raisePercent: 0, volume: 0, sessionDate: ""
            ), volumeRatio: nil)
        }
        return HoverPanelData(
            provider: "测试\(suffix)", price: "900", changeAmount: "0", changePercent: "0",
            isNegative: nil, updateTime: "09:00", refreshInterval: "1 秒",
            alertInfo: "未设置", market: .empty,
            stocks: [row("sh600036", "A股"), row("hk00700", "港股"), row("usAAPL", "美股")],
            summaries: [], holidays: [:]
        )
    }

    private func parent(_ suffix: String) throws -> NSPanel {
        try XCTUnwrap(NSApp.windows.compactMap { $0 as? NSPanel }.first {
            $0.isVisible && $0.contentView?.subviews.contains {
                ($0 as? NSTextField)?.stringValue == "测试\(suffix)"
            } == true
        })
    }

    private func popup(title: String) -> NSPanel? {
        NSApp.windows.compactMap { $0 as? NSPanel }.first {
            $0.isVisible && $0.contentView?.subviews.contains {
                ($0 as? NSTextField)?.identifier?.rawValue == "stockTrendTitle"
                    && ($0 as? NSTextField)?.stringValue.contains(title) == true
            } == true
        }
    }

    private func label(_ id: String, in window: NSWindow) throws -> NSTextField {
        try XCTUnwrap(window.contentView?.subviews.compactMap { $0 as? NSTextField }.first {
            $0.identifier?.rawValue == id
        })
    }

    private func hover(_ title: String, in window: NSPanel, panel: HoverPanel) throws {
        let content = try XCTUnwrap(window.contentView)
        let text = try XCTUnwrap(content.subviews.compactMap { $0 as? NSTextField }.first {
            $0.stringValue.contains(title)
        })
        let point = window.convertToScreen(NSRect(
            origin: content.convert(NSPoint(x: text.frame.midX, y: text.frame.midY), to: nil),
            size: .zero
        )).origin
        panel.updateHoveredQuote(at: point)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<75 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Stock trend did not reach expected state")
    }

    func testStockHoverLoadsSeparateAandHKAndUSDoesNotRequestTrend() async throws {
        _ = NSApplication.shared
        let suffix = UUID().uuidString
        let calls = StockTrendRequests()
        let panel = HoverPanel()
        var openedQuote: StockQuote?
        panel.onOpenStockKline = { openedQuote = $0 }
        panel.loadStockTrend = { code, range in
            await calls.record(code, range)
            let market = try XCTUnwrap(StockMarket.forCode(code))
            let date = try XCTUnwrap(market.quoteTime(from: "20260928093000"))
            if range.isCandlestick {
                let earlier = try XCTUnwrap(market.quoteTime(from: "20260925093000"))
                let candles = [
                    StockCandle(date: earlier, open: 40, high: 43, low: 39, close: 40.5),
                    StockCandle(date: date, open: 41.5, high: 42, low: 38, close: 41),
                ]
                return StockTrend(code: code, market: market, range: range,
                                  points: candles.map { StockTrendPoint(date: $0.date, price: $0.close) },
                                  candles: candles)
            }
            return StockTrend(code: code, market: market, range: range, points: [
                StockTrendPoint(date: date, price: code == "hk00700" ? 440 : 40),
                StockTrendPoint(date: date.addingTimeInterval(60), price: code == "hk00700" ? 443 : 41),
            ])
        }
        let screen = try XCTUnwrap(NSScreen.main)
        panel.show(below: NSRect(x: screen.frame.midX, y: screen.frame.maxY - 30, width: 60, height: 24), data: data(suffix))
        defer { panel.dismiss() }
        let window = try parent(suffix)
        try hover("A股\(suffix)", in: window, panel: panel)
        try await waitUntil {
            guard let popup = self.popup(title: "A股\(suffix)") else { return false }
            return (try? self.label("stockTrendSummary", in: popup).stringValue.contains("最高价格 41.00")) == true
                && (try? self.label("stockKlineSummary", in: popup).stringValue.contains("最高 43.00 · 最低 38.00")) == true
        }
        let firstPopup = try XCTUnwrap(popup(title: "A股\(suffix)"))
        let latestPrice = try label("stockTrendLatestPrice", in: firstPopup)
        XCTAssertEqual(latestPrice.stringValue, "最近价格 40.64 CNY")
        let title = try label("stockTrendTitle", in: firstPopup)
        let summary = try label("stockTrendSummary", in: firstPopup)
        let chart = try XCTUnwrap(firstPopup.contentView?.subviews.compactMap { $0 as? StockTrendPlot }
            .first { $0.identifier?.rawValue == "stockLinePlot" })
        let kChart = try XCTUnwrap(firstPopup.contentView?.subviews.compactMap { $0 as? StockTrendPlot }
            .first { $0.identifier?.rawValue == "stockKPlot" })
        let kSummary = try label("stockKlineSummary", in: firstPopup)
        firstPopup.contentView?.layoutSubtreeIfNeeded()
        XCTAssertLessThan(latestPrice.frame.maxY, title.frame.minY)
        XCTAssertLessThan(chart.frame.maxY, latestPrice.frame.minY)
        XCTAssertLessThan(summary.frame.maxY, chart.frame.minY)
        XCTAssertLessThan(kChart.frame.maxY, summary.frame.minY)
        XCTAssertLessThan(kSummary.frame.maxY, kChart.frame.minY)
        XCTAssertEqual(kChart.trend?.range, .dailyCandles)
        XCTAssertEqual(kChart.trend?.candles.count, 2)
        XCTAssertEqual(firstPopup.frame.width, 360, accuracy: 0.5)
        XCTAssertFalse(firstPopup.frame.intersects(window.frame),
                       "Popup must not cover another stock name in the parent panel")
        let firstContent = try XCTUnwrap(window.contentView)
        let aRow = try XCTUnwrap(firstContent.subviews.compactMap { $0 as? NSTextField }.first {
            $0.stringValue.contains("A股\(suffix)")
        })
        let row = window.convertToScreen(firstContent.convert(aRow.frame, to: nil))
        let bridge = NSPoint(x: (row.minX + firstPopup.frame.maxX) / 2,
                             y: (row.midY + firstPopup.frame.midY) / 2)
        XCTAssertTrue(HoverPanelInteraction.crossesToPopover(bridge, from: row, to: firstPopup.frame))
        panel.updateHoveredQuote(at: bridge)
        XCTAssertNotNil(popup(title: "A股\(suffix)"), "Moving toward the popover must not dismiss it")
        let popupMid = NSPoint(x: firstPopup.frame.midX, y: firstPopup.frame.midY)
        XCTAssertTrue(panel.containsInteraction(popupMid, button: .zero))
        panel.updateHoveredQuote(at: popupMid)
        XCTAssertNotNil(popup(title: "A股\(suffix)"))
        let control = try XCTUnwrap(firstPopup.contentView?.subviews.compactMap { $0 as? NSSegmentedControl }
            .first { $0.identifier?.rawValue == "stockLineRange" })
        let kControl = try XCTUnwrap(firstPopup.contentView?.subviews.compactMap { $0 as? NSSegmentedControl }
            .first { $0.identifier?.rawValue == "stockKRange" })
        XCTAssertEqual(control.segmentCount, 3)
        XCTAssertEqual(kControl.segmentCount, 3)
        control.selectedSegment = StockTrendRange.month.rawValue
        _ = NSApp.sendAction(try XCTUnwrap(control.action), to: control.target, from: control)
        try await waitUntil {
            (try? self.label("stockTrendSummary", in: firstPopup).stringValue.contains("最高日线 41.00")) == true
        }
        XCTAssertEqual(kSummary.stringValue, "最高 43.00 · 最低 38.00 CNY")
        kControl.selectedSegment = 1
        _ = NSApp.sendAction(try XCTUnwrap(kControl.action), to: kControl.target, from: kControl)
        try await waitUntil { kChart.trend?.range == .weeklyCandles }
        XCTAssertTrue(summary.stringValue.contains("最高日线 41.00"),
                      "Switching K timeframe must not reset the line chart")
        let klineButton = try XCTUnwrap(firstPopup.contentView?.subviews.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "openStockKline" })
        klineButton.performClick(nil)
        XCTAssertEqual(openedQuote?.code, "sh600036")
        XCTAssertEqual(openedQuote?.price, "40.64")

        try hover("港股\(suffix)", in: window, panel: panel)
        try await waitUntil {
            guard let popup = self.popup(title: "港股\(suffix)") else { return false }
            return (try? self.label("stockTrendSummary", in: popup).stringValue.contains("最高价格 443.00")) == true
                && (try? self.label("stockKlineSummary", in: popup).stringValue.contains("最高 43.00")) == true
        }
        try hover("美股\(suffix)", in: window, panel: panel)
        XCTAssertNil(popup(title: "美股\(suffix)"))
        XCTAssertNil(popup(title: "港股\(suffix)"))
        let requests = await calls.requests
        XCTAssertEqual(Set(requests.filter { $0.code == "sh600036" }.map(\.range)),
                       Set([.today, .month, .dailyCandles, .weeklyCandles]))
        XCTAssertEqual(Set(requests.filter { $0.code == "hk00700" }.map(\.range)),
                       Set([.today, .dailyCandles]))
        XCTAssertFalse(requests.contains { $0.code.hasPrefix("us") })
    }

    func testSweepingPastStockCancelsDebounceBeforeNetworking() async throws {
        let suffix = UUID().uuidString
        let calls = StockTrendRequests()
        let panel = HoverPanel()
        panel.loadStockTrend = { code, range in
            await calls.record(code, range)
            throw StockTrendError.unavailable("unexpected")
        }
        let screen = try XCTUnwrap(NSScreen.main)
        panel.show(below: NSRect(x: screen.frame.midX, y: screen.frame.maxY - 30, width: 60, height: 24), data: data(suffix))
        defer { panel.dismiss() }
        let window = try parent(suffix)
        try hover("A股\(suffix)", in: window, panel: panel)
        try hover("美股\(suffix)", in: window, panel: panel)
        try await Task.sleep(for: .milliseconds(260))
        let requests = await calls.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testKFailureDoesNotEraseLineAndReportsReason() async throws {
        let suffix = UUID().uuidString
        let panel = HoverPanel()
        panel.loadStockTrend = { code, range in
            if range.isCandlestick { throw StockTrendError.unavailable("K 接口测试失败") }
            let market = try XCTUnwrap(StockMarket.forCode(code))
            let date = try XCTUnwrap(market.quoteTime(from: "20260928093000"))
            return StockTrend(code: code, market: market, range: range,
                              points: [StockTrendPoint(date: date, price: 40.64)])
        }
        let screen = try XCTUnwrap(NSScreen.main)
        panel.show(below: NSRect(x: screen.frame.midX, y: screen.frame.maxY - 30, width: 60, height: 24), data: data(suffix))
        defer { panel.dismiss() }
        let parent = try parent(suffix)
        try hover("A股\(suffix)", in: parent, panel: panel)
        let popover = try XCTUnwrap(popup(title: "A股\(suffix)"))
        let line = try label("stockTrendSummary", in: popover)
        let kline = try label("stockKlineSummary", in: popover)
        try await waitUntil { line.stringValue.contains("最高价格 40.64") && kline.stringValue.contains("暂不可用") }
        XCTAssertTrue(kline.toolTip?.contains("K 接口测试失败") == true)
        XCTAssertFalse(line.stringValue.contains("暂不可用"))
    }

    func testStockHoverButtonOpensSeparateKlineWindowForTheSelectedTicker() async throws {
        let suffix = UUID().uuidString
        let panel = HoverPanel()
        let market = StockMarket.mainland
        let controller = StockKlineWindowController { code, range, _ in
            let date = try XCTUnwrap(market.quoteTime(from: "20260928150000"))
            let bar = StockCandle(date: date, open: 40.10, high: 41.08, low: 39.90, close: 40.64)
            return StockTrend(code: code, market: market, range: range,
                              points: [StockTrendPoint(date: date, price: bar.close)], candles: [bar])
        }
        panel.onOpenStockKline = { quote in
            panel.dismiss()
            do { try controller.show(quote: quote) }
            catch { XCTFail("Cannot open K-line window: \(error)") }
        }
        let screen = try XCTUnwrap(NSScreen.main)
        panel.show(below: NSRect(x: screen.frame.midX, y: screen.frame.maxY - 30, width: 60, height: 24), data: data(suffix))
        defer {
            panel.dismiss()
            controller.close()
        }
        let parent = try parent(suffix)
        try hover("A股\(suffix)", in: parent, panel: panel)
        let popover = try XCTUnwrap(popup(title: "A股\(suffix)"))
        let button = try XCTUnwrap(popover.contentView?.subviews.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "openStockKline" })
        button.performClick(nil)
        let kline = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.title == "A股\(suffix) · K 线" })
        let summary = try label("klineWindowSummary", in: kline)
        try await waitUntil { summary.stringValue.contains("日 K · 1 根") }
        XCTAssertEqual(controller.code, "sh600036")
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(controller.isVisible, true)
    }

    func testPopupBridgeIsOnlyActiveBetweenVisibleWindows() {
        let parent = NSRect(x: 100, y: 100, width: 780, height: 500)
        let popup = NSRect(x: 885, y: 300, width: 360, height: 215)
        XCTAssertTrue(HoverPanelInteraction.containsPopover(NSPoint(x: 882, y: 380), panel: parent, popup: popup))
        XCTAssertTrue(HoverPanelInteraction.containsPopover(NSPoint(x: 900, y: 380), panel: parent, popup: popup))
        XCTAssertFalse(HoverPanelInteraction.containsPopover(NSPoint(x: 882, y: 150), panel: parent, popup: popup))
        XCTAssertFalse(HoverPanelInteraction.containsPopover(NSPoint(x: 900, y: 200), panel: parent, popup: popup))
        let row = NSRect(x: 115, y: 370, width: 125, height: 17)
        XCTAssertTrue(HoverPanelInteraction.crossesToPopover(NSPoint(x: 600, y: 380), from: row, to: popup))
        XCTAssertFalse(HoverPanelInteraction.crossesToPopover(NSPoint(x: 600, y: 100), from: row, to: popup))
    }

    func testCandlesRenderRisingRedAndFallingGreen() throws {
        _ = NSApplication.shared
        let market = StockMarket.mainland
        let first = try XCTUnwrap(market.quoteTime(from: "20260925093000"))
        let last = try XCTUnwrap(market.quoteTime(from: "20260928093000"))
        let chart = StockTrendPlot(frame: NSRect(x: 0, y: 0, width: 336, height: 135))
        chart.trend = StockTrend(code: "sh600036", market: market, range: .dailyCandles,
                                 points: [.init(date: first, price: 41), .init(date: last, price: 39)],
                                 candles: [
                                    .init(date: first, open: 40, high: 42, low: 39, close: 41),
                                    .init(date: last, open: 41, high: 42, low: 38, close: 39),
                                 ])
        let rep = try XCTUnwrap(chart.bitmapImageRepForCachingDisplay(in: chart.bounds))
        chart.cacheDisplay(in: chart.bounds, to: rep)
        var red = 0
        var green = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.5 else { continue }
                if color.redComponent > 0.5, color.redComponent > color.greenComponent * 1.4 {
                    red += 1
                }
                if color.greenComponent > 0.35, color.greenComponent > color.redComponent * 1.4 {
                    green += 1
                }
            }
        }
        XCTAssertGreaterThan(red, 5)
        XCTAssertGreaterThan(green, 5)
    }

    func testETFStackedLineAndKKeepThreeDecimals() throws {
        _ = NSApplication.shared
        let market = StockMarket.mainland
        let first = try XCTUnwrap(market.quoteTime(from: "20260925093000"))
        let last = try XCTUnwrap(market.quoteTime(from: "20260928093000"))
        let quote = StockQuote(
            code: "sh512170", name: "医疗ETF", price: "0.349",
            raise: 0.001, raisePercent: 0.002, volume: 1_000, sessionDate: "2026-09-28"
        )
        let popover = StockTrendPopover()
        popover.show(code: quote.code, name: quote.name, market: market, quote: quote,
                     row: NSRect(x: 450, y: 400, width: 125, height: 16),
                     alongside: NSRect(x: 430, y: 150, width: 780, height: 520))
        defer { popover.dismiss() }
        let window = try XCTUnwrap(popup(title: "医疗ETF"))
        let chart = try XCTUnwrap(window.contentView?.subviews.compactMap { $0 as? StockTrendPlot }
            .first { $0.identifier?.rawValue == "stockLinePlot" })
        let kChart = try XCTUnwrap(window.contentView?.subviews.compactMap { $0 as? StockTrendPlot }
            .first { $0.identifier?.rawValue == "stockKPlot" })
        let latest = try label("stockTrendLatestPrice", in: window)
        let summary = try label("stockTrendSummary", in: window)
        let kSummary = try label("stockKlineSummary", in: window)
        let detail = try label("stockTrendDetail", in: window)
        XCTAssertEqual(latest.stringValue, "最近价格 0.349 CNY")
        XCTAssertEqual(chart.decimalPlaces, 3)
        XCTAssertEqual(kChart.decimalPlaces, 3)
        let candles = [
            StockCandle(date: first, open: 0.342, high: 0.360, low: 0.341, close: 0.345),
            StockCandle(date: last, open: 0.345, high: 0.358, low: 0.343, close: 0.349),
        ]
        let points = candles.map { StockTrendPoint(date: $0.date, price: $0.close) }
        popover.showLine(StockTrend(code: quote.code, market: market, range: .month, points: points, candles: candles))
        popover.showK(StockTrend(code: quote.code, market: market, range: .dailyCandles,
                                 points: points, candles: candles))
        XCTAssertEqual(summary.stringValue, "最高日线 0.349 · 最低日线 0.345 CNY")
        XCTAssertEqual(kSummary.stringValue, "最高 0.360 · 最低 0.341 CNY")
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let plotPoint = content.convert(NSPoint(x: 53, y: kChart.bounds.midY), from: kChart)
        let screen = window.convertToScreen(NSRect(origin: content.convert(plotPoint, to: nil), size: .zero)).origin
        popover.updateHover(at: screen)
        XCTAssertTrue(detail.stringValue.contains("开0.342 高0.360 低0.341 收0.345"))

        var morePrecise = StockQuote(code: quote.code, name: quote.name, price: "0.3490",
                                     raise: 0, raisePercent: 0, volume: 0, sessionDate: "2026-09-28")
        morePrecise.quotedAt = last
        popover.updateQuote(morePrecise, market: market)
        XCTAssertEqual(chart.decimalPlaces, 4)
        XCTAssertEqual(kChart.decimalPlaces, 4)
        XCTAssertEqual(summary.stringValue, "最高日线 0.3490 · 最低日线 0.3450 CNY")
        XCTAssertEqual(kSummary.stringValue, "最高 0.3600 · 最低 0.3410 CNY")
        XCTAssertEqual(latest.stringValue, "最近价格 0.3490 CNY")
    }
}

private actor StockTrendRequests {
    private(set) var requests: [(code: String, range: StockTrendRange)] = []
    func record(_ code: String, _ range: StockTrendRange) { requests.append((code, range)) }
}
