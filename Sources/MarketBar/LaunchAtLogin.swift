import Foundation
import ServiceManagement

/// 开机自启动。
///
/// 走 `SMAppService.mainApp` —— macOS 13+ 的正规登录项 API（我们的最低版本正好是 13），
/// 不需要额外的 helper bundle，用户也能在「系统设置 → 通用 → 登录项」里自己管。
///
/// ⚠️ 登录项注册是**跟签名绑的**。本项目的包是 ad-hoc 签名，每次重装签名都会变，
/// 所以本地开发时这个开关可能反复失效；从 DMG 正式装一次则不会。
/// 另外 `swift run` 那种没有 bundle 的构建根本注册不了。
@MainActor
struct LaunchAtLogin {
    /// 系统里的真实状态。抽成枚举是为了让「菜单该显示成什么样」可测
    enum State: Equatable {
        /// 没注册过
        case notRegistered
        /// 已启用，会自启
        case enabled
        /// 注册了，但**要用户去系统设置点一下允许**才会生效
        case requiresApproval
        /// 系统找不到这个 app（临时位置运行、或者签名变了）
        case notFound
        /// 拿不到状态（不是 bundle 等）
        case unavailable
    }

    typealias ReadState = @MainActor () -> State
    typealias Toggle = @MainActor () throws -> Void

    var readState: ReadState = LaunchAtLogin.systemState
    var register: Toggle = { try SMAppService.mainApp.register() }
    var unregister: Toggle = { try SMAppService.mainApp.unregister() }

    /// 菜单勾选态：只有 `enabled` 才算真的开着。
    /// 「需要批准」不算 —— 勾上但实际不会自启，比不勾更误导
    var isOn: Bool { readState() == .enabled }

    /// 纯函数：把系统状态映射成我们的枚举（`@unknown default` 兜住将来新增的态）
    static func state(from status: SMAppService.Status) -> State {
        switch status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unavailable
        }
    }

    /// 切换。返回**要跟用户说的话**，nil = 一切正常不用吭声
    func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try register()
            } else {
                try unregister()
            }
        } catch {
            NSLog("MarketBar: 设置开机自启动失败 %@", error.localizedDescription)
            return enabled ? "没能设成开机自启动。" : "没能取消开机自启动。"
        }
        // 注册成功不等于会生效：落到「需要批准」时得让用户去点一下，
        // 不告诉他就会出现「勾了但重启后没起来」这种查不明白的事
        if enabled, readState() == .requiresApproval {
            return "已请求。需要在「系统设置 → 通用 → 登录项」里允许一次。"
        }
        return nil
    }

    /// 首次启动要不要问一句。
    ///
    /// 只在「还没问过」且「本来就没开」时问 —— 已经开了的不用问，
    /// 系统里找不到这个 app 的（比如从临时目录跑）问了也没用
    static func shouldAskFirstTime(asked: Bool, state: State) -> Bool {
        !asked && state == .notRegistered
    }

    static func systemState() -> State {
        // 不是 bundle（swift run）时 mainApp 没有意义，直接当作不可用，
        // 免得弹出一个点了必然失败的提示
        guard Bundle.main.bundleIdentifier != nil else { return .unavailable }
        return state(from: SMAppService.mainApp.status)
    }
}
