import Foundation

/// 人物举牌价签的两行排版：上排金价、下排组合当日盈亏。
///
/// 两行里**盈亏是主角**（字号更大），金价退为次要信息。
/// 纯几何 + 纯文本规则，单独成文件既便于单测，也让角色那一层完全不认识股票
/// —— 它只接收一个已经格式化好的字符串。
enum FloatingCharacterSignLayout {
    /// 高度分配：金价只留一条的位置，其余全给盈亏（牌子高度固定，两行此消彼长）
    static let priceHeightRatio: CGFloat = 0.38
    /// 金价字号上限 = 盈亏字号 × 该比例（即盈亏至少是金价的 1 / 0.8 = 1.25 倍）
    static let priceFontScale: CGFloat = 0.8

    /// nil 与空串等价：都表示「没有第二行」
    static func normalizedProfitText(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    static func gap(in signRect: NSRect) -> CGFloat {
        max(1, signRect.height * 0.05)
    }

    /// 两行各自的可用尺寸（宽度都是整个牌子，只切高度）。
    /// 没有第二行时返回整个牌子尺寸 —— 与改动前的单行行为完全一致。
    static func availableSizes(in signRect: NSRect, hasProfit: Bool) -> (price: NSSize, profit: NSSize?) {
        guard hasProfit else { return (signRect.size, nil) }

        let usable = signRect.height - gap(in: signRect)
        return (
            NSSize(width: signRect.width, height: usable * priceHeightRatio),
            NSSize(width: signRect.width, height: usable * (1 - priceHeightRatio))
        )
    }

    /// 两行作为一整块在牌子内垂直居中后，各自绘制原点（左下角）。
    ///
    /// AppKit 的 y 轴向上：从块的顶端往下依次减高度。
    /// 单行时退化成今天的中点公式 `midY - height / 2`，逐像素相同。
    static func drawOrigins(
        priceSize: NSSize,
        profitSize: NSSize?,
        in signRect: NSRect
    ) -> (price: NSPoint, profit: NSPoint?) {
        guard let profitSize, profitSize.height > 0 else {
            return (
                NSPoint(x: signRect.midX - priceSize.width / 2, y: signRect.midY - priceSize.height / 2),
                nil
            )
        }

        let blockHeight = priceSize.height + gap(in: signRect) + profitSize.height
        let top = signRect.midY + blockHeight / 2
        let priceY = top - priceSize.height
        return (
            NSPoint(x: signRect.midX - priceSize.width / 2, y: priceY),
            NSPoint(
                x: signRect.midX - profitSize.width / 2,
                y: priceY - gap(in: signRect) - profitSize.height
            )
        )
    }
}
