import Foundation
import XCTest

@testable import MarketBar

final class ChatTranscriptStoreTests: XCTestCase {
    func testRoundTripWritesAndReadsMessages() throws {
        let sessionID = UUID()
        let url = ChatTranscriptStore.fileURL(sessionID: sessionID)
        try? FileManager.default.removeItem(at: url)
        defer { try? FileManager.default.removeItem(at: url) }

        ChatTranscriptStore.append(ChatMessage(role: .user, text: "你好"), sessionID: sessionID)
        ChatTranscriptStore.append(ChatMessage(role: .assistant, text: "在的", tokens: 1234), sessionID: sessionID)

        let loaded = ChatTranscriptStore.load(sessionID: sessionID)

        XCTAssertEqual(loaded.map(\.text), ["你好", "在的"])
        XCTAssertEqual(loaded.last?.tokens, 1234)
        XCTAssertEqual(loaded.map(\.role), [.user, .assistant])
    }

    func testRemoveClearsTheSession() throws {
        let sessionID = UUID()
        defer { ChatTranscriptStore.remove(sessionID: sessionID) }

        ChatTranscriptStore.append(ChatMessage(role: .user, text: "x"), sessionID: sessionID)
        XCTAssertFalse(ChatTranscriptStore.load(sessionID: sessionID).isEmpty)

        ChatTranscriptStore.remove(sessionID: sessionID)
        XCTAssertTrue(ChatTranscriptStore.load(sessionID: sessionID).isEmpty)
    }

    func testParseSkipsGarbageAndKeepsNewest() {
        let good = #"{"role":"user","text":"m1","date":0}"#
        let lines = ["", "not json", good, #"{"role":"assistant","text":"m2","date":0}"#]

        XCTAssertEqual(ChatTranscriptStore.parse(lines: lines).map(\.text), ["m1", "m2"])
        XCTAssertEqual(ChatTranscriptStore.parse(lines: lines, limit: 1).map(\.text), ["m2"])
    }

    func testStoreIsKeyedBySessionID() throws {
        let first = UUID(), second = UUID()
        defer {
            ChatTranscriptStore.remove(sessionID: first)
            ChatTranscriptStore.remove(sessionID: second)
        }

        ChatTranscriptStore.append(ChatMessage(role: .user, text: "A"), sessionID: first)
        ChatTranscriptStore.append(ChatMessage(role: .user, text: "B"), sessionID: second)

        XCTAssertEqual(ChatTranscriptStore.load(sessionID: first).map(\.text), ["A"])
        XCTAssertEqual(ChatTranscriptStore.load(sessionID: second).map(\.text), ["B"])
    }
}
