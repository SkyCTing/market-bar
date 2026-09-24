import Foundation
import XCTest

@testable import MarketBar

final class ClaudeChatInvocationTests: XCTestCase {
    private let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    func testNewSessionUsesSessionIDFlag() {
        let arguments = ClaudeChatInvocation.arguments(prompt: "你好", sessionID: sessionID, isResume: false)

        XCTAssertEqual(arguments, [
            "-p", "你好", "--session-id", sessionID.uuidString,
            "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--permission-mode", "bypassPermissions",
        ])
    }

    func testResumeUsesResumeFlag() {
        let arguments = ClaudeChatInvocation.arguments(prompt: "继续", sessionID: sessionID, isResume: true)

        XCTAssertEqual(arguments, [
            "-p", "继续", "--resume", sessionID.uuidString,
            "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--permission-mode", "bypassPermissions",
        ])
    }

    /// 用户明确要求：聊天窗里起的会话不弹权限询问。
    /// 这条改动意味着它执行命令/改文件不再征求同意，所以专门钉一条测试，改动时必须是有意的。
    func testInvocationBypassesPermissionPrompts() {
        for isResume in [false, true] {
            let arguments = ClaudeChatInvocation.arguments(prompt: "x", sessionID: sessionID, isResume: isResume)
            let index = arguments.firstIndex(of: "--permission-mode")
            XCTAssertNotNil(index, "resume=\(isResume)")
            XCTAssertEqual(index.map { arguments[$0 + 1] }, "bypassPermissions")
        }
    }

    /// 产品决策：调的是「用户自己的完整 CLI」，绝不裁剪上下文。
    /// 这条测试把决策钉死在代码里，防止以后有人为了省钱偷偷加上这些参数。
    func testInvocationNeverSlimsTheCLI() {
        let arguments = ClaudeChatInvocation.arguments(prompt: "x", sessionID: sessionID, isResume: false)

        for forbidden in ["--tools", "--strict-mcp-config", "--setting-sources", "--system-prompt"] {
            XCTAssertFalse(arguments.contains(forbidden), "不该出现 \(forbidden)")
        }
    }

    /// 登录 shell 的包装：真实命令走位置参数原样传递，任何引号/美元符/反引号都不能被 shell 解析。
    func testShellWrapperPassesCommandThroughPositionalParameters() {
        let spec = ClaudeChatInvocation.spec(
            prompt: "带 \"引号\" 和 $HOME 和 `反引号` 的 $(命令)",
            sessionID: sessionID,
            isResume: false,
            claudePath: URL(fileURLWithPath: "/Users/someone/.local/bin/claude"),
            workingDirectory: URL(fileURLWithPath: "/Users/someone")
        )

        XCTAssertEqual(spec.executable.path, "/bin/zsh")
        XCTAssertEqual(spec.arguments[0], "-lic")            // 必须是交互式：PATH 配在 ~/.zshrc 里
        XCTAssertEqual(spec.arguments[1], ClaudeChatInvocation.shellCommand)
        XCTAssertEqual(spec.arguments[2], "marketbar")       // $0
        XCTAssertEqual(spec.arguments[3], "/Users/someone")  // $1 → cd 的目标
        XCTAssertEqual(spec.arguments[4], "/Users/someone/.local/bin/claude")  // ${@:2} 的第一个

        // 原始消息逐字节保留为一个参数
        XCTAssertTrue(spec.arguments.contains("带 \"引号\" 和 $HOME 和 `反引号` 的 $(命令)"))
        XCTAssertEqual(spec.workingDirectory.path, "/Users/someone")
    }

    func testShellCommandReEstablishesWorkingDirectoryAfterUserRc() {
        // .zshrc 里常常会自己 cd，所以 exec 之前必须重新 cd 一次
        XCTAssertTrue(ClaudeChatInvocation.shellCommand.contains("builtin cd"))
        XCTAssertTrue(ClaudeChatInvocation.shellCommand.contains("exec"))
    }
}

final class ClaudeExecutableResolverTests: XCTestCase {
    func testParsesFirstExistingAbsolutePath() {
        let output = """
        some banner line
        /Users/someone/.local/bin/claude
        """
        let url = ClaudeExecutableResolver.parse(output, isExecutable: { $0 == "/Users/someone/.local/bin/claude" })

        XCTAssertEqual(url?.path, "/Users/someone/.local/bin/claude")
    }

    func testIgnoresNonAbsoluteAndBannerLines() {
        XCTAssertNil(ClaudeExecutableResolver.parse("claude not found"))
        XCTAssertNil(ClaudeExecutableResolver.parse("./relative/claude", isExecutable: { _ in true }))
        XCTAssertNil(ClaudeExecutableResolver.parse("", isExecutable: { _ in true }))
        XCTAssertNil(ClaudeExecutableResolver.parse("/gone/claude", isExecutable: { _ in false }))
    }
}

