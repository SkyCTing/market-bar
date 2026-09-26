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
            $0 is NSPanel && $0.isVisible && $0.contentView?.subviews.contains {
                ($0 as? NSTextField)?.stringValue.contains("腾讯控股") == true
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

    func testInterleavedWatchlistIsActuallyGroupedInPanel() throws {
        func row(_ code: String, _ name: String) -> StockRow {
            StockRow(quote: .placeholder(code: code, name: name), volumeRatio: nil)
        }
        let rows = [
            row("usAAPL", "美股测试"), row("sh600036", "沪市测试一"),
            row("hk00700", "港股测试"), row("sh512170", "沪市测试二"),
        ]
        let data = HoverPanelData(
            provider: "测试", price: "0", changeAmount: "0", changePercent: "0",
            isNegative: nil, updateTime: "09:00:00", refreshInterval: "1 秒",
            alertInfo: "未设置", market: .empty, stocks: rows, summaries: [],
            holidays: [:], unread: .init()
        )
        let screen = try XCTUnwrap(NSScreen.main)
        let panel = HoverPanel()
        panel.show(
            below: NSRect(x: screen.frame.midX, y: screen.frame.maxY - 30, width: 60, height: 24),
            data: data
        )
        defer { panel.dismiss() }

        let window = try XCTUnwrap(NSApp.windows.first {
            $0 is NSPanel && $0.isVisible && $0.contentView?.subviews.contains {
                ($0 as? NSTextField)?.stringValue.contains("沪市测试一") == true
            } == true
        })
        let labels = try XCTUnwrap(window.contentView).subviews.compactMap { $0 as? NSTextField }
        let ordered = labels.filter {
            ["A股", "港股", "美股"].contains($0.stringValue)
                || $0.stringValue.contains("测试一")
                || $0.stringValue.contains("测试二")
                || $0.stringValue.contains("港股测试")
                || $0.stringValue.contains("美股测试")
        }.sorted { $0.frame.midY > $1.frame.midY }.map { label in
            ["A股", "港股", "美股"].contains(label.stringValue)
                ? label.stringValue
                : label.stringValue.replacingOccurrences(of: "无价 · ", with: "")
        }
        XCTAssertEqual(ordered, ["A股", "沪市测试一", "沪市测试二", "港股", "港股测试 · HK", "美股", "美股测试 · US"])
    }

    func testHoldingSummaryRefreshesAndNewCurrencyGetsItsOwnRow() throws {
        func data(_ summaries: [HoldingSummary]) -> HoverPanelData {
            HoverPanelData(
                provider: "测试", price: "0", changeAmount: "0", changePercent: "0",
                isNegative: nil, updateTime: "09:00:00", refreshInterval: "1 秒",
                alertInfo: "未设置", market: .empty, stocks: [], summaries: summaries,
                holidays: [:], unread: .init()
            )
        }
        let original = HoldingSummary(
            currency: "CNY", marketValue: 40_000, todayProfit: 100,
            floatingProfit: nil, floatingPercent: nil, counted: 1
        )
        let updated = HoldingSummary(
            currency: "CNY", marketValue: 41_000, todayProfit: 200,
            floatingProfit: nil, floatingPercent: nil, counted: 1
        )
        let hongKong = HoldingSummary(
            currency: "HKD", marketValue: 8_000, todayProfit: nil,
            floatingProfit: nil, floatingPercent: nil, counted: 1
        )
        let panel = HoverPanel()
        let screen = try XCTUnwrap(NSScreen.main)
        panel.show(below: NSRect(x: screen.frame.midX, y: screen.frame.maxY - 30, width: 60, height: 24),
                   data: data([original]))
        defer { panel.dismiss() }

        let window = try XCTUnwrap(NSApp.windows.first {
            $0.isVisible && $0.contentView?.subviews.contains {
                ($0 as? NSTextField)?.stringValue == original.lineText
            } == true
        })
        let line = try XCTUnwrap(window.contentView?.subviews.compactMap { $0 as? NSTextField }
            .first { $0.stringValue == original.lineText })
        panel.updateContent(data: data([updated]))
        XCTAssertEqual(line.stringValue, updated.lineText)

        panel.updateContent(data: data([updated, hongKong]))
        XCTAssertTrue(NSApp.windows.contains {
            $0.isVisible && $0.contentView?.subviews.contains {
                ($0 as? NSTextField)?.stringValue == hongKong.lineText
            } == true
        })
    }
}
