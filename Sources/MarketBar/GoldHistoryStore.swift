import Foundation
import SQLite3

struct GoldHistorySample: Equatable, Sendable {
    let provider: GoldProvider
    let sampledAt: Date
    let price: Double
}

enum GoldHistoryError: LocalizedError {
    case invalidSample
    case invalidRange
    case database(String)

    var errorDescription: String? {
        switch self {
        case .invalidSample: return "金价或采集时间无效，未保存历史记录"
        case .invalidRange: return "查询时间无效：起点不得晚于终点，自选范围不能超过一年"
        case .database(let detail): return "无法读写金价历史数据库：\(detail)"
        }
    }
}

/// 本地原始分钟快照；不补缺口，也不对两个银行的价格做换算。
actor GoldHistoryStore {
    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MarketBar", isDirectory: true)
            .appendingPathComponent("gold-history.sqlite")
    }

    private nonisolated(unsafe) let database: OpaquePointer

    init(url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var connection: OpaquePointer?
        let status = sqlite3_open_v2(
            url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
        )
        guard status == SQLITE_OK, let connection else {
            let detail = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite 无法打开文件"
            if let connection { sqlite3_close(connection) }
            throw GoldHistoryError.database(detail)
        }
        database = connection
        let schema = """
            CREATE TABLE IF NOT EXISTS gold_samples (
                provider INTEGER NOT NULL CHECK (provider IN (1, 2)),
                minute INTEGER NOT NULL,
                sampled_at INTEGER NOT NULL,
                price REAL NOT NULL CHECK (price > 0),
                PRIMARY KEY (provider, minute)
            );
            """
        guard sqlite3_exec(connection, schema, nil, nil, nil) == SQLITE_OK else {
            let detail = String(cString: sqlite3_errmsg(connection))
            sqlite3_close(connection)
            throw GoldHistoryError.database(detail)
        }
    }

    deinit { sqlite3_close(database) }

    /// 每家银行每个 Unix 分钟只保留第一笔成功采到的价格。
    @discardableResult
    func record(provider: GoldProvider, price: Double, at date: Date) throws -> Bool {
        guard price.isFinite, price > 0, let seconds = Self.seconds(for: date) else {
            throw GoldHistoryError.invalidSample
        }
        let statement = try prepare(
            "INSERT OR IGNORE INTO gold_samples (provider, minute, sampled_at, price) VALUES (?, ?, ?, ?)"
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(provider.rawValue))
        sqlite3_bind_int64(statement, 2, seconds / 60)
        sqlite3_bind_int64(statement, 3, seconds)
        sqlite3_bind_double(statement, 4, price)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        return sqlite3_changes(database) == 1
    }

    /// 范围有序；不插值、不把没有运行或网络失败的分钟视为横盘。
    func samples(provider: GoldProvider, since start: Date, until end: Date) throws -> [GoldHistorySample] {
        guard let lower = Self.seconds(for: start), let upper = Self.seconds(for: end), lower <= upper else {
            throw GoldHistoryError.invalidRange
        }
        let statement = try prepare(
            """
            SELECT sampled_at, price FROM gold_samples
            WHERE provider = ? AND minute BETWEEN ? AND ? AND sampled_at BETWEEN ? AND ?
            ORDER BY minute
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(provider.rawValue))
        sqlite3_bind_int64(statement, 2, lower / 60)
        sqlite3_bind_int64(statement, 3, upper / 60)
        sqlite3_bind_int64(statement, 4, lower)
        sqlite3_bind_int64(statement, 5, upper)
        var result: [GoldHistorySample] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw failure() }
            result.append(GoldHistorySample(
                provider: provider,
                sampledAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))),
                price: sqlite3_column_double(statement, 1)
            ))
        }
    }

    func summary(for provider: GoldProvider) throws -> (count: Int64, first: Date?, last: Date?) {
        let statement = try prepare(
            "SELECT COUNT(*), MIN(sampled_at), MAX(sampled_at) FROM gold_samples WHERE provider = ?"
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(provider.rawValue))
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        let count = sqlite3_column_int64(statement, 0)
        return (
            count,
            count == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 1))),
            count == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 2)))
        )
    }

    private static func seconds(for date: Date) -> Int64? {
        let value = date.timeIntervalSince1970
        guard value.isFinite, value >= 0, value < Double(Int64.max) else { return nil }
        return Int64(value.rounded(.down))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw failure()
        }
        return statement
    }

    private func failure() -> GoldHistoryError {
        .database(String(cString: sqlite3_errmsg(database)))
    }
}