final class ClaudeChatParserTests: XCTestCase {
    func testParsesCanonicalPayload() throws {
        let data = Data(#"{"result":"你好","session_id":"abc","is_error":false,"total_cost_usd":0.023}"#.utf8)

        let response = try ClaudeChatParser.parse(data)

        XCTAssertEqual(response.result, "你好")
        XCTAssertEqual(response.sessionID, "abc")
        XCTAssertEqual(response.isError, false)
    }

    /// 界面只展示 token 数（不展示钱），所以要正确解出 usage
    func testParsesUsageTokens() throws {
        let data = Data("""
        {"result":"ok","usage":{"input_tokens":336,"output_tokens":2,
         "cache_creation_input_tokens":100,"cache_read_input_tokens":99328}}
        """.utf8)

        let usage = try XCTUnwrap(try ClaudeChatParser.parse(data).usage)

        XCTAssertEqual(usage.inputTokens, 336)
        XCTAssertEqual(usage.outputTokens, 2)
        XCTAssertEqual(usage.cacheCreationInputTokens, 100)
        XCTAssertEqual(usage.totalTokens, 99_766)
    }

    func testUsageToleratesMissingFields() throws {
        let usage = try XCTUnwrap(try ClaudeChatParser.parse(Data(#"{"result":"ok","usage":{}}"#.utf8)).usage)

        XCTAssertEqual(usage.totalTokens, 0)
        XCTAssertNil(usage.inputTokens)
    }

    func testTokenFormatting() {
        XCTAssertEqual(ChatTokenFormat.text(33_435), "33,435 tok")
        XCTAssertEqual(ChatTokenFormat.text(120), "120 tok")
        XCTAssertNil(ChatTokenFormat.text(nil))
        XCTAssertNil(ChatTokenFormat.text(0))
    }

    /// 登录 shell 会跑用户的 .zshrc，任何 echo 都可能排在 JSON 前面
    func testParsesWhenShellBannerPrecedesJSON() throws {
        let data = Data("welcome to zsh\n{\"result\":\"ok\",\"session_id\":\"s\"}\n".utf8)

        let response = try ClaudeChatParser.parse(data)

        XCTAssertEqual(response.result, "ok")
    }

    func testParsesPayloadWithTrailingNoise() throws {
        let data = Data("noise\n{\"result\":\"ok\"}\ntrailing".utf8)

        XCTAssertEqual(try ClaudeChatParser.parse(data).result, "ok")
    }

    func testErrorFlagIsSurfaced() throws {
        let data = Data(#"{"result":"额度不足","is_error":true}"#.utf8)

        let response = try ClaudeChatParser.parse(data)

        XCTAssertEqual(response.isError, true)
        XCTAssertEqual(response.result, "额度不足")
    }

    func testMissingFieldsDecodeAsNil() throws {
        let response = try ClaudeChatParser.parse(Data(#"{"result":"hi"}"#.utf8))

        XCTAssertEqual(response.result, "hi")
        XCTAssertNil(response.sessionID)
        XCTAssertNil(response.totalCostUSD)
        XCTAssertNil(response.isError)
    }

    func testThrowsOnEmptyAndGarbage() {
        XCTAssertThrowsError(try ClaudeChatParser.parse(Data()))
        XCTAssertThrowsError(try ClaudeChatParser.parse(Data("not json at all".utf8)))
    }

    func testDetectsBrokenSessionFromStderr() {
        let output = ClaudeProcessOutput(
            status: 1,
            stdout: Data(),
            stderr: Data("warning\nNo conversation found with session ID: 0000\n".utf8)
        )

        XCTAssertTrue(ClaudeChatParser.indicatesBrokenSession(output))
    }

    func testNormalFailureIsNotTreatedAsBrokenSession() {
        let output = ClaudeProcessOutput(
            status: 1,
            stdout: Data(),
            stderr: Data("network unreachable".utf8)
        )

        XCTAssertFalse(ClaudeChatParser.indicatesBrokenSession(output))
    }
}

final class ClaudeChatSessionStateTests: XCTestCase {
    func testFirstCallStartsANewSessionThenResumes() {
        var state = ClaudeChatSessionState()

        let first = state.begin()
        XCTAssertFalse(first.isResume)

        let second = state.begin()
        XCTAssertTrue(second.isResume)
        XCTAssertEqual(second.id, first.id)
    }

    func testAdoptsReturnedSessionID() {
        var state = ClaudeChatSessionState()
        _ = state.begin()

        let returned = UUID().uuidString
        state.succeeded(returnedID: returned)

        XCTAssertEqual(state.sessionID?.uuidString, returned)
        XCTAssertTrue(state.begin().isResume)
    }

    func testBrokenSessionFallsBackToNewOne() {
        var state = ClaudeChatSessionState()
        _ = state.begin()

        state.sessionBroke()

        XCTAssertNil(state.sessionID)
        XCTAssertFalse(state.begin().isResume)
    }

    func testResetStartsOver() {
        var state = ClaudeChatSessionState()
        _ = state.begin()
        state.reset()

        XCTAssertNil(state.sessionID)
    }

    func testRestoredStateResumesInsteadOfStartingFresh() {
        let existing = UUID()
        var state = ClaudeChatSessionState(sessionID: existing)

        let next = state.begin()

        XCTAssertTrue(next.isResume)
        XCTAssertEqual(next.id, existing)
    }
}

final class ChatTranscriptTests: XCTestCase {
    func testAppendsInOrder() {
        var transcript = ChatTranscript()
        transcript.append(ChatMessage(role: .user, text: "你好"))
        transcript.append(ChatMessage(role: .assistant, text: "在的"))

        XCTAssertEqual(transcript.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(transcript.plainText, "你好\n\n在的")
        XCTAssertFalse(transcript.isEmpty)
    }

    func testTrimsOldestMessagesBeyondLimit() {
        var transcript = ChatTranscript()
        for index in 0..<(ChatTranscript.maximumMessages + 20) {
            transcript.append(ChatMessage(role: .user, text: "m\(index)"))
        }

        XCTAssertEqual(transcript.messages.count, ChatTranscript.maximumMessages)
        XCTAssertEqual(transcript.messages.first?.text, "m20")   // 最旧的被裁掉
        XCTAssertEqual(transcript.messages.last?.text, "m\(ChatTranscript.maximumMessages + 19)")
    }

    func testRemoveAllEmptiesTranscript() {
        var transcript = ChatTranscript()
        transcript.append(ChatMessage(role: .system, text: "—— 新会话 ——"))
        transcript.removeAll()

        XCTAssertTrue(transcript.isEmpty)
        XCTAssertEqual(transcript.plainText, "")
    }
}

/// stream-json（NDJSON）逐行解析。fixture 用的是实测抓到的真实事件形状。
final class ClaudeChatStreamParserTests: XCTestCase {
    private func consume(_ lines: [String]) -> (parser: ClaudeChatStreamParser, events: [ClaudeChatEvent]) {
        var parser = ClaudeChatStreamParser()
        var events: [ClaudeChatEvent] = []
        for line in lines { events += parser.consume(line: line) }
        return (parser, events)
    }

    func testParsesThinkingAndTextDeltas() {
        let result = consume([
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"用户"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"在问好"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"x"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"你好"}}}"#,
        ])

        XCTAssertEqual(result.events, [
            .thinkingDelta("用户"),
            .thinkingDelta("在问好"),
            .textDelta("你好"),
        ])
        XCTAssertTrue(result.parser.didReceiveDeltas)
    }

    func testParsesFinalResultWithUsage() {
        let result = consume([
            #"{"type":"result","result":"你好","session_id":"abc","is_error":false,"usage":{"input_tokens":336,"output_tokens":2}}"#,
        ])

        guard case .finished(let value) = result.events.first else {
            return XCTFail("应当解析出 finished，实际 \(result.events)")
        }
        XCTAssertEqual(value.text, "你好")
        XCTAssertEqual(value.sessionID, "abc")
        XCTAssertEqual(value.isError, false)
        XCTAssertEqual(value.usage?.totalTokens, 338)
    }

    func testIgnoresNoiseAndUnknownEvents() {
        let result = consume([
            "",
            "not json at all",
            #"{"type":"system","subtype":"init","session_id":"s1"}"#,
            #"{"type":"assistant","message":{"content":[]}}"#,
            #"{"type":"stream_event","event":{"type":"message_start"}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_stop","index":0}}"#,
        ])

        XCTAssertEqual(result.events, [.sessionID("s1")])
        XCTAssertFalse(result.parser.didReceiveDeltas)
    }

    /// 没有增量（比如 CLI 没开 partial messages）时，要能退回用 result 里的完整文本
    func testResultTextStillAvailableWithoutDeltas() {
        let result = consume([
            #"{"type":"result","result":"完整回复","session_id":"s","usage":{"output_tokens":7}}"#,
        ])

        guard case .finished(let value) = result.events.first else {
            return XCTFail("应当解析出 finished")
        }
        XCTAssertEqual(value.text, "完整回复")
        XCTAssertEqual(value.usage?.totalTokens, 7)
    }
}

/// 微信未读徽标：状态项标题 → 数字
final class UnreadBadgeTests: XCTestCase {
    func testParsesUnreadCountFromStatusTitle() {
        XCTAssertEqual(UnreadBadge.count(fromStatusTitle: "5"), 5)
        XCTAssertEqual(UnreadBadge.count(fromStatusTitle: " 12 "), 12)
    }

    func testReturnsNilWhenNoUnread() {
        XCTAssertNil(UnreadBadge.count(fromStatusTitle: nil))
        XCTAssertNil(UnreadBadge.count(fromStatusTitle: ""))
        XCTAssertNil(UnreadBadge.count(fromStatusTitle: "0"))        // 0 条 = 不显示
        XCTAssertNil(UnreadBadge.count(fromStatusTitle: "微信"))      // 没有未读时是名字
        XCTAssertNil(UnreadBadge.count(fromStatusTitle: "abc"))
    }
}
