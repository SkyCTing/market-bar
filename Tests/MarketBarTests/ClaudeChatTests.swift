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

// MARK: - 图片输入（stream-json）

/// 实测过的契约：`--input-format stream-json` 是给 CLI 送图片的唯一途径
///（`-p` 只收纯文本），而且它**必须**配 `--output-format stream-json`。
final class ClaudeChatImageInputTests: XCTestCase {
    private let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    func testStreamInputKeepsPromptOutOfArguments() {
        let arguments = ClaudeChatInvocation.arguments(
            prompt: "这张图是什么", sessionID: sessionID, isResume: false, usesStreamInput: true
        )

        XCTAssertFalse(arguments.contains("-p"), "stream-json 模式下提示词不走 argv")
        XCTAssertFalse(arguments.contains("这张图是什么"), "提示词走 stdin，不该出现在参数里")
        XCTAssertEqual(arguments.first, "--input-format")
        XCTAssertEqual(arguments.dropFirst().first, "stream-json")
    }

    /// ⚠️ 少了这个 CLI 会直接报错退出（实测：requires output-format=stream-json）
    func testStreamInputKeepsStreamOutput() {
        let arguments = ClaudeChatInvocation.arguments(
            prompt: "x", sessionID: sessionID, isResume: false, usesStreamInput: true
        )

        let index = arguments.firstIndex(of: "--output-format")
        XCTAssertEqual(index.map { arguments[$0 + 1] }, "stream-json")
    }

    /// 默认仍是老的 -p 路径，行为不变
    func testDefaultStillUsesPrintFlag() {
        let arguments = ClaudeChatInvocation.arguments(prompt: "你好", sessionID: sessionID, isResume: false)

        XCTAssertEqual(arguments.first, "-p")
        XCTAssertEqual(arguments.dropFirst().first, "你好")
        XCTAssertFalse(arguments.contains("--input-format"))
    }

    // MARK: 消息编码

    private func decode(_ data: Data?) throws -> [String: Any] {
        let data = try XCTUnwrap(data)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.hasSuffix("\n"), "stdin 要一行一条")
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.dropLast().utf8)) as? [String: Any]
        )
    }

    func testEncodesTextOnly() throws {
        let payload = try decode(ClaudeChatMessage(text: "你好").streamJSONLine())

        XCTAssertEqual(payload["type"] as? String, "user")
        let message = try XCTUnwrap(payload["message"] as? [String: Any])
        let content = try XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[0]["text"] as? String, "你好")
    }

    func testEncodesImageBlock() throws {
        let message = ClaudeChatMessage(
            text: "看看这张",
            images: [ClaudeChatImage(mediaType: "image/png", base64: "AAAA")]
        )

        let payload = try decode(message.streamJSONLine())
        let content = try XCTUnwrap((payload["message"] as? [String: Any])?["content"] as? [[String: Any]])

        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[1]["type"] as? String, "image")
        let source = try XCTUnwrap(content[1]["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, "AAAA")
    }

    /// 只有图没有字也要发得出去
    func testEncodesImageWithoutText() throws {
        let message = ClaudeChatMessage(text: "", images: [ClaudeChatImage(mediaType: "image/jpeg", base64: "BBBB")])

        let content = try XCTUnwrap(
            (try decode(message.streamJSONLine())["message"] as? [String: Any])?["content"] as? [[String: Any]]
        )

        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"] as? String, "image")
    }

    /// 既没字也没图就别发 —— CLI 会把它当成一个空回合
    func testEmptyMessageEncodesToNil() {
        XCTAssertNil(ClaudeChatMessage(text: "").streamJSONLine())
        XCTAssertNil(ClaudeChatMessage(text: "", images: []).streamJSONLine())
    }
}

// MARK: - 图片附件

final class ChatImageAttachmentTests: XCTestCase {
    /// 只缩不放 —— 小图放大只会变糊、还费 token
    func testSmallImagesAreLeftAlone() {
        XCTAssertEqual(
            ChatImageAttachment.fittedSize(CGSize(width: 800, height: 600)),
            CGSize(width: 800, height: 600)
        )
        XCTAssertEqual(
            ChatImageAttachment.fittedSize(CGSize(width: 1568, height: 100)),
            CGSize(width: 1568, height: 100)
        )
    }

    func testLargeImagesAreScaledDownKeepingAspect() {
        let fitted = ChatImageAttachment.fittedSize(CGSize(width: 4000, height: 3000))

        XCTAssertEqual(fitted.width, 1568)
        XCTAssertEqual(fitted.height, 1176, "4:3 要保住")
    }

