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
}
