import AppKit
import XCTest

@testable import MarketBar

@MainActor
final class HoverPanelQuoteTimeTests: XCTestCase {
    func testHoveringStockNameUpdatesVisibleQuoteTimeRow() throws {
        let quotedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-25T08:08:20Z"))
        let quote = StockQuote(
            code: "hk00700", name: "腾讯控股", price: "436.600",
            raise: -1.8, raisePercent: -0.0041, volume: 0,
            sessionDate: "2026-09-25", quotedAt: quotedAt
        )
        let panel = HoverPanel()
        let data = HoverPanelData(
            provider: "测试", price: "0", changeAmount: "0", changePercent: "0",
            isNegative: nil, updateTime: "08:00:00", refreshInterval: "1 秒",
            alertInfo: "未设置", market: .empty,
            stocks: [StockRow(quote: quote, volumeRatio: nil)],
            summaries: [],
            holidays: [:], unread: .init()
        )
        let screen = try XCTUnwrap(NSScreen.main)
        panel.show(below: NSRect(x: screen.frame.midX, y: screen.frame.maxY - 30, width: 60, height: 24), data: data)
        defer { panel.dismiss() }

        let window = try XCTUnwrap(NSApp.windows.first {
            $0 is NSPanel && $0.contentView?.subviews.contains {
                ($0 as? NSTextField)?.stringValue == "报价时间"
            } == true
        })
        let content = try XCTUnwrap(window.contentView)
        let labels = content.subviews.compactMap { $0 as? NSTextField }
        let name = try XCTUnwrap(labels.first { $0.stringValue.contains("腾讯控股") })
        let result = try XCTUnwrap(labels.first { $0.stringValue == "悬停股票名称或现价查看" })
        let point = window.convertToScreen(NSRect(
            origin: content.convert(NSPoint(x: name.frame.midX, y: name.frame.midY), to: nil),
            size: .zero
        )).origin

        panel.updateHoveredQuote(at: point)
        XCTAssertTrue(result.stringValue.contains("2026-09-25 16:08:20 香港时间"))
        XCTAssertTrue(result.stringValue.contains(" · 旧"))

        panel.updateContent(data: data)
        XCTAssertTrue(result.stringValue.contains("2026-09-25 16:08:20 香港时间"))
        panel.updateHoveredQuote(at: window.convertToScreen(NSRect(
            origin: content.convert(NSPoint(x: 2, y: 2), to: nil), size: .zero
        )).origin)
        XCTAssertEqual(result.stringValue, "悬停股票名称或现价查看")
    }
}
