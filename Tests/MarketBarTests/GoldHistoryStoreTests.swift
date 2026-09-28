import XCTest
@testable import MarketBar

final class GoldHistoryStoreTests: XCTestCase {
    private func withStore(_ check: (GoldHistoryStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoldHistoryTests-\(UUID())", isDirectory: true)
        let url = directory.appendingPathComponent("gold-history.sqlite")
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Failed to remove isolated test database: \(error)") }
        }
        let store = try GoldHistoryStore(url: url)
        try await check(store, url)
    }

    func testBanksStaySeparateAndOneMinuteKeepsFirstValidSample() async throws {
        try await withStore { store, _ in
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let initial = try await store.record(provider: .zheShang, price: 1_020.75, at: start)
            let duplicate = try await store.record(provider: .zheShang, price: 9_999, at: start.addingTimeInterval(35))
            let other = try await store.record(provider: .minSheng, price: 1_018.25, at: start.addingTimeInterval(35))
            let next = try await store.record(provider: .zheShang, price: 1_021, at: start.addingTimeInterval(60))
            XCTAssertTrue(initial)
            XCTAssertFalse(duplicate)
            XCTAssertTrue(other)
            XCTAssertTrue(next)
            let end = start.addingTimeInterval(100)
            let zhe = try await store.samples(provider: .zheShang, since: start, until: end)
            let min = try await store.samples(provider: .minSheng, since: start, until: end)
            XCTAssertEqual(zhe.map(\.price), [1_020.75, 1_021])
            XCTAssertEqual(min.map(\.price), [1_018.25])
            XCTAssertEqual(zhe.map(\.provider), [.zheShang, .zheShang])
            XCTAssertEqual(min.map(\.provider), [.minSheng])
            let lateOnly = try await store.samples(
                provider: .minSheng, since: start.addingTimeInterval(36), until: end
            )
            XCTAssertTrue(lateOnly.isEmpty, "Minute index must still respect exact acquisition time")
            let zheCount = try await store.summary(for: .zheShang).count
            let minCount = try await store.summary(for: .minSheng).count
            XCTAssertEqual(zheCount, 2)
            XCTAssertEqual(minCount, 1)
        }
    }

    func testRestartPreservesHistoryAndMissingMinutesStayMissing() async throws {
        try await withStore { store, url in
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            try await store.record(provider: .minSheng, price: 1_015, at: start)
            try await store.record(provider: .minSheng, price: 1_019, at: start.addingTimeInterval(24 * 3_600))
            let reopened = try GoldHistoryStore(url: url)
            let week = try await reopened.samples(
                provider: .minSheng, since: start.addingTimeInterval(-7 * 86_400),
                until: start.addingTimeInterval(7 * 86_400)
            )
            XCTAssertEqual(week.map(\.price), [1_015, 1_019], "No fabricated points for gaps")
            let empty = try await reopened.samples(provider: .zheShang, since: start, until: start.addingTimeInterval(86_400))
            let inserted = try await reopened.record(provider: .zheShang, price: 1_017, at: start)
            XCTAssertTrue(empty.isEmpty)
            XCTAssertTrue(inserted)
        }
    }

    func testRejectsInvalidPriceAndRangeWithoutWriting() async throws {
        try await withStore { store, _ in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            for price in [0, -1, .nan, .infinity] {
                do {
                    try await store.record(provider: .zheShang, price: price, at: now)
                    XCTFail("Invalid price was accepted")
                } catch GoldHistoryError.invalidSample {}
            }
            do {
                _ = try await store.samples(provider: .zheShang, since: now, until: now.addingTimeInterval(-1))
                XCTFail("Reversed range was accepted")
            } catch GoldHistoryError.invalidRange {}
            let count = try await store.summary(for: .zheShang).count
            XCTAssertEqual(count, 0)
        }
    }
}

@MainActor
final class GoldHistoryRecorderTests: XCTestCase {
    func testInactiveBankIsFetchedOncePerMinuteAndInvalidPricesAreIgnored() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoldRecorderTests-\(UUID())", isDirectory: true)
        let store = try GoldHistoryStore(url: directory.appendingPathComponent("gold-history.sqlite"))
        let calls = LockedProviders()
        let recorder = GoldHistoryRecorder(fetch: { provider in
            await calls.record(provider)
            return PriceInfo(price: 999, changeAmount: "0", changePercent: "0%", isNegative: nil)
        }, store: store)
        defer {
            recorder.stop()
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Failed to remove isolated test data: \(error)") }
        }
        let date = Date()
        recorder.recordCurrent(.zheShang, price: 1_021, at: date)
        recorder.recordCurrent(.zheShang, price: 0, at: date)
        recorder.sampleOther(than: .zheShang, at: date)
        recorder.sampleOther(than: .zheShang, at: date)
        for _ in 0..<40 {
            if (try await store.summary(for: .minSheng)).count > 0 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let providers = await calls.providers
        let zheCount = try await store.summary(for: .zheShang).count
        let minCount = try await store.summary(for: .minSheng).count
        XCTAssertEqual(providers, [.minSheng])
        XCTAssertEqual(zheCount, 1)
        XCTAssertEqual(minCount, 1)
        let summary = try await recorder.summaries()
        XCTAssertEqual(summary.map(\.provider), [.zheShang, .minSheng])
        XCTAssertEqual(summary.map(\.count), [1, 1])
    }
}

private actor LockedProviders {
    private(set) var providers: [GoldProvider] = []
    func record(_ provider: GoldProvider) { providers.append(provider) }
}
