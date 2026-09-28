import Foundation

/// Keep SQLite writes off the UI actor and serialize them through the store actor.
@MainActor
final class GoldHistoryRecorder {
    typealias Fetch = @Sendable (GoldProvider) async -> PriceInfo
    private let fetch: Fetch
    private var store: GoldHistoryStore?
    private var otherProviderTask: Task<Void, Never>?
    private var lastAttemptedOtherMinute: Int64?
    private var lastAttemptedCurrentMinute: [GoldProvider: Int64] = [:]
    private(set) var lastError: String?

    init(fetch: @escaping Fetch, store: GoldHistoryStore? = nil) {
        self.fetch = fetch
        if let store {
            self.store = store
            return
        }
        do {
            self.store = try GoldHistoryStore()
        } catch {
            report(error)
        }
    }

    func recordCurrent(_ provider: GoldProvider, price: Double, at date: Date) {
        guard price.isFinite, price > 0, date.timeIntervalSince1970.isFinite,
              date.timeIntervalSince1970 >= 0, let store else { return }
        let minute = Int64(date.timeIntervalSince1970 / 60)
        guard lastAttemptedCurrentMinute[provider] != minute else { return }
        lastAttemptedCurrentMinute[provider] = minute
        Task {
            do {
                try await store.record(provider: provider, price: price, at: date)
            } catch {
                report(error)
            }
        }
    }

    func sampleOther(than selected: GoldProvider, at date: Date) {
        guard let store, otherProviderTask == nil, date.timeIntervalSince1970.isFinite,
              date.timeIntervalSince1970 >= 0 else { return }
        let minute = Int64(date.timeIntervalSince1970 / 60)
        guard lastAttemptedOtherMinute != minute else { return }
        lastAttemptedOtherMinute = minute
        let other: GoldProvider = selected == .zheShang ? .minSheng : .zheShang
        otherProviderTask = Task { [weak self] in
            guard let self else { return }
            defer { otherProviderTask = nil }
            let info = await fetch(other)
            guard !Task.isCancelled, info.price.isFinite, info.price > 0 else { return }
            do {
                try await store.record(provider: other, price: info.price, at: Date())
            } catch {
                report(error)
            }
        }
    }

    func stop() {
        otherProviderTask?.cancel()
        otherProviderTask = nil
    }

    func summaries() async throws -> [(provider: GoldProvider, count: Int64, first: Date?, last: Date?)] {
        guard let store else {
            throw GoldHistoryError.database(lastError ?? "数据库尚未建立")
        }
        var result: [(GoldProvider, Int64, Date?, Date?)] = []
        for provider in GoldProvider.allCases {
            let data = try await store.summary(for: provider)
            result.append((provider, data.count, data.first, data.last))
        }
        return result
    }

    private func report(_ error: Error) {
        lastError = error.localizedDescription
        NSLog("MarketBar: gold history storage failed: %@", error.localizedDescription)
    }
}
