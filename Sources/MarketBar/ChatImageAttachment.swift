import AppKit

/// 把粘贴板 / 文件里的图变成能发给 CLI 的附件。
///
/// CLI 只收 base64 的 PNG/JPEG 内容块（见 `ClaudeChatMessage.streamJSONLine()`），
/// 所以这里统一转 PNG，并把过大的图缩下来。
enum ChatImageAttachment {
    /// 最长边上限。Claude 推荐不超过 1568px —— 原图动辄三四千像素，
    /// 不缩的话又慢又费 token，而且大图更容易被接口拒掉
    static let maximumDimension: CGFloat = 1568

    /// 缩放后的尺寸：**只缩不放**，保持长宽比。
    /// 纯函数，便于单测（缩放的边界最容易写错）
    static func fittedSize(_ size: CGSize, maximum: CGFloat = maximumDimension) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > maximum, longest > 0 else { return size }
        let scale = maximum / longest
        return CGSize(
            width: max(1, (size.width * scale).rounded()),
            height: max(1, (size.height * scale).rounded())
        )
    }

    /// 从粘贴板取图。
    ///
    /// PNG 优先，其次 TIFF —— macOS 上复制图片（截图、右键拷贝）常常只给 TIFF
    static func imageData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        if let tiff = pasteboard.data(forType: .tiff) { return tiff }
        return nil
    }

    /// Data → 附件。转不成图就返回 nil（调用方 beep）
    static func make(from data: Data) -> ClaudeChatImage? {
        guard let source = NSBitmapImageRep(data: data) else { return nil }

        let target = fittedSize(CGSize(width: source.pixelsWide, height: source.pixelsHigh))
        let rep = (Int(target.width) == source.pixelsWide && Int(target.height) == source.pixelsHigh)
            ? source
            : resized(source, to: target) ?? source

        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return ClaudeChatImage(mediaType: "image/png", base64: png.base64EncodedString())
    }

    private static func resized(_ source: NSBitmapImageRep, to size: CGSize) -> NSBitmapImageRep? {
        guard let target = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        let image = NSImage(size: NSSize(width: source.pixelsWide, height: source.pixelsHigh))
        image.addRepresentation(source)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: target) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size))
        context.flushGraphics()

        return target
    }
}
