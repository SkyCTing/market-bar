import AppKit
import UniformTypeIdentifiers

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

    /// 从粘贴板取图。**几条路都要试** —— 图片进粘贴板的方式不止一种：
    ///
    /// - 截图、浏览器里右键拷贝：给的是 `.png` / `.tiff` 原始数据
    /// - **在 Finder 里拷贝一个图片文件：粘贴板上只有文件 URL，没有图像数据**
    ///   （只查 png/tiff 的话这种就漏了，表现成「⌘V 没反应」）
    static func imageData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        if let tiff = pasteboard.data(forType: .tiff) { return tiff }

        // 交给 NSImage 兜一层：它能认的来源比逐个 type 查更全
        if let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation {
            return tiff
        }

        // 文件 URL：读出来，但**必须是图片**才收（拖个 .txt 进来不该当成图）
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls where isImageFile(url) {
                if let data = try? Data(contentsOf: url) { return data }
            }
        }
        return nil
    }

    /// 靠 UTI 判断，别只看扩展名
    static func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
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
