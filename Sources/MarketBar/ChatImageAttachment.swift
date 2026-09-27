import AppKit
import UniformTypeIdentifiers
import ImageIO

/// 把粘贴板 / 文件里的图变成能发给 CLI 的附件。
///
/// CLI 只收 base64 的 PNG/JPEG 内容块（见 `ClaudeChatMessage.streamJSONLine()`），
/// 优先转 PNG，复杂照片过大时改 JPEG；按实际像素缩小并应用图片方向。
enum ChatImageAttachment {
    /// 最长边上限。Claude 推荐不超过 1568px —— 原图动辄三四千像素，
    /// 不缩的话又慢又费 token，而且大图更容易被接口拒掉
    static let maximumDimension: CGFloat = 1568
    static let maximumCount = 4
    static let maximumInputBytes = 50 * 1_024 * 1_024
    static let maximumImageBytes = 4 * 1_024 * 1_024

    enum AttachmentError: LocalizedError {
        case tooMany, tooLarge, invalidImage

        var errorDescription: String? {
            switch self {
            case .tooMany: return "每条消息最多附 4 张图片，请先移除一些图片"
            case .tooLarge: return "原图片超过 50 MB，请先缩小图片"
            case .invalidImage: return "无法读取或转换这张图片，请选择有效的 PNG、JPEG、HEIC 等图片文件"
            }
        }
    }

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
    static func images(from pasteboard: NSPasteboard) throws -> [ClaudeChatImage] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            let files = urls.filter { $0.isFileURL && isImageFile($0) }
            if !files.isEmpty { return try images(from: files) }
        }
        if let png = pasteboard.data(forType: .png) { return [try converted(png)] }
        if let tiff = pasteboard.data(forType: .tiff) { return [try converted(tiff)] }
        for type in NSImage.imageTypes {
            if let data = pasteboard.data(forType: .init(type)) { return [try converted(data)] }
        }

        // 交给 NSImage 兜一层：它能认的来源比逐个 type 查更全
        if let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation {
            return [try converted(tiff)]
        }
        return []
    }

    static func images(from files: [URL]) throws -> [ClaudeChatImage] {
        guard files.count <= maximumCount else { throw AttachmentError.tooMany }
        return try files.map { url in
            guard url.isFileURL, isImageFile(url) else { throw AttachmentError.invalidImage }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maximumInputBytes else { throw AttachmentError.tooLarge }
            return try converted(Data(contentsOf: url, options: .mappedIfSafe))
        }
    }

    private static func converted(_ data: Data) throws -> ClaudeChatImage {
        guard data.count <= maximumInputBytes else { throw AttachmentError.tooLarge }
        guard let image = make(from: data) else { throw AttachmentError.invalidImage }
        return image
    }

    /// 靠 UTI 判断，别只看扩展名
    static func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// Data → 附件。转不成图就返回 nil（调用方 beep）
    static func make(from data: Data) -> ClaudeChatImage? {
        guard data.count <= maximumInputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maximumDimension),
              ] as CFDictionary) else { return nil }
        let rep = NSBitmapImageRep(cgImage: thumbnail)
        if let png = rep.representation(using: .png, properties: [:]), png.count <= maximumImageBytes {
            return ClaudeChatImage(mediaType: "image/png", base64: png.base64EncodedString())
        }
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]),
              jpeg.count <= maximumImageBytes else { return nil }
        return ClaudeChatImage(mediaType: "image/jpeg", base64: jpeg.base64EncodedString())
    }
}
