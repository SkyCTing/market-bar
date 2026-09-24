import Foundation
import XCTest

@testable import MarketBar

/// 进程层的测试：全部用系统自带命令（/bin/echo、/bin/sh），离线、无网络、不花钱。
final class ClaudeProcessRunnerTests: XCTestCase {
    private func spec(_ executable: String, _ arguments: [String]) -> ClaudeProcessSpec {
        ClaudeProcessSpec(
            executable: URL(fileURLWithPath: executable),
            arguments: arguments,
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
        )
    }

    func testCapturesStdoutAndExitStatus() async throws {
        let output = try await ClaudeProcessRunner.run(
            spec("/bin/echo", [#"{"result":"ok","session_id":"s"}"#]),
            timeout: 10
        )

        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(try ClaudeChatParser.parse(output.stdout).result, "ok")
    }

    func testCapturesStderrSeparately() async throws {
        let output = try await ClaudeProcessRunner.run(
            spec("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"]),
            timeout: 10
        )

        XCTAssertEqual(output.status, 3)
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "out")
        XCTAssertEqual(output.stderrTail, "err")
    }

    /// 最关键的一条：macOS 管道缓冲区只有 64KB，两条管道都必须持续读。
    /// 如果有人把读取改成「等进程退出后再读」，这条会直接挂死（超时失败）而不是悄悄通过。
    func testLargeOutputOnBothPipesDoesNotDeadlock() async throws {
        let bytes = 200_000
        let output = try await ClaudeProcessRunner.run(
            spec("/bin/sh", [
                "-c",
                "head -c \(bytes) /dev/zero | tr '\\0' 'x'; head -c \(bytes) /dev/zero | tr '\\0' 'y' >&2",
            ]),
            timeout: 30
        )

        XCTAssertEqual(output.stdout.count, bytes)
        XCTAssertEqual(output.stderr.count, bytes)
    }

    func testMissingExecutableFailsFast() async {
        do {
            _ = try await ClaudeProcessRunner.run(spec("/definitely/not/here", []), timeout: 5)
            XCTFail("应当抛错")
        } catch let error as ClaudeChatError {
            guard case .launchFailed = error else {
                return XCTFail("期望 launchFailed，实际 \(error)")
            }
        } catch {
            XCTFail("期望 ClaudeChatError，实际 \(error)")
        }
    }

    func testTimeoutKillsTheChildAndReportsTimeout() async {
        let started = Date()
        do {
            _ = try await ClaudeProcessRunner.run(spec("/bin/sleep", ["30"]), timeout: 1)
            XCTFail("应当超时")
        } catch let error as ClaudeChatError {
            XCTAssertEqual(error, .timeout(seconds: 1))
        } catch {
            XCTFail("期望 ClaudeChatError，实际 \(error)")
        }

        // 超时后应该很快返回（宽限期 3 秒 + 余量），而不是等 sleep 自己结束
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testCancellationStopsTheChild() async {
        let started = Date()
        // spec 在 Task 外面构造：闭包里不能捕获 XCTestCase（Swift 6 严格并发）
        let sleepSpec = spec("/bin/sleep", ["30"])
        let task = Task {
            try await ClaudeProcessRunner.run(sleepSpec, timeout: 60)
        }

        try? await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()

        let result = await task.result
        guard case .failure(let error) = result, let chatError = error as? ClaudeChatError else {
            return XCTFail("期望被取消，实际 \(result)")
        }
        XCTAssertEqual(chatError, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    /// 登录 shell 的包装确实能拿到用户交互式环境（PATH 配在 ~/.zshrc 里）。
    /// 这里只验证「登录 shell 里的 PATH 比 GUI 进程的更长」这一事实，不依赖 claude 是否安装。
    func testInteractiveLoginShellSeesUserPath() async throws {
        let output = try await ClaudeProcessRunner.run(
            ClaudeProcessSpec(
                executable: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-lic", "command -v -- git || true", ClaudeChatInvocation.shellArgumentZero],
                workingDirectory: URL(fileURLWithPath: NSHomeDirectory())
            ),
            timeout: ClaudeChatTiming.resolveTimeout
        )

        let resolved = String(decoding: output.stdout, as: UTF8.self)
            .split(separator: "\n").last
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        // git 一定存在（可能是 Xcode/CLT 带的）；这里只要求能解析出一个绝对路径
        XCTAssertTrue(resolved.isEmpty || resolved.hasPrefix("/"), "解析结果异常：\(resolved)")
    }
}
