import Foundation

/// 会议模式期间被压下来的一条提醒，散会后补放。
///
/// ⚠️ 必须把**呈现所需的整份内容**存下来，不能事后回 store 里取：
///   · `ReminderCenter.fire` 会先把空的 body 兜成 title（ReminderCenter.swift:214）
///   · 价格提醒的正文里焊死了**触发那一刻的实时价**（MarketBar.swift:1584 的
///     `displayMessage(price:)`），事后再算就是另一个数
///   · methods 也可能在会议期间被改过
///
/// 顶层类型，不嵌进 `MeetingMode`：把 Codable 模型嵌进 @MainActor 类型，
/// Swift 6 下会把全局 actor 隔离带进合成的解码器里
struct PendingAlert: Codable, Equatable, Sendable {
    /// 原来的 id。补放要复用它 —— `stillValid`、`pendingConfirms`、顺延全按它索引
    var key: UUID
    var title: String
    var body: String
    var methods: Reminder.Methods
    /// 同一条**连续**响了几次。循环倒计时开两小时会会响二十几次，
    /// 全列出来没意义，折成一条记个数
    var count: Int = 1

    init(key: UUID, title: String, body: String, methods: Reminder.Methods, count: Int = 1) {
        self.key = key
        self.title = title
        self.body = body
        self.methods = methods
        self.count = count
    }

    /// 手写解码：以后加字段不会把老队列整份判死
    /// （合成的解码器遇到缺字段会抛 keyNotFound —— 这个坑在 Reminder 上踩过）
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(UUID.self, forKey: .key)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        methods = try container.decodeIfPresent(Reminder.Methods.self, forKey: .methods) ?? .default
        count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 1
    }
}

/// 会议模式：一个手动开关 + 一份「会议期间被压住的提醒」队列。
///
/// 只管状态和持久化，不碰 AppKit、不认识菜单和弹框 —— 界面那层由 `AppDelegate`
/// 编排（见 `setMeetingMode`），呈现由 `AlertPresenter` 负责。
@MainActor
final class MeetingMode {
    static let enabledKey = "meetingModeEnabled"
    static let queueKey = "meetingModeQueue"
    /// 队列上限。正常用不到（连续重复本来就会折叠成一条），
    /// 但这是个随会议时长增长、还要落盘的数组，得有个头
    static let maximumQueueLength = 100

    private let defaults: UserDefaults
    private(set) var isOn: Bool
    private(set) var queue: [PendingAlert]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 缺省的 Bool 读出来是 false，所以要先判「这个键存过没有」
        isOn = (defaults.object(forKey: Self.enabledKey) != nil)
            && defaults.bool(forKey: Self.enabledKey)
        queue = []
        reloadQueue()
    }

    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        defaults.set(on, forKey: Self.enabledKey)
    }

    /// 记下一条。返回记完之后的队列长度
    @discardableResult
    func enqueue(_ alert: PendingAlert) -> Int {
        // 只折叠**相邻**的重复：循环倒计时连着响 24 次不该补 24 条气泡，
        // 但 A、B、A 要老老实实留三条，顺序不能被打乱
        if var last = queue.last,
           last.key == alert.key, last.title == alert.title,
           last.body == alert.body, last.methods == alert.methods {
            last.count += 1
            queue[queue.count - 1] = last
        } else {
            queue.append(alert)
            if queue.count > Self.maximumQueueLength {
                queue.removeFirst(queue.count - Self.maximumQueueLength)
            }
        }
        saveQueue()
        return queue.count
    }

    /// 取走整条队列，并**立刻**落盘空队列。
    ///
    /// 先清空再放是有意的：中途崩了、被强退、或者补放途中又被拉进会议模式，
    /// 最坏也只是少放一次，绝不会重放一遍 —— 和 `takeDueReminders`
    /// 「先登记整批」是同一个取舍
    func takeAll() -> [PendingAlert] {
        let items = queue
        queue = []
        saveQueue()
        return items
    }

    /// 补放被打断时，把还没放完的还回队首
    func prepend(_ alerts: [PendingAlert]) {
        guard !alerts.isEmpty else { return }
        queue.insert(contentsOf: alerts, at: 0)
        saveQueue()
    }

    var pendingCount: Int { queue.count }

    private func saveQueue() {
        // 编码失败时绝不能 set(nil)：那会把整个 key 删掉，等于清空队列
        guard let data = try? JSONEncoder().encode(queue) else { return }
        defaults.set(data, forKey: Self.queueKey)
    }

    private func reloadQueue() {
        guard let data = defaults.data(forKey: Self.queueKey) else { return }
        guard let decoded = try? JSONDecoder().decode([LossyPendingAlert].self, from: data) else {
            // 连数组都解不出来（整个键被写坏）—— 保持内存里现有的，别清空。
            // 之后再存一次就会把好的那份写回去，相当于自愈
            return
        }
        queue = decoded.compactMap(\.value)
    }

    /// 逐条解码：某一条解不出来只丢那一条，不能让整份队列归零
    /// （`ReminderStore` 那个坑的同款处理）
    private struct LossyPendingAlert: Decodable {
        let value: PendingAlert?
        init(from decoder: Decoder) throws { value = try? PendingAlert(from: decoder) }
    }
}

/// 补放时那条合并弹窗的文案。纯函数，好测
enum MeetingReplaySummary {
    /// 最多列几条。超出的折成「另有 N 条」——
    /// NSAlert 不会滚动，十几条带正文的提醒会把窗口撑得比屏幕还高
    static let maximumItems = 8
    static let maximumLineLength = 80

    static func title(count: Int) -> String {
        "会议期间错过了 \(count) 条提醒"
    }

    static func text(for items: [PendingAlert]) -> String {
        var lines = items.prefix(maximumItems).map(line(for:))
        if items.count > maximumItems {
            lines.append("…另有 \(items.count - maximumItems) 条，去「提醒 → 管理提醒…」查看")
        }
        return lines.joined(separator: "\n")
    }

    private static func line(for item: PendingAlert) -> String {
        let title = flatten(item.title)
        let body = flatten(item.body)
        var text = (body.isEmpty || body == title) ? title : "\(title)：\(body)"
        if text.count > maximumLineLength {
            text = String(text.prefix(maximumLineLength)) + "…"
        }
        if item.count > 1 { text += "（连续 \(item.count) 次）" }
        return "• " + text
    }

    /// 正文里带的换行会把 NSAlert 的版式搞乱，压成单空格
    private static func flatten(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
