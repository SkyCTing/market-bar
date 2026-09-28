import AppKit
import XCTest
@testable import MarketBar

@MainActor
final class StockTrendPopoverTests: XCTestCase {
    private func data(_ suffix: String) -> HoverPanelData {
        func row(_ code: String, _ name: String) -> StockRow {
            StockRow(quote: .placeholder(code: code, name: name + suffix), volumeRatio: nil)
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

    private func label(_ id: String, in window: NSPanel) throws -> NSTextField {
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
        panel.loadStockTrend = { code, range in
            await calls.record(code, range)
            let market = try XCTUnwrap(StockMarket.forCode(code))
            let date = try XCTUnwrap(market.quoteTime(from: "20260928093000"))
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
        }
        let firstPopup = try XCTUnwrap(popup(title: "A股\(suffix)"))
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
        let control = try XCTUnwrap(firstPopup.contentView?.subviews.compactMap { $0 as? NSSegmentedControl }.first)
        control.selectedSegment = StockTrendRange.month.rawValue
        _ = NSApp.sendAction(try XCTUnwrap(control.action), to: control.target, from: control)
        try await waitUntil {
            (try? self.label("stockTrendSummary", in: firstPopup).stringValue.contains("最高日线 41.00")) == true
        }

        try hover("港股\(suffix)", in: window, panel: panel)
        try await waitUntil {
            guard let popup = self.popup(title: "港股\(suffix)") else { return false }
            return (try? self.label("stockTrendSummary", in: popup).stringValue.contains("最高价格 443.00")) == true
        }
        try hover("美股\(suffix)", in: window, panel: panel)
        XCTAssertNil(popup(title: "美股\(suffix)"))
        XCTAssertNil(popup(title: "港股\(suffix)"))
        let requests = await calls.requests
        XCTAssertEqual(requests.map(\.code), ["sh600036", "sh600036", "hk00700"])
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
}

private actor StockTrendRequests {
    private(set) var requests: [(code: String, range: StockTrendRange)] = []
    func record(_ code: String, _ range: StockTrendRange) { requests.append((code, range)) }
}
