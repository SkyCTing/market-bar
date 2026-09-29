import AppKit
import XCTest

@testable import MarketBar

/// 面板列宽的回归测试：把「估算放得下」变成「测量确认放得下」。
/// 谁改了列宽常量或清单里的名称，这里会先报出来。
@MainActor
final class HoverPanelLayoutTests: XCTestCase {
    private func width(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// 六列宽度 + 五个间隙 + 两侧内边距必须正好等于面板宽度
    func testColumnsTileTheWidthExactly() {
        let total = HoverPanel.padding * 2
            + HoverPanel.columnGap * 6
            + HoverPanel.nameColumnWidth
            + HoverPanel.volumeColumnWidth
            + HoverPanel.sharesColumnWidth
            + HoverPanel.costColumnWidth
            + HoverPanel.priceColumnWidth
            + HoverPanel.profitColumnWidth
            + HoverPanel.floatingColumnWidth

        XCTAssertEqual(total, HoverPanel.panelWidth, accuracy: 0.001)
    }

    /// 每个名称都要放得进名称列（量能已经拆成独立的列，不再挤在名称后面）
    func testEveryNameFitsTheNameColumn() {
        for entry in StockWatchlist.entries {
            let measured = (entry.name as NSString)
                .size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .regular)]).width
            XCTAssertLessThanOrEqual(
                measured, HoverPanel.nameColumnWidth + 0.5,
                "\(entry.name) 需要 \(measured)pt，名称列只有 \(HoverPanel.nameColumnWidth)pt"
            )
        }
    }

    /// 量能列的文本是「倍数（固定宽度）+ 标记」，要放得下最宽的组合
    func testVolumeColumnFitsWidestContent() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let widest = StockVolume.volumeText(12.34)              // "12.3 放量"
        let measured = (widest as NSString).size(withAttributes: [.font: font]).width

        XCTAssertLessThanOrEqual(measured, HoverPanel.volumeColumnWidth + 0.5)
    }

    /// 三个数值列各自的最宽内容（含持仓里最大的股数与可能的七位数盈亏）
    func testNumericColumnsFitTheirWidestContent() {
        let sharesFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

        XCTAssertLessThanOrEqual(
            width(HoldingFormat.sharesText(1_100_000), sharesFont),
            HoverPanel.sharesColumnWidth + 0.5
        )
        // 指数那行的价格位数最多
        XCTAssertLessThanOrEqual(
            width("3936.52  -0.39%", valueFont),
            HoverPanel.priceColumnWidth + 0.5
        )
        XCTAssertLessThanOrEqual(
            width("-1,234,567", valueFont),
            HoverPanel.profitColumnWidth + 0.5
        )
        XCTAssertLessThanOrEqual(
            width("USD -1,234,567", valueFont),
            HoverPanel.profitColumnWidth + 0.5
        )
        XCTAssertLessThanOrEqual(
            width("HKD -1,234,567  +12.34%", valueFont),
            HoverPanel.floatingColumnWidth + 0.5
        )
    }

    func testLivePanelPlacesSharesAndCostImmediatelyBeforeFloatingProfit() throws {
        _ = NSApplication.shared
        let title = "列布局测试-\(UUID())"
        func data(price: String) -> HoverPanelData {
            HoverPanelData(
                provider: title, price: "900", changeAmount: "0", changePercent: "0",
                isNegative: nil, updateTime: "09:30:00", refreshInterval: "1 秒",
                alertInfo: "未设置", market: .empty,
                stocks: [StockRow(quote: StockQuote(
                    code: "sh600036", name: "测试招商", price: price, raise: 0.01,
                    raisePercent: 0.002, volume: 100,
                    sessionDate: StockMarket.mainland.dateString(for: Date()), quotedAt: Date()
                ), volumeRatio: nil)],
                summaries: [], holidays: [:]
            )
        }
        let screen = try XCTUnwrap(NSScreen.main)
        let panel = HoverPanel()
        panel.show(
            below: NSRect(x: screen.frame.midX, y: screen.frame.maxY - 30, width: 60, height: 24),
            data: data(price: "40.64")
        )
        defer { panel.dismiss() }
        let window = try XCTUnwrap(NSApp.windows.first {
            $0.isVisible && $0.contentView?.subviews.contains {
                ($0 as? NSTextField)?.stringValue == title
            } == true
        })
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let labels = content.subviews.compactMap { $0 as? NSTextField }
        let headers = [
            HoverPanel.volumeHeader, HoverPanel.priceHeader, HoverPanel.profitHeader,
            HoverPanel.sharesHeader, HoverPanel.costHeader, HoverPanel.floatingHeader,
        ]
        let cells = try headers.map { heading in
            try XCTUnwrap(labels.first { $0.stringValue == heading })
        }
        for (left, right) in zip(cells, cells.dropFirst()) {
            XCTAssertGreaterThanOrEqual(right.frame.minX - left.frame.maxX, 3,
                                        "\(left.stringValue) must precede \(right.stringValue) without overlapping")
        }
        XCTAssertLessThanOrEqual(cells.last!.frame.maxX, HoverPanel.panelWidth - HoverPanel.padding + 2.5)
        let value = try XCTUnwrap(labels.first { $0.stringValue.hasPrefix("40.64") })
        XCTAssertEqual(value.frame.minX, cells[1].frame.minX, accuracy: 0.5)
        panel.updateContent(data: data(price: "41.08"))
        XCTAssertTrue(value.stringValue.hasPrefix("41.08"))
        XCTAssertEqual(value.frame.minX, cells[1].frame.minX, accuracy: 0.5)
    }
}
