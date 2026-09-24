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

    /// 四列宽度 + 三个间隙 + 两侧内边距必须正好等于面板宽度
    func testColumnsTileTheWidthExactly() {
        let total = HoverPanel.padding * 2
            + HoverPanel.columnGap * 3
            + HoverPanel.nameColumnWidth
            + HoverPanel.sharesColumnWidth
            + HoverPanel.priceColumnWidth
            + HoverPanel.profitColumnWidth

        XCTAssertEqual(total, HoverPanel.panelWidth, accuracy: 0.001)
    }

    /// 每个名称配上最长的量能尾巴（1.20 放量）都要放得进名称列，
    /// 否则最长的几行会被截断、看不到量能。
    func testEveryNameWithLongestVolumeTailFitsTheNameColumn() {
        let longestTailRatio = StockVolume.expansionThreshold   // " 1.20 放量" 是最宽的尾巴

        for entry in StockWatchlist.entries {
            let title = HoverPalette.stockTitle(name: entry.name, ratio: longestTailRatio)
            let measured = title.size().width
            XCTAssertLessThanOrEqual(
                measured, HoverPanel.nameColumnWidth + 0.5,
                "\(entry.name) 配上量能尾巴需要 \(measured)pt，名称列只有 \(HoverPanel.nameColumnWidth)pt"
            )
        }
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
    }
}
