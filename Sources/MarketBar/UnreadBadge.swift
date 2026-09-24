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
