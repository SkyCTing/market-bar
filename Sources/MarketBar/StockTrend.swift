import Foundation

enum StockTrendRange: Int, CaseIterable, Sendable {
    case today, fiveDays, month

    var title: String {
        switch self {
        case .today: "当日"
        case .fiveDays: "近5日"
        case .month: "近1月"
        }
    }

    var isDailyClose: Bool { self == .month }
    var cacheSeconds: TimeInterval { self == .today ? 60 : 600 }
}

struct StockTrendPoint: Equatable, Sendable {
    let date: Date
    let price: Double
}

struct StockTrend: Sendable {
    let code: String
    let market: StockMarket
    let range: StockTrendRange
    let points: [StockTrendPoint]

    var high: StockTrendPoint? { points.max { $0.price < $1.price } }
    var low: StockTrendPoint? { points.min { $0.price < $1.price } }
    var latest: StockTrendPoint? { points.last }

    private var tradingAxis: (slots: [Int], total: Int)? {
        var rankByDate: [String: Int] = [:]
        var slots: [Int] = []
        for point in points {
            let day = market.dateString(for: point.date)
            if rankByDate[day] == nil { rankByDate[day] = rankByDate.count }
            guard let minute = market.regularSessionMinuteIndex(at: point.date),
                  let rank = rankByDate[day] else { return nil }
            slots.append(rank * market.regularSessionMinuteCount + minute)
        }
        return (slots, max(1, rankByDate.count * market.regularSessionMinuteCount - 1))
    }

    /// Position on the *trading* timeline: skip lunch, nights and non-trading days.
    /// A gap during an open session still occupies its missing minute slots.
    var plotFractions: [Double] {
        guard !points.isEmpty else { return [] }
        if range.isDailyClose {
            return points.indices.map { Double($0) / Double(max(1, points.count - 1)) }
        }
        guard let tradingAxis else { return [] }
        return tradingAxis.slots.map { Double($0) / Double(tradingAxis.total) }
    }

    var segments: [[StockTrendPoint]] {
        guard !points.isEmpty else { return [] }
        if range.isDailyClose { return [points] }
        guard let tradingAxis else { return points.map { [$0] } }
        var result: [[StockTrendPoint]] = []
        var segment: [StockTrendPoint] = [points[0]]
        for index in points.indices.dropFirst() {
            let current = points[index]
            if tradingAxis.slots[index] - tradingAxis.slots[index - 1] != 1 {
                result.append(segment)
                segment = []
            }
            segment.append(current)
        }
        result.append(segment)
        return result
    }

    func nearest(at date: Date) -> StockTrendPoint? {
        guard !points.isEmpty else { return nil }
        var lower = 0
        var upper = points.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if points[middle].date < date { lower = middle + 1 }
            else { upper = middle }
        }
        if lower == 0 { return points[0] }
        if lower == points.count { return points[lower - 1] }
        let earlier = points[lower - 1]
        let later = points[lower]
        return date.timeIntervalSince(earlier.date) <= later.date.timeIntervalSince(date)
            ? earlier : later
    }
}

enum StockTrendError: LocalizedError {
    case unsupported
    case unsupportedBeijing
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unsupported: "目前仅支持 A 股和港股趋势"
        case .unsupportedBeijing: "北交所历史接口只返回占位点，暂无法提供可信走势"
        case .unavailable(let detail): "股票趋势暂不可用：\(detail)"
        }
    }
}

