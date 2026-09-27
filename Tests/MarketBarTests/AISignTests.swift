import Foundation
import XCTest

@testable import MarketBar

private actor SignHTTPStub {
    private var responses: [(Int, Data)]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [(Int, Data)]) { self.responses = responses }

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw AISignError.message("Unexpected request") }
        let (status, data) = responses.removeFirst()
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private func signResponse(line: String = "记得起来走走", indices: [Int] = [], finish: String = "stop") throws -> Data {
    let inner = try JSONSerialization.data(withJSONObject: [
        "line": line, "detail": "长时间工作后适当活动，注意劳逸结合。", "sourceIndices": indices,
    ])
    return try JSONSerialization.data(withJSONObject: [
        "choices": [["message": ["content": String(decoding: inner, as: UTF8.self)], "finish_reason": finish]],
    ])
}

final class AISignServiceTests: XCTestCase {
    func testNonSearchRequestUsesOnlyDeepSeekAndDoesNotPersistSecrets() async throws {
        let stub = SignHTTPStub([(200, try signResponse())])
        let service = AISignService(transport: { try await stub.send($0) })
        let settings = AISignSettings(enabled: true, topic: "程序员休息建议")
        let result = try await service.generate(
            settings: settings, deepSeekKey: "test-deepseek", searchKey: nil, at: Date()
        )
        XCTAssertEqual(result.line, "记得起来走走")
        XCTAssertFalse(result.searched)
        XCTAssertTrue(result.sources.isEmpty)
        let requests = await stub.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-deepseek")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "deepseek-flash")
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("test-deepseek"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(settings), as: UTF8.self).contains("test-deepseek"))
    }

    func testSearchThenSummarizeUsesActualSearchCitations() async throws {
        let search = Data("""
        {"results":[
          {"title":"源码更新","url":"https://example.com/news","content":"项目发布了一项更新。"},
          {"title":"另一个来源","url":"https://example.org/news","content":"另一份报道。"}
        ]}
        """.utf8)
        let stub = SignHTTPStub([(200, search), (200, try signResponse(line: "看看技术新动态", indices: [2, 2]))])
        let result = try await AISignService(transport: { try await stub.send($0) }).generate(
            settings: AISignSettings(enabled: true, usesWebSearch: true),
            deepSeekKey: "test-deepseek", searchKey: "test-search", at: Date()
        )
        XCTAssertTrue(result.searched)
        XCTAssertEqual(result.sources.map(\.url.absoluteString), ["https://example.org/news"])
        let requests = await stub.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://api.tavily.com/search")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer test-search")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer test-deepseek")
        let prompt = String(decoding: try XCTUnwrap(requests[1].httpBody), as: UTF8.self)
        XCTAssertTrue(prompt.contains("项目发布了一项更新"))
        XCTAssertFalse(prompt.contains("test-search"))
    }

    func testFailedSearchDoesNotFallBackToInventedNews() async throws {
        for response in [(429, Data("private error content".utf8)), (200, Data(#"{"results":[]}"#.utf8))] {
            let stub = SignHTTPStub([response])
            do {
                _ = try await AISignService(transport: { try await stub.send($0) }).generate(
                    settings: AISignSettings(enabled: true, usesWebSearch: true),
                    deepSeekKey: "test-deepseek", searchKey: "test-search", at: Date()
                )
                XCTFail("Search failure must be surfaced")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("private error content"))
            }
            let requests = await stub.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testSearchRejectsUnsafeLinksAndUncitedOutput() async throws {
        let valid = Data(#"{"results":[{"title":"新闻","url":"https://example.com","content":"内容"}]}"#.utf8)
        let invalid = Data(#"{"results":[{"title":"新闻","url":"javascript:alert(1)","content":"内容"}]}"#.utf8)
        for search in [valid, invalid] {
            let stub = SignHTTPStub([(200, search), (200, try signResponse())])
            do {
                _ = try await AISignService(transport: { try await stub.send($0) }).generate(
                    settings: AISignSettings(enabled: true, usesWebSearch: true),
                    deepSeekKey: "test", searchKey: "search-test", at: Date()
                )
                XCTFail("News requires usable source links and citations")
            } catch { XCTAssertTrue(error is AISignError) }
        }
    }

    func testRejectsEmptyLongTruncatedAndInvalidCitationResponses() async throws {
        for data in [
            try signResponse(line: ""),
            try signResponse(line: "这是一个超过八个字的超长句子"),
            try signResponse(line: "第一行\n第二行"),
            try signResponse(indices: [Int.min]),
            try signResponse(indices: [1]),
            try signResponse(finish: "length"),
            Data("not JSON".utf8),
        ] {
            let service = AISignService(transport: { request in
                (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            do {
                _ = try await service.generate(
                    settings: AISignSettings(), deepSeekKey: "test", searchKey: nil, at: Date()
                )
                XCTFail("Malformed content must not reach the sign")
            } catch { XCTAssertTrue(error is AISignError) }
        }
    }

    func testMissingKeyAndInvalidSettingsMakeNoRequests() async throws {
        let stub = SignHTTPStub([])
        let service = AISignService(transport: { try await stub.send($0) })
        for settings in [
            AISignSettings(enabled: true),
            AISignSettings(enabled: true, usesWebSearch: true),
            AISignSettings(enabled: true, model: "bad model"),
        ] {
            do {
                _ = try await service.generate(
                    settings: settings, deepSeekKey: settings.usesWebSearch ? "test" : "", searchKey: nil, at: Date()
                )
                XCTFail("Invalid setup must fail")
            } catch { XCTAssertTrue(error is AISignError) }
        }
        let requests = await stub.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testContentExpiresAfterTwoHoursAndRejectsFutureClock() {
        let now = Date()
        let content = AISignContent(line: "起来走走", detail: "休息一下", sources: [], generatedAt: now, searched: false)
        XCTAssertEqual(content.lines(at: now)?.headline, "AI·灵感")
        XCTAssertNotNil(content.lines(at: now.addingTimeInterval(7_199)))
        XCTAssertNil(content.lines(at: now.addingTimeInterval(7_200)))
        XCTAssertNil(content.lines(at: now.addingTimeInterval(-1)))
    }

    func testKeychainRoundTripUsesOnlyIsolatedTestService() throws {
        let keys = KeychainAIKeyStore(service: "com.marketbar.tests.\(UUID().uuidString)")
        defer {
            do { try keys.save("", account: "test") }
            catch { XCTFail("Failed to clean up test key: \(error)") }
        }
        XCTAssertNil(try keys.read("test"))
        try keys.save("dummy-test-key", account: "test")
        XCTAssertEqual(try keys.read("test"), "dummy-test-key")
        try keys.save("updated-test-key", account: "test")
        XCTAssertEqual(try keys.read("test"), "updated-test-key")
        try keys.save("", account: "test")
        XCTAssertNil(try keys.read("test"))
    }
}

private final class SignMemoryKeys: AIKeyStore {
    var values: [String: String] = [:]
    func read(_ account: String) throws -> String? { values[account] }
    func save(_ value: String, account: String) throws { values[account] = value }
}

@MainActor
final class AISignControllerTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var keys: SignMemoryKeys!

    override func setUp() async throws {
        suite = "AISignControllerTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        keys = SignMemoryKeys()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        keys = nil
    }

    func testOptInVisibilityCooldownAndTradingDayPriority() async throws {
        let stub = SignHTTPStub([(200, try signResponse()), (200, try signResponse())])
        let controller = AISignController(defaults: defaults, keys: keys, service: AISignService(transport: {
            try await stub.send($0)
        }))
        let now = Date()
        controller.refreshIfNeeded(at: now, canDisplay: true)
        XCTAssertFalse(controller.settings.enabled)
        try controller.save(AISignSettings(enabled: true), deepSeekKey: "test-key", searchKey: "")
        XCTAssertEqual(keys.values["deepseek"], "test-key")
        let persisted = try XCTUnwrap(defaults.data(forKey: AISignController.settingsKey))
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains("test-key"))
        controller.refreshIfNeeded(at: now, canDisplay: false)
        var requests = await stub.requests
        XCTAssertTrue(requests.isEmpty)
        let finished = expectation(description: "generated")
        controller.onChange = { if controller.content != nil { finished.fulfill() } }
        controller.refreshIfNeeded(at: now, canDisplay: true)
        await fulfillment(of: [finished], timeout: 2)
        controller.onChange = nil
        XCTAssertNil(controller.lastError)
        XCTAssertNotNil(controller.lines(at: now, isTradingDay: false))
        XCTAssertNil(controller.lines(at: now, isTradingDay: true))
        controller.refreshIfNeeded(at: now.addingTimeInterval(1_799), canDisplay: true)
        requests = await stub.requests
        XCTAssertEqual(requests.count, 1)
        let updated = expectation(description: "updated after 30 minutes")
        controller.onChange = {
            if controller.content?.generatedAt == now.addingTimeInterval(1_800) { updated.fulfill() }
        }
        controller.refreshIfNeeded(at: now.addingTimeInterval(1_800), canDisplay: true)
        await fulfillment(of: [updated], timeout: 2)
        controller.onChange = nil
        requests = await stub.requests
        XCTAssertEqual(requests.count, 2)
        try controller.save(AISignSettings(enabled: false), deepSeekKey: "", searchKey: "")
        XCTAssertNil(controller.content)
        XCTAssertNil(controller.lines(at: now, isTradingDay: false))
        XCTAssertEqual(keys.values["deepseek"], "test-key", "Blank input keeps an existing key")
    }

    func testSettingsChangeCancelsOldResult() async throws {
        let response = try signResponse()
        let started = expectation(description: "started")
        let controller = AISignController(defaults: defaults, keys: keys, service: AISignService(transport: {
            request in
            started.fulfill()
            try await Task.sleep(for: .milliseconds(200))
            return (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }))
        try controller.save(AISignSettings(enabled: true), deepSeekKey: "test-key", searchKey: "")
        controller.refreshIfNeeded(canDisplay: true)
        await fulfillment(of: [started], timeout: 2)
        try controller.save(AISignSettings(enabled: false), deepSeekKey: "", searchKey: "")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(controller.content)
        XCTAssertNil(controller.lastError)
        XCTAssertEqual(controller.status, "未启用")
    }

    func testErrorIsVisibleAndAutomaticRetriesAreThrottled() async throws {
        let stub = SignHTTPStub([(401, Data())])
        let controller = AISignController(defaults: defaults, keys: keys, service: AISignService(transport: {
            try await stub.send($0)
        }))
        try controller.save(AISignSettings(enabled: true), deepSeekKey: "test-key", searchKey: "")
        let failed = expectation(description: "failed")
        controller.onChange = { if controller.lastError != nil { failed.fulfill() } }
        let now = Date()
        controller.refreshIfNeeded(at: now, canDisplay: true)
        await fulfillment(of: [failed], timeout: 2)
        controller.onChange = nil
        XCTAssertTrue(controller.status.contains("401"))
        XCTAssertNil(controller.content)
        controller.refreshIfNeeded(at: now.addingTimeInterval(1), canDisplay: true)
        let requests = await stub.requests
        XCTAssertEqual(requests.count, 1)
    }
}
