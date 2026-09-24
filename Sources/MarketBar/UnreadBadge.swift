import AppKit
import ApplicationServices

/// 从微信的**菜单栏状态项**读未读数。
///
/// 原理：微信在菜单栏的图标是一个 status item，它的 AX title 就是未读数字（实测 title="5"）。
/// 没有未读时 title 不是数字（或为空），此时按「不显示」处理。
/// 两个微信进程都叫 `WeChat`，靠 bundle id 区分：
///   主微信 com.tencent.xinWeChat ｜ 微信小号 com.tencent.xinWeChatSecond
///
/// 需要「辅助功能」权限（系统设置 → 隐私与安全性 → 辅助功能）。
enum UnreadBadge {
    struct Counts: Equatable {
        var weChat: Int?
        var weChatSecond: Int?
    }

    static let mainBundleID = "com.tencent.xinWeChat"
    static let secondBundleID = "com.tencent.xinWeChatSecond"

    /// 打开对应的微信：没运行就启动它；运行中就把窗口带到前面。
    ///
    /// 两条路都要走：
    /// - macOS 14+ 是「协作式激活」，后台 app 直接 `activate` 可能被拒（返回值 false），
    ///   所以失败时退回交系统 `openApplication` 再激活一次；
    /// - 微信没在运行时，原来的实现是**静默什么都不做**，这里补上启动。
    @MainActor
    static func activate(bundleID: String) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            // 微信窗口可能是「隐藏」状态：隐藏的 app 只 activate 不会把窗口带出来，必须先 unhide
            if app.isHidden {
                app.unhide()
            }
            if app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) {
                return
            }
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    /// AX title → 未读数。纯函数，便于单测。
    static func count(fromStatusTitle title: String?) -> Int? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value > 0 else { return nil }
        return value
    }

    /// 读两个微信的未读数（读不到就是 nil，界面据此不显示）
    @MainActor
    static func fetch() -> Counts {
        var counts = Counts()
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier else { continue }
            switch bundleID {
            case "com.tencent.xinWeChat":
                counts.weChat = statusItemTitle(pid: app.processIdentifier)
            case "com.tencent.xinWeChatSecond":
                counts.weChatSecond = statusItemTitle(pid: app.processIdentifier)
            default:
                continue
            }
        }
        return counts
    }

    /// 取某个进程的「菜单栏附加项」（状态项）里那一项的标题。
    /// ⚠️ 必须用 AXExtrasMenuBar：状态项挂在 app 的 extras 菜单栏上，
    /// 读 kAXMenuBar 只会拿到 App 自己的菜单（Apple/文件/编辑…），读 kAXChildren 只能拿到窗口。
    private static func statusItemTitle(pid: pid_t) -> Int? {
        let appElement = AXUIElementCreateApplication(pid)

        var extrasRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, "AXExtrasMenuBar" as CFString, &extrasRef
        ) == .success, let extrasRef else { return nil }
        let extrasBar = extrasRef as! AXUIElement

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            extrasBar, kAXChildrenAttribute as CFString, &childrenRef
        ) == .success, let items = childrenRef as? [AXUIElement] else { return nil }

        for item in items {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &titleRef) == .success,
               let count = count(fromStatusTitle: titleRef as? String) {
                return count
            }
        }
        return nil
    }
}

/// 未读数字的圆形徽标（红底白字），没有未读时整颗隐藏
@MainActor
final class UnreadCountBadgeView: NSView {
    static let diameter: CGFloat = 22

    private let label = NSTextField(labelWithString: "")
    /// 点徽标时执行（用来打开对应的微信）
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.92, green: 0.22, blue: 0.2, alpha: 1).cgColor
        layer?.cornerRadius = Self.diameter / 2

        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: Self.diameter),
            heightAnchor.constraint(equalToConstant: Self.diameter),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 有未读：红底 + 数字（超过 99 显示 99+）；没有未读：**仍然显示**一颗灰圈（可点击打开微信）
    func update(count: Int?) {
        guard let count, count > 0 else {
            label.stringValue = ""
            layer?.backgroundColor = NSColor(white: 0.45, alpha: 0.55).cgColor
            return
        }
        label.stringValue = count > 99 ? "99+" : "\(count)"
        layer?.backgroundColor = NSColor(calibratedRed: 0.92, green: 0.22, blue: 0.2, alpha: 1).cgColor
    }
}
