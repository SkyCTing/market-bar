import Foundation

/// 一条价格提醒：盯住金价或某只股票，越过阈值就按指定的方式提醒。
///
/// 金价和股票共用同一个模型 —— 菜单里只有一处「价格提醒」，语义一致。
/// 提醒方式（宠物提示 / 弹窗）直接复用 `Reminder.Methods`，和定时提醒完全一样。
struct PriceAlert: Codable, Equatable, Identifiable, Sendable {
    /// 盯谁
    enum Target: Equatable, Sendable {
        case gold
        case stock(code: String)

        var code: String? {
            if case .stock(let code) = self { return code }
            return nil
        }
    }

    /// 往哪边越过
    enum Direction: String, Codable, Equatable, Sendable {
        case above   // 涨到 ≥ 阈值
        case below   // 跌到 ≤ 阈值

        var title: String {
            switch self {
            case .above: return "高于"
            case .below: return "低于"
            }
        }

        var symbol: String {
            switch self {
            case .above: return "≥"
            case .below: return "≤"
            }
        }

        var arrow: String {
            switch self {
            case .above: return "📈"
            case .below: return "📉"
            }
        }

        /// 这一刻算不算「已经越过阈值」
        func isBeyond(price: Double, threshold: Double) -> Bool {
            switch self {
            case .above: return price >= threshold
            case .below: return price <= threshold
            }
        }

        /// 算不算「回到了阈值内侧」。
        /// ⚠️ 故意用严格反向：等于阈值时既不算越过、也不算回落，
        /// 免得价格正好卡在阈值上时闩锁来回抖动（沿用原金价提醒的语义）
        func isBackInside(price: Double, threshold: Double) -> Bool {
            switch self {
            case .above: return price < threshold
            case .below: return price > threshold
            }
        }
    }

    var id: UUID = UUID()
    var target: Target = .gold
    var direction: Direction = .above
    var threshold: Double = 0
    /// 自定义提示语；空 = 用默认的「代码: 价格」/「金价: 价格」
    var message: String = ""
    /// 提醒方式，和定时提醒同一套
    var methods: Reminder.Methods = .default
    /// 勾上 = 价格回落之后再次穿过还会响；不勾 = 响一次就停
    var repeats: Bool = true
    /// 这一条自己的「已告警」闩锁。
    /// **持久化**：不持久化的话，「不重复」的提醒每次重启都会再响一次
    var isTriggered: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, target, direction, threshold, message, methods, repeats, isTriggered
    }

    /// 摘要：`📈 sh600036 ≥ 45.00`（菜单里显示用）
    func summary(displayName: String) -> String {
        let currency = target.code.flatMap(StockMarket.forCode)?.currency
        let suffix = currency.flatMap { $0 == "CNY" ? nil : " \($0)" } ?? ""
        return "\(direction.arrow) \(displayName) \(direction.symbol) \(String(format: "%.2f", threshold))\(suffix)"
    }

    /// 真正要显示的正文
    func displayMessage(price: Double) -> String {
        message.isEmpty ? Self.defaultMessage(for: self, price: price) : message
    }

    /// 没自定义时的默认提示语。用户点名要「股票代码冒号+价格」
    static func defaultMessage(for alert: PriceAlert, price: Double) -> String {
        let formatted = String(format: "%.2f", price)
        switch alert.target {
        case .gold: return "金价: \(formatted)"
        case .stock(let code):
            let currency = StockMarket.forCode(code)?.currency
            let suffix = currency.flatMap { $0 == "CNY" ? nil : " \($0)" } ?? ""
            return "\(code): \(formatted)\(suffix)"
        }
    }
}

extension PriceAlert.Target: Codable {
    /// 存成 `"gold"` / `"stock:sh600036"` —— 比嵌套对象紧凑，读起来也直白
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw.hasPrefix("stock:") {
            self = .stock(code: String(raw.dropFirst("stock:".count)))
        } else {
            // 认不出来的一律当金价：宁可盯错标的，也别让整条提醒解码失败
            self = .gold
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .gold: try container.encode("gold")
        case .stock(let code): try container.encode("stock:\(code)")
        }
    }
}

