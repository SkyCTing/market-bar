import AppKit

/// 会议模式的「对外副作用」：退出微信、切专注模式。
///
/// 全部做成可注入的闭包 —— 「该退哪些、该开回哪些、什么时候根本不该跑」这些判断
/// 才好测，不用真的去退你的微信。
///
/// 两件事的性质完全不同：
///   · 退出微信：走本 app **已经拿到过的自动化授权**（`UnreadBadge` 早就在用
///     AppleScript 控制微信了），不新增权限
///   · 切专注模式：macOS **没有公开 API**（`INFocusStatus.isFocused` 是 readonly，
///     也没有 DoNotDisturb framework，老的 defaults 写法 Big Sur 之后就失效了），
///     只能借道用户自己建的快捷指令
@MainActor
struct MeetingSideEffects {
    /// 两个微信的 bundle id，和 `UnreadBadge` 用的是同一对
    static let weChatBundleIDs = ["com.tencent.xinWeChat", "com.tencent.xinWeChatSecond"]
    static let shortcutsPath = "/usr/bin/shortcuts"

    // 闭包类型也要标 @MainActor：静态方法在 @MainActor 类型上默认是隔离的，
    // 不标的话赋过去会「loses global actor 'MainActor'」
    typealias IsRunning = @MainActor (String) -> Bool
    typealias QuitApp = @MainActor (String) -> Bool
    typealias LaunchApp = @MainActor (String) -> Void
    typealias RunShortcut = @MainActor (String) -> Bool

    var isRunning: IsRunning = MeetingSideEffects.processIsRunning
    var quitApp: QuitApp = MeetingSideEffects.quitViaAppleScript
    var launchApp: LaunchApp = MeetingSideEffects.launchInBackground
    var runShortcut: RunShortcut = MeetingSideEffects.runShortcutProcess

    /// 退出正在跑的微信，返回**被我们退掉的那些** bundle id。
    ///
    /// 必须记下来：散会后只把我们退掉的、且还没有自己起来的开回来。
    /// 用户自己在会议期间手动退掉的，不该被我们自作主张开回来
    func quitWeChats() -> [String] {
        var quit: [String] = []
        for bundleID in Self.weChatBundleIDs where isRunning(bundleID) {
            if quitApp(bundleID) { quit.append(bundleID) }
        }
        return quit
    }

    /// 把之前被我们退掉的微信开回来。已经自己起来了的跳过 ——
    /// 否则等于把它激活到前台，平白打扰
    func restoreWeChats(_ bundleIDs: [String]) {
        for bundleID in bundleIDs where !isRunning(bundleID) {
            launchApp(bundleID)
        }
    }

    /// 跑快捷指令切专注模式。名字为空 = 没配，直接跳过（不算失败）
    @discardableResult
    func applyFocus(shortcut named: String) -> Bool {
        let name = named.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        return runShortcut(name)
    }

    // MARK: - 默认实现

    static func processIsRunning(_ bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { !$0.isTerminated }
    }

    /// 用 AppleScript 的 `quit`（优雅退出，微信会正常保存），不用 `forceTerminate`
    /// —— 那是 SIGKILL，正在输入的草稿会没。走的是已经授权过的自动化通路
    static func quitViaAppleScript(_ bundleID: String) -> Bool {
        let source = "tell application id \"\(bundleID)\" to quit"
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard error == nil else {
            NSLog("MarketBar: 退出 %@ 失败 %@", bundleID, String(describing: error))
            return false
        }
        return true
    }

    static func launchInBackground(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            NSLog("MarketBar: 找不到 %@，没法开回来", bundleID)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // 开会呢，别把窗口抢到前面来
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    /// `shortcuts run <名字>`
    ///
    /// 用 `terminationHandler` 而不是 `waitUntilExit()`：主线程不能为一条快捷指令卡住。
    /// 失败只记日志，不弹框 —— 用户没建快捷指令时，不该每次开会都挨一个错误提示
    static func runShortcutProcess(_ name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shortcutsPath)
        process.arguments = ["run", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            guard finished.terminationStatus != 0 else { return }
            NSLog("MarketBar: 快捷指令「%@」退出码 %d（名字对得上吗？）", name, finished.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            NSLog("MarketBar: 快捷指令起不来 %@", error.localizedDescription)
            return false
        }
        return true
    }
}
