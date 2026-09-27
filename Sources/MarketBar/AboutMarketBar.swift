import AppKit

enum AboutMarketBar {
    static func versionText(info: [String: Any]) -> String {
        guard let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty else {
            return "开发版本（未打包）"
        }
        if let build = info["CFBundleVersion"] as? String, !build.isEmpty, build != version {
            return "版本：\(version)\n构建：\(build)"
        }
        return "版本：\(version)"
    }

    @MainActor
    static func show() {
        let alert = NSAlert()
        alert.messageText = "关于 MarketBar"
        alert.informativeText = versionText(info: Bundle.main.infoDictionary ?? [:])
            + "\n\n菜单栏行情、持仓与提醒 · 桌面宠物助手"
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