extension PriceAlert {
    /// 容忍缺字段的解码：新增字段后不能因为旧数据没有那个键就整条丢掉
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            target: try container.decodeIfPresent(Target.self, forKey: .target) ?? .gold,
            direction: try container.decodeIfPresent(Direction.self, forKey: .direction) ?? .above,
            threshold: try container.decodeIfPresent(Double.self, forKey: .threshold) ?? 0,
            message: try container.decodeIfPresent(String.self, forKey: .message) ?? "",
            methods: try container.decodeIfPresent(Reminder.Methods.self, forKey: .methods) ?? .default,
            repeats: try container.decodeIfPresent(Bool.self, forKey: .repeats) ?? true,
            isTriggered: try container.decodeIfPresent(Bool.self, forKey: .isTriggered) ?? false
        )
    }
}

/// 触发判定。纯函数，便于单测。
enum PriceAlertEvaluator {
    /// 价格到了，这一条该不该响；以及响完之后这条提醒的新状态。
    ///
    /// - 越过阈值且还没告警过 → 响，闩锁置上
    /// - 回到阈值内侧 → 只有勾了「重复提醒」才把闩锁复位（不重复的就一直锁着，响一次就完）
    static func evaluate(_ alert: PriceAlert, price: Double) -> (fired: Bool, updated: PriceAlert) {
        var updated = alert

        guard alert.direction.isBeyond(price: price, threshold: alert.threshold) else {
            // 回到内侧：只有要重复提醒的才重新武装
            if alert.repeats, alert.isTriggered {
                updated.isTriggered = false
            }
            return (false, updated)
        }

        guard !alert.isTriggered else { return (false, updated) }
        updated.isTriggered = true
        return (true, updated)
    }
}

/// 价格提醒的增删改查（存 UserDefaults），外加从旧版两条金价阈值迁移
@MainActor
final class PriceAlertStore {
    private static let key = "priceAlerts"
    /// 旧版就两个裸键：金价的高/低阈值
    private static let legacyHighKey = "highPriceThreshold"
    private static let legacyLowKey = "lowPriceThreshold"

    private let defaults: UserDefaults
    private(set) var alerts: [PriceAlert] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateLegacyGoldThresholdsIfNeeded()
        reload()
    }

    /// 逐条解码：某一条解不出来只丢那一条。
    /// （整份 `try? decode` 一条坏数据就把全部提醒清零，之后 save 会把空表写回去 ——
    /// 这个坑在 ReminderStore 上刚踩过，这里直接用同样的写法）
    private struct LossyAlert: Decodable {
        let value: PriceAlert?
        init(from decoder: Decoder) throws {
            value = try? PriceAlert(from: decoder)
        }
    }

    func reload() {
        guard let data = defaults.data(forKey: Self.key) else {
            alerts = []
            return
        }
        guard let decoded = try? JSONDecoder().decode([LossyAlert].self, from: data) else {
            // 整个键都解不出来：保持内存现状，别清空（下次 save 会把好的写回去，自愈）
            return
        }
        alerts = decoded.compactMap(\.value)
    }

    func save() {
        // 编码失败时绝不能 set(nil)：那会把整个 key 删掉，等于清空所有提醒
        guard let data = try? JSONEncoder().encode(alerts) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func upsert(_ alert: PriceAlert) {
        if let index = alerts.firstIndex(where: { $0.id == alert.id }) {
            alerts[index] = alert
        } else {
            alerts.append(alert)
        }
        save()
    }

    func remove(id: UUID) {
        alerts.removeAll { $0.id == id }
        save()
    }

    func removeAll() {
        alerts.removeAll()
        save()
    }

    func alerts(for target: PriceAlert.Target) -> [PriceAlert] {
        alerts.filter { $0.target == target }
    }

    /// 把旧版那两条金价阈值迁成提醒。
    ///
    /// 只在**从没写过新键**时做一次，且迁完就删掉旧键 —— 否则用户在新界面里
    /// 删掉迁移出来的提醒，下次启动又被旧键复活。
    private func migrateLegacyGoldThresholdsIfNeeded() {
        guard defaults.data(forKey: Self.key) == nil else { return }

        var migrated: [PriceAlert] = []
        if defaults.object(forKey: Self.legacyHighKey) != nil {
            migrated.append(PriceAlert(
                target: .gold,
                direction: .above,
                threshold: defaults.double(forKey: Self.legacyHighKey)
            ))
        }
        if defaults.object(forKey: Self.legacyLowKey) != nil {
            migrated.append(PriceAlert(
                target: .gold,
                direction: .below,
                threshold: defaults.double(forKey: Self.legacyLowKey)
            ))
        }
        guard !migrated.isEmpty else { return }

        alerts = migrated
        save()
        defaults.removeObject(forKey: Self.legacyHighKey)
        defaults.removeObject(forKey: Self.legacyLowKey)
    }
}
