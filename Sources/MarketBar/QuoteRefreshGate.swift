import Foundation

/// A refresh owns its slot until all child requests finish, even when its data is invalidated.
struct QuoteRefreshGate {
    private var generation = UUID()
    private var active: UUID?

    mutating func begin() -> UUID? {
        guard active == nil else { return nil }
        active = generation
        return generation
    }

    mutating func invalidate() {
        generation = UUID()
    }

    func accepts(_ token: UUID) -> Bool {
        active == token && generation == token
    }

    /// Returns whether an invalidated request should be followed by a fresh request.
    mutating func finish(_ token: UUID) -> Bool {
        guard active == token else { return false }
        active = nil
        return generation != token
    }
}
