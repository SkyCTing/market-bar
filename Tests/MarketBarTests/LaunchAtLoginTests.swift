import ServiceManagement
import XCTest

@testable import MarketBar

@MainActor
private final class LoginToggleRecorder {
    var registered = 0
    var unregistered = 0
    var state: LaunchAtLogin.State = .notRegistered
    var registerError: Error?
}

@MainActor
final class LaunchAtLoginTests: XCTestCase {
    private func makeLogin(_ recorder: LoginToggleRecorder) -> LaunchAtLogin {
        var login = LaunchAtLogin()
        login.readState = { recorder.state }
        login.register = {
            recorder.registered += 1
            if let error = recorder.registerError { throw error }
        }
        login.unregister = {
            recorder.unregistered += 1
            recorder.state = .notRegistered
        }
        return login
    }

    func testStateMappingCoversEverySystemState() {
        XCTAssertEqual(LaunchAtLogin.state(from: .notRegistered), .notRegistered)
        XCTAssertEqual(LaunchAtLogin.state(from: .enabled), .enabled)
        XCTAssertEqual(LaunchAtLogin.state(from: .requiresApproval), .requiresApproval)
        XCTAssertEqual(LaunchAtLogin.state(from: .notFound), .notFound)
    }

    func testMenuIsOnOnlyWhenActuallyEnabled() {
        let recorder = LoginToggleRecorder()
        let login = makeLogin(recorder)
        for (state, expected) in [
            (LaunchAtLogin.State.enabled, true),
            (.notRegistered, false),
            // 「需要批准」勾上但实际不会自启 —— 显示成开就是骗人
            (.requiresApproval, false),
            (.notFound, false),
            (.unavailable, false),
        ] {
            recorder.state = state
            XCTAssertEqual(login.isOn, expected, "\(state) 时菜单勾选态不对")
        }
    }

    func testEnablingCallsRegisterAndStaysQuietWhenItWorked() {
        let recorder = LoginToggleRecorder()
        let login = makeLogin(recorder)
        recorder.state = .enabled

        XCTAssertNil(login.setEnabled(true), "正常启用不该弹任何东西")
        XCTAssertEqual(recorder.registered, 1)
    }

    func testDisablingCallsUnregister() {
        let recorder = LoginToggleRecorder()
        let login = makeLogin(recorder)
        recorder.state = .enabled

        XCTAssertNil(login.setEnabled(false))
        XCTAssertEqual(recorder.unregistered, 1)
        XCTAssertFalse(login.isOn)
    }

    func testEnablingThatNeedsApprovalTellsTheUserWhereToGo() {
        let recorder = LoginToggleRecorder()
        let login = makeLogin(recorder)
        // 注册成功了，但系统要求用户去点一下才生效
        recorder.state = .requiresApproval

        let message = try? XCTUnwrap(login.setEnabled(true))
        // 不告诉他的话，会出现「勾了但重启没起来」这种查不明白的事
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("登录项") == true, message ?? "")
    }

    func testRegisterFailureIsReportedWithoutThrowing() {
        let recorder = LoginToggleRecorder()
        let login = makeLogin(recorder)
        recorder.registerError = NSError(domain: "test", code: 1)

        XCTAssertNotNil(login.setEnabled(true), "失败要说一声，不能吞")
    }

    func testFirstTimePromptOnlyWhenNeverAskedAndNotRegistered() {
        // 该问：没问过 + 本来就没开
        XCTAssertTrue(LaunchAtLogin.shouldAskFirstTime(asked: false, state: .notRegistered))
        // 问过了就不再烦
        XCTAssertFalse(LaunchAtLogin.shouldAskFirstTime(asked: true, state: .notRegistered))
        // 已经开着的不用问
        XCTAssertFalse(LaunchAtLogin.shouldAskFirstTime(asked: false, state: .enabled))
        // 系统里找不到这个 app（临时目录跑）问了也白问
        XCTAssertFalse(LaunchAtLogin.shouldAskFirstTime(asked: false, state: .notFound))
        XCTAssertFalse(LaunchAtLogin.shouldAskFirstTime(asked: false, state: .unavailable))
        // 等用户去批准的那种也别再问一遍
        XCTAssertFalse(LaunchAtLogin.shouldAskFirstTime(asked: false, state: .requiresApproval))
    }
}
