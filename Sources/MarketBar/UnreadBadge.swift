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

    /// 取某个进程「第二个菜单栏」（第一个是 App 自己的菜单，状态项在第二个）里那一项的标题
    private static func statusItemTitle(pid: pid_t) -> Int? {
        let appElement = AXUIElementCreateApplication(pid)

        var menuBars: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBars) == .success,
              let menuBar = menuBars else { return nil }
        // 状态项挂在 menu bar 2 上；AX 里通过 AXChildren 能拿到全部菜单栏
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXChildrenAttribute as CFString, &children) == .success,
              let elements = children as? [AXUIElement] else { return nil }

        for element in elements where AXUIElementGetTypeID() == CFGetTypeID(element) {
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success else { continue }
            if let text = title as? String, let count = count(fromStatusTitle: text) {
                return count
            }
        }
        _ = menuBar
        return nil
    }
}
