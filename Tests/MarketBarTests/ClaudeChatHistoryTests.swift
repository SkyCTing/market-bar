import Foundation
import XCTest

@testable import MarketBar

final class ClaudeChatHistoryTests: XCTestCase {
    private let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    /// cwd 转义规则：`/` 和 `.` 都换成 `-`。
    /// 少换 `.` 会让路径指向不存在的目录（`-Users-sky.ding` vs `-Users-sky-ding`），
    /// 表现成 ENOENT —— 之前排查了很久就是这个。
    func testSlugReplacesDotsAsWellAsSlashes() {
        XCTAssertEqual(
            ClaudeChatHistory.slug(for: URL(fileURLWithPath: "/Users/sky.ding")),
            "-Users-sky-ding"
        )
        XCTAssertEqual(
            ClaudeChatHistory.slug(for: URL(fileURLWithPath: "/Users/someone")),
            "-Users-someone"
        )
        XCTAssertEqual(
            ClaudeChatHistory.slug(for: URL(fileURLWithPath: "/tmp/a.b/c")),
            "-tmp-a-b-c"
        )
    }

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
