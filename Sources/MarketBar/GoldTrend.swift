import Foundation

enum GoldTrendRange: Int, CaseIterable {
    case day, week, month, threeMonths, custom

    var title: String {
        switch self {
        case .day: "1 天"
        case .week: "1 周"
        case .month: "1 个月"
        case .threeMonths: "3 个月"
        case .custom: "自选"
        }
    }

    func dates(now: Date, calendar: Calendar = .current, customStart: Date? = nil, customEnd: Date? = nil) throws -> (Date, Date) {
        if self == .custom {
            guard let customStart, let customEnd, customStart <= customEnd,
                  customEnd.timeIntervalSince(customStart) <= 366 * 86_400 else {
                throw GoldHistoryError.invalidRange
            }
            return (customStart, customEnd)
        }
        let component: Calendar.Component
        let amount: Int
        switch self {
        case .day: (component, amount) = (.day, -1)
        case .week: (component, amount) = (.day, -7)
        case .month: (component, amount) = (.month, -1)
        case .threeMonths: (component, amount) = (.month, -3)
        case .custom: preconditionFailure("Handled above")
        }
        guard let start = calendar.date(byAdding: component, value: amount, to: now) else {
            throw GoldHistoryError.invalidRange
        }
        return (start, now)
    }
}

struct GoldTrend {
    let provider: GoldProvider
    let start: Date
    let end: Date
    let samples: [GoldHistorySample]

    init(provider: GoldProvider, start: Date, end: Date, samples: [GoldHistorySample]) {
        self.provider = provider
        self.start = start
        self.end = end
        self.samples = samples
    }

    var high: GoldHistorySample? { samples.max { $0.price < $1.price } }
    var low: GoldHistorySample? { samples.min { $0.price < $1.price } }
    var first: GoldHistorySample? { samples.first }
    var last: GoldHistorySample? { samples.last }

    /// One captured point per minute; don't connect through offline periods or API failures.
    static func joins(_ earlier: GoldHistorySample, _ later: GoldHistorySample) -> Bool {
        let firstMinute = Int64(earlier.sampledAt.timeIntervalSince1970 / 60)
        let secondMinute = Int64(later.sampledAt.timeIntervalSince1970 / 60)
        return secondMinute - firstMinute == 1
    }

    /// Bound drawing complexity while keeping every gap endpoint and every bucket's extrema.
    func drawingSamples(buckets: Int = 500) -> [GoldHistorySample] {
        drawingIndices(buckets: buckets).map { samples[$0] }
    }

    func drawingSegments(buckets: Int = 500) -> [[GoldHistorySample]] {
        guard !samples.isEmpty else { return [] }
        let indices = Set(drawingIndices(buckets: buckets))
        var segments: [[GoldHistorySample]] = []
        var segment: [GoldHistorySample] = []
        for index in samples.indices {
            if index > 0, !Self.joins(samples[index - 1], samples[index]) {
                if !segment.isEmpty { segments.append(segment) }
                segment = []
            }
            if indices.contains(index) { segment.append(samples[index]) }
        }
        if !segment.isEmpty { segments.append(segment) }
        return segments
    }

    private func drawingIndices(buckets: Int) -> [Int] {
        guard buckets > 0, samples.count > buckets * 4 else { return Array(samples.indices) }
        let duration = end.timeIntervalSince(start)
        guard duration > 0 else { return Array(samples.indices) }
        func bucket(for sample: GoldHistorySample) -> Int {
            min(buckets - 1, max(0, Int(
                (sample.sampledAt.timeIntervalSince(start) / duration * Double(buckets)).rounded(.down)
            )))
        }
        var keep: Set<Int> = [0, samples.count - 1]
        var previousBucket = -1
        var first = 0
        var high = 0
        var low = 0
        for index in samples.indices {
            let currentBucket = bucket(for: samples[index])
            if previousBucket != currentBucket {
                if previousBucket >= 0 {
                    keep.formUnion([first, high, low, index - 1])
                }
                previousBucket = currentBucket
                first = index
                high = index
                low = index
            } else {
                if samples[index].price > samples[high].price { high = index }
                if samples[index].price < samples[low].price { low = index }
            }
            if index > 0, !Self.joins(samples[index - 1], samples[index]),
               bucket(for: samples[index - 1]) != currentBucket {
                keep.insert(index - 1)
                keep.insert(index)
            }
        }
        keep.formUnion([first, high, low])
        return keep.sorted()
    }

    func nearest(to date: Date) -> GoldHistorySample? {
        guard !samples.isEmpty else { return nil }
        var low = 0
        var high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].sampledAt < date { low = mid + 1 }
            else { high = mid }
        }
        if low == 0 { return samples[0] }
        if low == samples.count { return samples[low - 1] }
        let before = samples[low - 1]
        let after = samples[low]
        return date.timeIntervalSince(before.sampledAt) <= after.sampledAt.timeIntervalSince(date)
            ? before : after
    }
}
