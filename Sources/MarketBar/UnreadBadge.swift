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
/// 一侧未读的状态。
///
/// ⚠️「读不到」和「没有未读」必须分开：以前两者都是 `nil`，于是权限被吊销、
/// 或微信一时读不出来时，界面和「本来就没消息」长得一模一样 —— 用户无从察觉
/// 自己再也收不到未读提醒了。
enum UnreadState: Equatable {
    case count(Int)
    case none
    case unavailable
}

enum UnreadBadge {
    struct Counts: Equatable {
        var weChat: UnreadState = .unavailable
        var weChatSecond: UnreadState = .unavailable

        /// 两侧都读不到，才算「这一轮整体失败」
        var isUnavailable: Bool { weChat == .unavailable && weChatSecond == .unavailable }
    }

    /// 读失败时沿用上一次的显示：一次瞬时失败不该让红数字闪成灰圈。
    /// 连续失败满 `tolerance` 次才认账，这时才显示成「读不到」
    static func displayed(_ fetched: Counts, previous: Counts, failures: Int, tolerance: Int) -> Counts {
        guard fetched.isUnavailable, failures < tolerance else { return fetched }
        return previous
    }

    static let mainBundleID = "com.tencent.xinWeChat"
    static let secondBundleID = "com.tencent.xinWeChatSecond"

    /// 请求「辅助功能」权限。
    ///
    /// 两条一起走：系统那句「MarketBar 想控制这台电脑」每次启动只会弹一次，
    /// 之后系统会静默忽略；所以再直接把设置面板打开到「辅助功能」那一页兜底。
    @MainActor
    static func requestAccessibilityPermission() {
        // 用字面量而不是 kAXTrustedCheckOptionPrompt：那个常量在 Swift 6 下是
        // 非并发安全的全局 var，取用会编译报错。它的值就是这个字符串
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 徽标被点时该干什么：读不到就去要权限，其余情况打开对应的微信
    @MainActor
    static func handleBadgeClick(state: UnreadState, bundleID: String) {
        guard state != .unavailable else {
            requestAccessibilityPermission()
            return
        }
        activate(bundleID: bundleID)
    }

    /// 打开对应的微信（把它的窗口带到前面）；没运行就启动它。
    ///
    /// 顺序有讲究：**优先用 AppleScript 的 `activate`** —— 它最接近「点 Dock 图标」的行为，
    /// 对隐藏窗口也管用（实测直接 `NSRunningApplication.activate` 对主微星常常无效，
    /// 加 `unhide()` 反而把它弄坏了）。失败再退回系统 openApplication / 直接激活。
    /// 第一次会弹一次「MarketBar 想控制微信」的自动化授权。
    @MainActor
    static func activate(bundleID: String) {
        if activateViaAppleScript(bundleID: bundleID) { return }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
            return
        }
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?
            .activate(options: [.activateAllWindows])
    }

    private static func activateViaAppleScript(bundleID: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              !app.isTerminated else { return false }

        // reopen 才会把「进程还在但窗口已关闭」的窗口重新开出来；activate 只管把 app 提到前台
        let source = "tell application id \"\(bundleID)\"\n reopen\n activate\nend tell"
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error == nil
    }

    /// AX title → 未读数。纯函数，便于单测。
    static func count(fromStatusTitle title: String?) -> Int? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value > 0 else { return nil }
        return value
    }

    /// 读两个微信的未读数
    @MainActor
    static func fetch() -> Counts {
        var counts = Counts()
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier else { continue }
            switch bundleID {
            case "com.tencent.xinWeChat":
                counts.weChat = statusItemState(pid: app.processIdentifier)
            case "com.tencent.xinWeChatSecond":
                counts.weChatSecond = statusItemState(pid: app.processIdentifier)
            default:
                continue
            }
        }
        return counts
    }

    /// 取某个进程的「菜单栏附加项」（状态项）里那一项的标题。
    /// ⚠️ 必须用 AXExtrasMenuBar：状态项挂在 app 的 extras 菜单栏上，
    /// 读 kAXMenuBar 只会拿到 App 自己的菜单（Apple/文件/编辑…），读 kAXChildren 只能拿到窗口。
    /// AX 读失败 → `.unavailable`（没权限 / 进程刚起来还没建状态项）；
    /// 读到了但那一项不是数字 → `.none`（真的没有未读）
    private static func statusItemState(pid: pid_t) -> UnreadState {
        let appElement = AXUIElementCreateApplication(pid)

        var extrasRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, "AXExtrasMenuBar" as CFString, &extrasRef
        ) == .success, let extrasRef else { return .unavailable }
        let extrasBar = extrasRef as! AXUIElement

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            extrasBar, kAXChildrenAttribute as CFString, &childrenRef
        ) == .success, let items = childrenRef as? [AXUIElement] else { return .unavailable }

        for item in items {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &titleRef) == .success,
               let count = count(fromStatusTitle: titleRef as? String) {
                return .count(count)
            }
        }
        return .none
    }
}

/// 未读数字的圆形徽标（红底白字），没有未读时整颗隐藏
@MainActor
final class UnreadCountBadgeView: NSView {
    static let diameter: CGFloat = 22

    private let label = NSTextField(labelWithString: "")
    /// 点徽标时执行（用来打开对应的微信）
    /// 点击时把**当前状态**一起传出去 —— 没授权（`.unavailable`）时该做的是
    /// 去要权限，而不是傻乎乎地去打开微信
    var onClick: ((UnreadState) -> Void)?

    private(set) var state: UnreadState = .unavailable

    override func mouseDown(with event: NSEvent) {
        onClick?(state)
    }

    /// 抬起事件必须在这里吃掉。徽标中央被内部的数字标签盖住，标签不处理 mouseUp 时会
    /// 顺着响应链抛给人物视图 —— 于是点一次徽标 = 开微信 **+** 人物说话换姿势，
    /// 还会计进连击状态机（3 秒内点 4 次，人物就躲到牌子后面去了）。
    override func mouseUp(with event: NSEvent) {}

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

    /// 有未读：红底 + 数字（超过 99 显示 99+）；没有未读：灰圈（仍可点击打开微信）；
    /// 读不到：深一号的圈 + 「!」，和「没有未读」区分开
    func update(_ state: UnreadState) {
        self.state = state
        switch state {
        case .count(let count):
            label.stringValue = count > 99 ? "99+" : "\(count)"
            layer?.backgroundColor = NSColor(calibratedRed: 0.92, green: 0.22, blue: 0.2, alpha: 1).cgColor
        case .none:
            label.stringValue = ""
            layer?.backgroundColor = NSColor(white: 0.45, alpha: 0.55).cgColor
        case .unavailable:
            label.stringValue = "!"
            layer?.backgroundColor = NSColor(white: 0.25, alpha: 0.7).cgColor
        }
    }
}