    /// 竖图按**高**缩，别只看宽
    func testPortraitImagesScaleByHeight() {
        let fitted = ChatImageAttachment.fittedSize(CGSize(width: 1000, height: 4000))

        XCTAssertEqual(fitted.height, 1568)
        XCTAssertEqual(fitted.width, 392)
    }

    func testDegenerateSizeIsSafe() {
        XCTAssertEqual(ChatImageAttachment.fittedSize(.zero), .zero, "不该除零崩掉")
    }

    func testEncodesToPNGBase64() throws {
        // 2×2 的红点图
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))

        let attachment = try XCTUnwrap(ChatImageAttachment.make(from: png))

        XCTAssertEqual(attachment.mediaType, "image/png")
        XCTAssertFalse(attachment.base64.isEmpty)
        XCTAssertNotNil(Data(base64Encoded: attachment.base64), "得是合法 base64")
    }

    func testGarbageDataIsRejected() {
        XCTAssertNil(ChatImageAttachment.make(from: Data("这不是图片".utf8)))
    }

    func testImageFileDetection() {
        XCTAssertTrue(ChatImageAttachment.isImageFile(URL(fileURLWithPath: "/tmp/a.png")))
        XCTAssertTrue(ChatImageAttachment.isImageFile(URL(fileURLWithPath: "/tmp/a.JPG")))
        XCTAssertTrue(ChatImageAttachment.isImageFile(URL(fileURLWithPath: "/tmp/a.heic")))
        XCTAssertFalse(ChatImageAttachment.isImageFile(URL(fileURLWithPath: "/tmp/a.txt")))
        XCTAssertFalse(ChatImageAttachment.isImageFile(URL(fileURLWithPath: "/tmp/a.pdf")))
        XCTAssertFalse(ChatImageAttachment.isImageFile(URL(fileURLWithPath: "/tmp/noext")))
    }

    /// ⚠️ 在 Finder 里拷贝一个图片文件时，粘贴板上**只有文件 URL**，没有图像数据。
    /// 只查 png/tiff 的话这种就漏了，用户看到的是「⌘V 没反应」
    func testReadsImageFromFileURLPasteboard() throws {
        let png = try XCTUnwrap(makeTinyPNG())
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("paste-test-\(UUID().uuidString).png")
        try png.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ChatImageAttachmentTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])

        XCTAssertEqual(try ChatImageAttachment.images(from: pasteboard).count, 1, "文件 URL 也要能取出图")
    }

    /// 拖进来一个 .txt 不该被当成图
    func testNonImageFileOnPasteboardIsIgnored() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("paste-test-\(UUID().uuidString).txt")
        try Data("不是图".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ChatImageAttachmentTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])

        XCTAssertTrue(try ChatImageAttachment.images(from: pasteboard).isEmpty)
    }

    private func makeTinyPNG() -> Data? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
        return rep?.representation(using: .png, properties: [:])
    }
}

/// 有图才切到 stream-json 输入：`-p` 只收纯文本
final class ClaudeChatImageSpecTests: XCTestCase {
    private let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let executable = URL(fileURLWithPath: "/usr/local/bin/claude")
    private let cwd = URL(fileURLWithPath: "/tmp")

    private func spec(_ message: ClaudeChatMessage) -> ClaudeProcessSpec {
        ClaudeChatInvocation.spec(
            message: message, sessionID: sessionID, isResume: false,
            claudePath: executable, workingDirectory: cwd
        )
    }

    func testTextOnlyKeepsThePrintFlag() {
        let spec = spec(ClaudeChatMessage(text: "你好"))

        XCTAssertTrue(spec.arguments.contains("-p"))
        XCTAssertNil(spec.stdin, "没有图就还是走 -p，stdin 接 /dev/null")
    }

    func testImagesSwitchToStreamInput() throws {
        let spec = spec(ClaudeChatMessage(
            text: "看看这张",
            images: [ClaudeChatImage(mediaType: "image/png", base64: "AAAA")]
        ))

        XCTAssertFalse(spec.arguments.contains("-p"), "有图就不能走 -p")
        // 参数前面还有登录 shell 的包装（-lic 等），所以判断「在不在」而不是「是不是第一个」
        XCTAssertTrue(spec.arguments.contains("--input-format"))

        let stdin = try XCTUnwrap(spec.stdin, "提示词和图都要从 stdin 进去")
        let line = try XCTUnwrap(String(data: stdin, encoding: .utf8))
        XCTAssertTrue(line.contains("\"image\""))
        XCTAssertTrue(line.contains("AAAA"))
    }
}