/// Tencent chart endpoints are queried only on demand, never on each quote refresh.
actor StockTrendService {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    private struct Key: Hashable {
        let code: String
        let range: StockTrendRange
    }
    private var cache: [Key: (loadedAt: Date, trend: StockTrend)] = [:]
    private var inFlight: [Key: Task<StockTrend, Error>] = [:]

    init(transport: @escaping Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw StockTrendError.unavailable("服务器未返回 HTTP 响应")
        }
        return (data, response)
    }) {
        self.transport = transport
    }

    func fetch(code: String, range: StockTrendRange, at now: Date = Date()) async throws -> StockTrend {
        guard WatchlistDraft.isValidCode(code), let market = StockMarket.forCode(code),
              market != .unitedStates else { throw StockTrendError.unsupported }
        guard !code.hasPrefix("bj") else { throw StockTrendError.unsupportedBeijing }
        let key = Key(code: code, range: range)
        if let cached = cache[key], now.timeIntervalSince(cached.loadedAt) >= 0,
           now.timeIntervalSince(cached.loadedAt) < range.cacheSeconds { return cached.trend }
        if let inFlight = inFlight[key] { return try await inFlight.value }
        let transport = transport
        let task = Task {
            let path: String
            switch range {
            case .today: path = "minute/query?code=\(code)"
            case .fiveDays: path = "day/query?code=\(code)"
            case .month: path = "kline/kline?param=\(code),day,,,31"
            }
            guard let url = URL(string: "https://web.ifzq.gtimg.cn/appstock/app/\(path)") else {
                throw StockTrendError.unavailable("行情地址无效")
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            let (data, response) = try await transport(request)
            guard response.statusCode == 200 else {
                throw StockTrendError.unavailable("接口 HTTP \(response.statusCode)")
            }
            return try Self.parse(data, code: code, market: market, range: range)
        }
        inFlight[key] = task
        do {
            let trend = try await task.value
            inFlight[key] = nil
            cache[key] = (now, trend)
            return trend
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    static func parse(_ data: Data, code: String, market: StockMarket, range: StockTrendRange) throws -> StockTrend {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["code"] as? Int == 0, let nodes = root["data"] as? [String: Any],
              let node = nodes[code] as? [String: Any] else {
            throw StockTrendError.unavailable("接口返回格式错误或代码未匹配")
        }
        var entries: [StockTrendPoint] = []
        switch range {
        case .today:
            guard let snapshot = node["data"] as? [String: Any],
                  let day = snapshot["date"] as? String,
                  let rows = snapshot["data"] as? [String] else {
                throw StockTrendError.unavailable("分时日期或明细缺失")
            }
            entries = parseMinutes(rows, day: day, market: market)
        case .fiveDays:
            guard let days = node["data"] as? [[String: Any]] else {
                throw StockTrendError.unavailable("近五日分时缺失")
            }
            entries = days.flatMap { day in
                guard let date = day["date"] as? String, let rows = day["data"] as? [String] else { return [StockTrendPoint]() }
                return parseMinutes(rows, day: date, market: market)
            }
        case .month:
            guard let rows = node["day"] as? [[Any]] else {
                throw StockTrendError.unavailable("日线数据缺失")
            }
            entries = rows.compactMap { row in
                guard row.count >= 6, let day = row[0] as? String,
                      let price = Double(row[2] as? String ?? ""), price.isFinite, price > 0,
                      day.count == 10 else { return nil }
                let compact = day.replacingOccurrences(of: "-", with: "")
                let time = market == .mainland ? "150000" : "160000"
                guard let date = market.quoteTime(from: compact + time) else { return nil }
                return StockTrendPoint(date: date, price: price)
            }
        }
        guard !entries.isEmpty else { throw StockTrendError.unavailable("该区间没有有效价格点") }
        entries.sort { $0.date < $1.date }
        var unique: [StockTrendPoint] = []
        for point in entries {
            if unique.last?.date == point.date { unique[unique.count - 1] = point }
            else { unique.append(point) }
        }
        return StockTrend(code: code, market: market, range: range, points: unique)
    }

    private static func parseMinutes(_ rows: [String], day: String, market: StockMarket) -> [StockTrendPoint] {
        guard day.count == 8, day.allSatisfy(\.isNumber) else { return [] }
        return rows.compactMap { row in
            let parts = row.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, parts[0].count == 4, parts[0].allSatisfy(\.isNumber),
                  let price = Double(parts[1]), price.isFinite, price > 0,
                  let date = market.quoteTime(from: day + parts[0] + "00"),
                  market.isRegularSession(at: date) else { return nil }
            return StockTrendPoint(date: date, price: price)
        }
    }
}
