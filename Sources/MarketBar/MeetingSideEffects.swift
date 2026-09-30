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

    /// 试着退出正在跑的微信，返回**尝试过的**那些 bundle id。
    ///
    /// 必须记下来：散会后只把我们动过的、且还没有自己起来的开回来。
    /// 用户自己在会议期间手动退掉的，不该被我们自作主张开回来。
    ///
    /// ⚠️ **不看 `quitApp` 的返回值**。微信退得极快，Apple Event 的回执还没回来
    /// 它就没了，AppleScript 于是报一个「连接失效」之类的错 —— 但那其实是**退出成功**。
    /// 之前按返回值判断，结果微信明明退了还弹「没能退出」的框。
    /// 真正算不算成功，隔一会儿看它还在不在（`verifyQuit`）才算数
    func quitWeChats() -> [String] {
        var attempted: [String] = []
        for bundleID in Self.weChatBundleIDs where isRunning(bundleID) {
            _ = quitApp(bundleID)
            attempted.append(bundleID)
        }
        return attempted
    }

    /// 隔一会儿回头确认：**还在跑的**才是真没退掉
    func verifyQuit(_ bundleIDs: [String]) -> [String] {
        bundleIDs.filter { isRunning($0) }
    }

    /// 把之前被我们退掉的微信开回来。已经自己起来了的跳过 ——
    /// 否则等于把它激活到前台，平白打扰
    func restoreWeChats(_ bundleIDs: [String]) {
        for bundleID in bundleIDs where !isRunning(bundleID) {
            launchApp(bundleID)
        }
    }

    /// 开回来之后隔一会儿再确认一次。
    ///
    /// 「派发成功」不等于「真的起来了」—— `openApplication` 的失败是异步回调的，
    /// 而且 app 本身也可能启动失败。所以隔几秒回头看一眼才算数
    func verifyRestored(_ bundleIDs: [String]) -> [String] {
        bundleIDs.filter { !isRunning($0) }
    }

    /// bundle id → 给人看的名字，报错时用
    static func displayName(for bundleID: String) -> String {
        bundleID == weChatBundleIDs.first ? "微信" : "微信小号"
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
    /// —— 那是 SIGKILL，正在输入的草稿会没。走的是已经授权过的自动化通路。
    ///
    /// 返回的 Bool **只表示「这条 Apple Event 发出去时没报错」**，不代表真退掉了：
    /// app 退得快时回执收不到，脚本照样报错。判成败请用 `verifyQuit`
    static func quitViaAppleScript(_ bundleID: String) -> Bool {
        let source = "tell application id \"\(bundleID)\" to quit"
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            // 这个错多半是「app 已经没了」造成的回执丢失，不是真失败，只记不报
            NSLog("MarketBar: 发 quit 给 %@ 时报了 %@（不代表没退掉）", bundleID, String(describing: error))
        }
        return error == nil
    }

    static func launchInBackground(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            NSLog("MarketBar: 找不到 %@ 的安装位置，没法开回来", bundleID)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // 开会呢，别把窗口抢到前面来
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                NSLog("MarketBar: 开回 %@ 时报错 %@，退回普通打开方式再试", bundleID, error.localizedDescription)
                // 退回最简单的那条路：直接按 app 路径打开
                NSWorkspace.shared.open(url)
            } else {
                NSLog("MarketBar: 已请求开回 %@", bundleID)
            }
        }
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
