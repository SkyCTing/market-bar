import Foundation
import XCTest

@testable import MarketBar

final class ClaudeChatHistoryTests: XCTestCase {
    private let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    /// cwd 转义规则：`/` → `-`
    func testSessionFilePath() {
        let file = ClaudeChatHistory.sessionFile(
            sessionID: sessionID,
            workingDirectory: URL(fileURLWithPath: "/Users/someone")
        )
        XCTAssertTrue(file.path.hasSuffix("/.claude/projects/-Users-someone/\(sessionID.uuidString).jsonl"))
    }

    func testParsesUserAndAssistantText() {
        let messages = ClaudeChatHistory.parse(lines: [
            #"{"type":"user","message":{"content":"你好"},"timestamp":"2026-09-24T01:00:00.000Z"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"嗯"},{"type":"text","text":"在的"}]}}"#,
        ])

        XCTAssertEqual(messages.map(\.text), ["你好", "在的"])
        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
    }

    /// 系统提醒、命令回显、工具结果都不是对话内容
    func testSkipsSystemInjectedAndToolMessages() {
        let messages = ClaudeChatHistory.parse(lines: [
            #"{"type":"user","isMeta":true,"message":{"content":"元数据"}}"#,
            #"{"type":"user","message":{"content":"<system-reminder>x</system-reminder>"}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"x"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}"#,
            #"{"type":"user","message":{"content":"真实提问"}}"#,
        ])

        XCTAssertEqual(messages.map(\.text), ["真实提问"])
    }

    func testKeepsNewestWithinLimit() {
        let lines = (1...8).map { #"{"type":"user","message":{"content":"m\#($0)"}}"# }
        XCTAssertEqual(ClaudeChatHistory.parse(lines: lines, limit: 2).map(\.text), ["m7", "m8"])
    }

    func testMissingFileYieldsNothing() {
        XCTAssertTrue(ClaudeChatHistory.messages(from: URL(fileURLWithPath: "/definitely/missing.jsonl")).isEmpty)
    }
}
