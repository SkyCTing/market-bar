import AppKit
import Foundation

enum GoldProvider: CaseIterable {
    case zheShang
    case minSheng

    var displayName: String {
        switch self {
        case .zheShang:
            return "浙商积存金"
        case .minSheng:
            return "民生积存金"
        }
    }

    var shortName: String {
        switch self {
        case .zheShang:
            return "浙商"
        case .minSheng:
            return "民生"
        }
    }

    var url: URL {
        switch self {
        case .zheShang:
            return URL(string: "https://api.jdjygold.com/gw2/generic/produTools/h5/m/getGoldPrice?goldCode=CZB-JCJ")!
        case .minSheng:
            return URL(string: "https://ms.jr.jd.com/gw2/generic/CreatorSer/newh5/m/getFirstRelatedProductInfo?reqData=%7B%22circleId%22%3A%2213245%22%2C%22invokeSource%22%3A5%2C%22productId%22%3A%2221001001000001%22%7D")!
        }
    }
}

enum RefreshIntervalOption: Double, CaseIterable {
    case one = 1
    case two = 2
    case five = 5
    case ten = 10

    var title: String {
        "\(Int(rawValue)) 秒"
    }
}

/// 人物冒完气泡之后、等多久才弹置顶模态框（只在两种提醒方式都勾时才有意义）。
///
/// 用户 2026-09-25 反馈 60 秒太久，默认改成 30 秒，并且做成可调。
enum ReminderAcknowledgeOption: Double, CaseIterable {
    case ten = 10
    case fifteen = 15
    case thirty = 30
    case fortyFive = 45
    case sixty = 60
    case ninety = 90
    case twoMinutes = 120

    static let defaultOption: ReminderAcknowledgeOption = .thirty

    var title: String {
        guard rawValue >= 60 else { return "\(Int(rawValue)) 秒" }
        let minutes = Int(rawValue) / 60
        let remainder = Int(rawValue) % 60
        // 整除才说「N 分钟」，否则 90 秒会被说成「1 分钟」
        return remainder == 0 ? "\(minutes) 分钟" : "\(minutes) 分 \(remainder) 秒"
    }
}

struct ZheShangResponse: Decodable {
    let resultData: ResultData?

    struct ResultData: Decodable {
        let data: DataNode?
    }

    struct DataNode: Decodable {
        let lastPrice: Double?
        let raise: Double?
        let raisePercent: Double?
    }
}

struct MinShengResponse: Decodable {
    let resultData: ResultData?

    struct ResultData: Decodable {
        let data: DataNode?
    }

    struct DataNode: Decodable {
        let minimumPriceValue: String?
        let rateValue: String?
        let dayFluctuateNum: String?
    }
}

struct PriceInfo {
    let price: Double
    let changeAmount: String   // e.g. "-4.22" or "+4.22"
    let changePercent: String  // e.g. "-0.44%" or "+0.44%"
    let isNegative: Bool?

    static let empty = PriceInfo(price: 0, changeAmount: "0.00", changePercent: "0.00%", isNegative: nil)
}

// MARK: - Market Quote API Response

struct MarketQuoteResponse: Decodable {
    let resultData: ResultData?

    struct ResultData: Decodable {
        let data: [QuoteItem]?
    }

    struct QuoteItem: Decodable {
        let uniqueCode: String?
        let name: String?
        let lastPrice: Double?
        let raise: Double?
        let raisePercent: Double?
    }
}

struct MarketData {
    let londonGold: QuoteRow       // XAUUSD
    let goldTD: QuoteRow           // Au(T+D)
    let usdCnh: QuoteRow           // USDCNH
    let dollarIndex: QuoteRow      // DXY
    let convertedPrice: Double     // 伦敦金换算价 (¥/g)
    let premium: Double            // 溢价金额 (¥/g)

    struct QuoteRow {
        let name: String
        let price: String
        let raise: Double
        let raisePercent: Double
    }

    static let empty = MarketData(
        londonGold: QuoteRow(name: "伦敦金", price: "--", raise: 0, raisePercent: 0),
        goldTD: QuoteRow(name: "黄金T+D", price: "--", raise: 0, raisePercent: 0),
        usdCnh: QuoteRow(name: "离岸人民币", price: "--", raise: 0, raisePercent: 0),
        dollarIndex: QuoteRow(name: "美元指数", price: "--", raise: 0, raisePercent: 0),
        convertedPrice: 0,
        premium: 0
    )
}

// MARK: - 自选清单

/// 悬浮面板「自选行情」分区的标的清单。
/// 运行时从配置文件读（`~/Library/Application Support/MarketBar/watchlist.json`），
/// 默认值见 `WatchlistConfig.default`；菜单里「重新载入配置」可刷新。
enum StockWatchlist {
    struct Entry: Sendable {
        let code: String
        let name: String
    }

    /// 启动时写一次，之后只在主线程通过 reload() 改
    nonisolated(unsafe) static var entries: [Entry] = loadEntries()

    static var codes: [String] { entries.map(\.code) }

    static var url: URL {
        URL(string: "https://qt.gtimg.cn/q=" + entries.map(\.code).joined(separator: ","))!
    }

    static func loadEntries() -> [Entry] {
        WatchlistConfig.load().watchlist.map { Entry(code: $0.code, name: $0.name) }
    }

    static func reload() {
        entries = loadEntries()
    }
}

/// 单只标的的行情。价格/涨跌字段与 `MarketData.QuoteRow` 一一对应，
/// 因此面板的 `formatValueWithPercent` 与 `raisedColor` 可以直接复用。
struct StockQuote: Sendable {
    let code: String
    let name: String
    /// 已格式化价格字符串，`"--"` 表示无数据（沿用 `QuoteRow.price` 的哨兵约定）
    let price: String
    let raise: Double
    /// ⚠️ 小数：0.0029 表示 0.29%
    let raisePercent: Double
    /// 今日累计成交量（手）
    let volume: Double
    /// 行情时间戳所属的交易日 `2026-09-23`；解析失败为空串
    let sessionDate: String

    /// 数值价格。`price` 是已格式化的字符串，`"--"` 表示无数据 ——
    /// 阈值比较要用数值，别在每个判定点各写一遍 `Double(...)` 加哨兵判断
    var numericPrice: Double? {
        guard price != "--", let value = Double(price), value.isFinite, value > 0 else { return nil }
        return value
    }

    static func placeholder(
        code: String,
        name: String,
        volume: Double = 0,
        sessionDate: String = ""
    ) -> StockQuote {
        StockQuote(
            code: code,
            name: name,
            price: "--",
            raise: 0,
            raisePercent: 0,
            volume: volume,
            sessionDate: sessionDate
        )
    }
}

final class GoldPriceService: Sendable {
    private let session: URLSession

    private let marketQuoteURL = URL(string: "https://ms.jr.jd.com/gw2/generic/jdtwt/h5/m/getSimpleQuoteUseUniqueCodes?reqData=%7B%22ticket%22%3A%22gold-price-h5%22%2C%22uniqueCodes%22%3A%5B%22WG-XAUUSD%22%2C%22SGE-Au(T%2BD)%22%2C%22FX-USDCNH%22%2C%22FX-DXY%22%5D%7D")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchPriceInfo(for provider: GoldProvider) async -> PriceInfo {
        var request = URLRequest(url: provider.url)
        request.timeoutInterval = 5

        do {
            let (data, _) = try await session.data(for: request)
            switch provider {
            case .zheShang:
                return try decodeZheShang(from: data)
            case .minSheng:
                return try decodeMinSheng(from: data)
            }
        } catch {
            return .empty
        }
    }

    func fetchMarketData(currentGoldPrice: Double) async -> MarketData {
        var request = URLRequest(url: marketQuoteURL)
        request.timeoutInterval = 5

        do {
            let (data, _) = try await session.data(for: request)
            let response = try JSONDecoder().decode(MarketQuoteResponse.self, from: data)
            guard let items = response.resultData?.data else { return .empty }

            var xauusd: MarketQuoteResponse.QuoteItem?
            var auTD: MarketQuoteResponse.QuoteItem?
            var usdcnh: MarketQuoteResponse.QuoteItem?
            var dxy: MarketQuoteResponse.QuoteItem?

            for item in items {
                switch item.uniqueCode {
                case "WG-XAUUSD": xauusd = item
                case "SGE-Au(T+D)": auTD = item
                case "FX-USDCNH": usdcnh = item
                case "FX-DXY": dxy = item
                default: break
                }
            }

            func makeRow(_ item: MarketQuoteResponse.QuoteItem?, decimals: Int = 2) -> MarketData.QuoteRow {
                guard let item else { return MarketData.QuoteRow(name: "--", price: "--", raise: 0, raisePercent: 0) }
                let priceStr = String(format: "%.\(decimals)f", item.lastPrice ?? 0)
                return MarketData.QuoteRow(
                    name: item.name ?? "--",
                    price: priceStr,
                    raise: item.raise ?? 0,
                    raisePercent: item.raisePercent ?? 0
                )
            }

            let londonGoldPrice = xauusd?.lastPrice ?? 0
            let exchangeRate = usdcnh?.lastPrice ?? 0

            // 伦敦金换算价 = XAUUSD / 31.1035 * USDCNH
            let converted = londonGoldPrice > 0 && exchangeRate > 0
                ? londonGoldPrice / 31.1035 * exchangeRate
                : 0

            // 溢价 = 黄金T+D - 换算价
            let auTDPrice = auTD?.lastPrice ?? 0
            let premium = converted > 0 && auTDPrice > 0
                ? auTDPrice - converted
                : 0

            return MarketData(
                londonGold: makeRow(xauusd, decimals: 2),
                goldTD: makeRow(auTD, decimals: 2),
                usdCnh: makeRow(usdcnh, decimals: 4),
                dollarIndex: makeRow(dxy, decimals: 3),
                convertedPrice: converted,
                premium: premium
            )
        } catch {
            return .empty
        }
    }

    /// 拉取 `StockWatchlist` 里所有标的的行情。返回的字典可能缺项（接口没返回该代码、
    /// 或该标的停牌），缺的项由调用方回落到 `StockQuote.placeholder`。
    /// ⚠️ 清单必须由调用方**在主线程取好快照**再传进来。
    ///
    /// 这个方法体跑在协作线程池上（`async let` 起的），而 `StockWatchlist.entries`
    /// 是主线程可随时改写的全局变量（保存配置就改），在后台直接读它是真实的数据竞争 ——
    /// 最坏情况下读到正在释放的数组缓冲，拼出的 URL 会让 `URL(string:)!` 崩掉。
    func fetchStockQuotes(codes: [String], fallback: [StockWatchlist.Entry]) async -> [String: StockQuote] {
        guard let url = URL(string: "https://qt.gtimg.cn/q=" + codes.joined(separator: ",")) else {
            return [:]
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (data, _) = try await session.data(for: request)
            return Self.parseStockQuotes(data, watchlist: fallback)
        } catch {
            return [:]
        }
    }

    /// 解析腾讯行情 `qt.gtimg.cn` 的响应。每行形如
    /// `v_sh512170="1~医疗ETF华宝~512170~0.349~…~<30 时间>~<31 涨跌>~<32 涨跌幅%>~…";`
    /// 记录之间用 `";\n"` 分隔（第二条起每段以换行开头），所以按清单里的代码
    /// 逐个定位锚点，而不是按 `;` 切分。
    static func parseStockQuotes(_ data: Data, watchlist: [StockWatchlist.Entry]) -> [String: StockQuote] {
        // 响应含 GBK 编码的中文名称。ISO-8859-1 把每个字节一一映射成字符，对要读的
        // ASCII 数字字段是无损的；换成 .utf8 会整段返回 nil，导致全部标的一直显示 "--"。
        let text = String(data: data, encoding: .isoLatin1) ?? ""

        var quotes: [String: StockQuote] = [:]
        for entry in watchlist {
            guard let keyRange = text.range(of: "v_\(entry.code)=\"") else { continue }
            let rest = text[keyRange.upperBound...]
            guard let bodyEnd = rest.firstIndex(of: "\"") else { continue }
            let fields = rest[rest.startIndex..<bodyEnd].components(separatedBy: "~")

            // 字段不足或内容错位（无效代码只会返回 v_pv_none_match="1"）时跳过
            guard fields.count > 32, fields[2].hasSuffix(entry.code.suffix(6)) else { continue }

            // 成交量和交易日要在「价格为 0 就占位」那道 guard 之前取：
            // 否则停牌行的 sessionDate 为空，日线缓存的键就永远是空的，永远不会去拉。
            let volume = Double(fields[6]) ?? 0
            let sessionDate = TradingSession.sessionDate(fromQuoteTimestamp: fields[30]) ?? ""

            // 停牌、未开盘或数据异常时价格是 0.000 / 空，回落到 "--" 占位
            guard let price = Double(fields[3]), price > 0 else {
                quotes[entry.code] = .placeholder(
                    code: entry.code,
                    name: entry.name,
                    volume: volume,
                    sessionDate: sessionDate
                )
                continue
            }

            quotes[entry.code] = StockQuote(
                code: entry.code,
                name: entry.name,
                price: fields[3],
                raise: Double(fields[31]) ?? 0,
                raisePercent: (Double(fields[32]) ?? 0) / 100,  // 接口给的是百分数，面板要小数
                volume: volume,
                sessionDate: sessionDate
            )
        }
        return quotes
    }

    /// 法定节假日（timor.tech 的年接口，含调休补班信息）。
    /// 只用来判断「今天是不是交易日」和取节日名，拉不到就退化为只按周末判断。
    /// 一次请求同时取回：法定节假日（日期 → 节日名）与调休补班日（这些日子要照常提醒）
    func fetchHolidays(year: Int) async -> (holidays: [String: String], makeupWorkdays: Set<String>) {
        guard let url = URL(string: "https://timor.tech/api/holiday/year/\(year)") else { return ([:], []) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        do {
            let (data, _) = try await session.data(for: request)
            return (MarketCalendar.parseHolidays(data), MarketCalendar.parseMakeupWorkdays(data))
        } catch {
            return ([:], [])
        }
    }

    /// 日线接口。一次只能一只（多个代码用 `;` 或 `,` 拼接都会返回 param error，实测过），
    /// 且用 kline/kline 而不是 fqkline/get：后者对部分代码返回 `day`、对另一部分返回 `qfqday`，
    /// 键不稳定；而成交量复权与否完全一致（比对过 320 个交易日），所以取键稳定的这个。
    private static let dailyBarsBase = "https://web.ifzq.gtimg.cn/appstock/app/kline/kline?param="

    static func dailyBarsURL(code: String, days: Int = 5) -> URL? {
        // 代码来自写死的清单，仍然校验一次，免得手误把垃圾参数打出去
        guard code.range(of: "^(sh|sz)[0-9]{6}$", options: .regularExpression) != nil else { return nil }
        return URL(string: "\(dailyBarsBase)\(code),day,,,\(days)")
    }

    /// 拉一只标的最近若干根日线，用来取「昨日全天量」
    func fetchDailyBars(code: String, days: Int = 5) async -> [StockDailyBar] {
        guard let url = Self.dailyBarsURL(code: code, days: days) else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (data, _) = try await session.data(for: request)
            return Self.parseDailyBars(data, code: code)
        } catch {
            return []
        }
    }

    /// 并发拉多只（串行最坏 16 × 5 秒）。失败的代码不进结果，调用方显示 "--"，等下次会话日变化时重试。
    func fetchDailyBars(codes: [String], days: Int = 5) async -> [String: [StockDailyBar]] {
        await withTaskGroup(of: (String, [StockDailyBar]).self) { group in
            for code in codes {
                group.addTask { (code, await self.fetchDailyBars(code: code, days: days)) }
            }
            var result: [String: [StockDailyBar]] = [:]
            for await (code, bars) in group where !bars.isEmpty {
                result[code] = bars
            }
            return result
        }
    }

    static func parseDailyBars(_ data: Data, code: String) -> [StockDailyBar] {
        guard let response = try? JSONDecoder().decode(DailyKlineResponse.self, from: data),
              let rows = response.data?[code]?.day else { return [] }

        return rows.compactMap { row in
            guard row.count >= 6,
                  let date = row[0].stringValue,
                  let volumeText = row[5].stringValue,
                  let volume = Double(volumeText) else { return nil }
            return StockDailyBar(date: date, volume: volume)
        }
    }

    private struct DailyKlineResponse: Decodable {
        let data: [String: Node]?

        struct Node: Decodable {
            let day: [[JSONScalar]]?
        }
    }

    /// 日线每根通常是 6 个字符串，但个别标的（如 sz301609、sz300803）末尾会多带一个
    /// 对象元素 `{"nd":"2026…"}`。用宽松标量解码，否则 `[[String]]` 会整段解析失败，
    /// 那几只标的的昨日量就永远是空的。
    private enum JSONScalar: Decodable {
        case text(String)
        case other

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                self = .text(value)
            } else if let value = try? container.decode(Double.self) {
                self = .text(String(value))
            } else {
                self = .other
            }
        }

        var stringValue: String? {
            if case .text(let value) = self { return value }
            return nil
        }
    }

    private func decodeZheShang(from data: Data) throws -> PriceInfo {
        let response = try JSONDecoder().decode(ZheShangResponse.self, from: data)
        let node = response.resultData?.data
        let price = node?.lastPrice ?? 0
        let raise = node?.raise ?? 0
        let raisePercent = node?.raisePercent ?? 0

        // Truncate raisePercent * 100 to 2 decimal places (not round)
        let pctValue = raisePercent * 100
        let truncated = (pctValue * 100).rounded(.towardZero) / 100
        let percentStr = String(format: "%.2f%%", truncated)
        let amountStr = String(format: "%.2f", raise)
        let isNeg = raise < 0 ? true : (raise > 0 ? false : nil)

        return PriceInfo(price: price, changeAmount: amountStr, changePercent: percentStr, isNegative: isNeg)
    }

    private func decodeMinSheng(from data: Data) throws -> PriceInfo {
        let response = try JSONDecoder().decode(MinShengResponse.self, from: data)
        let node = response.resultData?.data
        let price: Double
        if let value = node?.minimumPriceValue {
            price = Double(value) ?? 0
        } else {
            price = 0
        }
        let percentStr = node?.rateValue ?? "0.00%"
        let amountStr = node?.dayFluctuateNum ?? "0.00"

        // Determine direction from the amount string
        let isNeg: Bool?
        if amountStr.hasPrefix("-") {
            isNeg = true
        } else if let val = Double(amountStr), val > 0 {
            isNeg = false
        } else {
            isNeg = nil
        }

        return PriceInfo(price: price, changeAmount: amountStr, changePercent: percentStr, isNegative: isNeg)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let service = GoldPriceService()
    private let floatingCharacterController = FloatingCharacterController()

    private var selectedProvider: GoldProvider = .zheShang
    private var refreshInterval: RefreshIntervalOption = .one
    /// 气泡到弹窗的等待时间（用户可调，默认 30 秒）
    private var reminderAcknowledge: ReminderAcknowledgeOption = .defaultOption
    private var timer: Timer?
    private var currentPrice: Double = 0
    private var currentPriceInfo: PriceInfo = .empty
    private var currentMarketData: MarketData = .empty
    private var currentStockQuotes: [String: StockQuote] = [:]
    /// 各标的最近的日线，用来取「昨日全天量」。一个交易日内是常量，所以按会话日缓存。
    private var dailyBars: [String: [StockDailyBar]] = [:]
    private var dailyBarsSessionKey = ""
    private var isLoadingDailyBars = false
    private var nextDailyBarsRetry = Date.distantPast
    private var isFetching = false
    private var lastUpdateTime: Date?

    // Hover panel
    private var hoverPanel: HoverPanel?
    /// 右键人物弹出的 AI 聊天窗（懒创建）
    private var chatController: ClaudeChatController?
    /// 「自选与持仓」配置窗口（懒创建）
    private var watchlistSettings: WatchlistSettingsController?
    /// 「提醒管理」窗口（懒创建）
    private var reminderList: ReminderListController?
    /// 提醒（配置存 UserDefaults，30 秒扫一次）
    private let reminderStore = ReminderStore()
    private lazy var reminderCenter = ReminderCenter(
        store: reminderStore,
        characterController: floatingCharacterController
    )

    /// 微信未读数（面板左右两个徽标用）
    private var unreadCounts = UnreadBadge.Counts()
    private var lastUnreadFetch = Date.distantPast
    private var unreadFailures = 0
    /// 未读不必每秒看一次；而且 `fetch()` 是主线程同步 AX IPC，
    /// 实测均值 1.2ms、最坏 42ms —— 微信卡住时会连带拖住金价刷新和动画
    private static let unreadFetchInterval: TimeInterval = 3
    /// 连续失败这么多次才把徽标显示成「读不到」，免得一次瞬时失败就闪
    private static let unreadFailureTolerance = 3
    /// 菜单里每类提醒最多列几条，超出的去「管理提醒…」窗口看
    private static let menuListLimit = 5
    /// 法定节假日（"2026-10-01" → "国庆节"），每天刷新一次，落在本地
    private var holidays: [String: String] = [:]
    /// 调休补班日（这些周六/周日要上班，提醒照常）
    private var makeupWorkdays: Set<String> = []
    private var holidayFetchDate: Date?

    /// 价格提醒：金价与股票共用一套（模型与判定见 PriceAlert.swift），存 UserDefaults
    private let priceAlertStore = PriceAlertStore()
    private var isMenuOpen = false
    private var isFloatingCharacterVisible = true
    private var floatingCharacterSize: FloatingCharacterSizeOption = .defaultOption
    /// 拖到屏幕边缘时直接收起（默认关，需要时在菜单「浮动窗口」里打开）
    private var hidesFloatingCharacterAtEdge = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        loadSettings()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusTitle()
        rebuildMenu()
        restartTimer()
        setupHoverTracking()
        floatingCharacterController.setSize(floatingCharacterSize)
        floatingCharacterController.update(
            price: format(price: currentPrice),
            numericPrice: currentPrice,
            isNegative: currentPriceInfo.isNegative
        )
        floatingCharacterController.setVisible(isFloatingCharacterVisible)
        reminderCenter.start()
        floatingCharacterController.onRightClick = { [weak self] anchor in
            self?.showChat(anchor: anchor)
        }
        floatingCharacterController.hidesAtEdge = hidesFloatingCharacterAtEdge
        floatingCharacterController.onAutoHidden = { [weak self] in
            guard let self else { return }
            self.isFloatingCharacterVisible = false
            // 人都藏起来了，聊天窗也别留着（和菜单里的「显示人物」一个处理）
            self.chatController?.close()
            self.saveSettings()
            self.rebuildMenu()
        }
        refreshHolidaysIfNeeded()
        Task {
            await self.refreshPrice()
        }
    }

    /// 右键人物 → 打开/收起聊天窗（懒创建，和 hoverPanel 一个套路）
    private func showChat(anchor: NSRect) {
        let controller = chatController ?? ClaudeChatController()
        chatController = controller
        controller.toggle(anchor: anchor)
    }

    /// 退出前必须取消在途请求：否则 claude 子进程被 launchd 收养，会继续烧钱
    func applicationWillTerminate(_ notification: Notification) {
        chatController?.shutdown()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        hoverPanel?.dismiss()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval.rawValue, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshPrice()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func refreshPrice() async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        // 三个请求并发发起：各自 5 秒超时，串行的话最坏要 15 秒，
        // 而 isFetching 会把这段时间的刷新全部丢掉。
        async let priceTask = service.fetchPriceInfo(for: selectedProvider)
        async let marketTask = service.fetchMarketData(currentGoldPrice: currentPrice)
        // 在主线程上取快照：后台那条任务绝不能直接读 StockWatchlist 的全局状态
        let watchlistCodes = StockWatchlist.codes
        let watchlistEntries = StockWatchlist.entries
        async let stockTask = service.fetchStockQuotes(codes: watchlistCodes, fallback: watchlistEntries)

        let info = await priceTask
        currentPriceInfo = info
        currentPrice = info.price
        lastUpdateTime = Date()
        updateStatusTitle()
        refreshHolidaysIfNeeded()
        refreshUnreadIfNeeded()
        updateFloatingCharacter()
        currentMarketData = await marketTask
        currentStockQuotes = await stockTask

        // 金价和股票行情都拿到之后再判一次。单一判定点，代价是金价提醒要等到
        // 三个请求里最慢那个回来（各自 5 秒超时）—— 对价格提醒来说无所谓
        checkPriceAlerts()
        // 纯计算，无 await：不影响金价与状态栏的关键路径
        floatingCharacterController.updateProfitLoss(
            marketClosedGreeting()?.greeting ?? totalProfitLossText()
        )
        scheduleDailyBarsLoadIfNeeded()
        if hoverPanel?.isVisible == true {
            updateHoverPanelContent()
        }
    }

    /// 昨日成交量在一个交易日内是常量，所以每个「行情会话日」只拉一次日线。
    ///
    /// 这里只起 Task 不 await：`refreshPrice` 全程持着 `isFetching`，
    /// 一旦 await 就会把 1 秒一跳卡住（最坏 5 秒），那段时间的价格刷新会被全部丢掉。
    private func scheduleDailyBarsLoadIfNeeded() {
        let key = currentStockQuotes.values.map(\.sessionDate).max() ?? ""
        guard !key.isEmpty else { return }

        // 换会话日（下一个交易日）时整批重来
        if key != dailyBarsSessionKey {
            dailyBars = [:]
            dailyBarsSessionKey = key
        }

        // 只补还缺的：并发请求偶尔会丢一两个，整批判定「成功」会让缺的那几只一整天都是 "--"
        let missing = StockWatchlist.codes.filter { dailyBars[$0] == nil }
        guard !missing.isEmpty, !isLoadingDailyBars, Date() >= nextDailyBarsRetry else { return }

        isLoadingDailyBars = true
        Task { [weak self] in
            guard let self else { return }
            let fetched = await self.service.fetchDailyBars(codes: missing)
            self.isLoadingDailyBars = false

            // 拉取期间可能已经跨了会话日，那一批数据就作废，等下一轮按新键重来
            guard key == self.dailyBarsSessionKey else { return }
            self.dailyBars.merge(fetched) { _, new in new }

            // 退避是为了避免条件的每秒检查变成重试风暴；只缺少数几只时不用等太久
            if fetched.count < missing.count {
                self.nextDailyBarsRetry = Date().addingTimeInterval(fetched.isEmpty ? 60 : 15)
            } else {
                self.nextDailyBarsRetry = .distantPast
            }

            if self.hoverPanel?.isVisible == true {
                self.updateHoverPanelContent()
            }
        }
    }

    /// 微信未读：降频到 3 秒一次，并且读失败时先沿用上一次的显示
    private func refreshUnreadIfNeeded() {
        guard Date().timeIntervalSince(lastUnreadFetch) >= Self.unreadFetchInterval else { return }
        lastUnreadFetch = Date()

        let fetched = UnreadBadge.fetch()
        unreadFailures = fetched.isUnavailable ? unreadFailures + 1 : 0

        let displayed = UnreadBadge.displayed(
            fetched,
            previous: unreadCounts,
            failures: unreadFailures,
            tolerance: Self.unreadFailureTolerance
        )
        unreadCounts = displayed
        floatingCharacterController.updateUnread(main: displayed.weChat, second: displayed.weChatSecond)
    }

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }

        // 状态栏只显示价格，例如 "1049.59"
        let attributed = NSAttributedString(
            string: format(price: currentPrice),
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ]
        )

        button.image = nil
        button.imagePosition = .noImage
        button.attributedTitle = attributed
    }

    private func format(price: Double) -> String {
        String(format: "%.2f", price)
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        for provider in GoldProvider.allCases {
            let item = NSMenuItem(
                title: provider.displayName,
                action: #selector(selectProvider(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = provider
            item.isEnabled = provider != selectedProvider
            menu.addItem(item)
        }

        let refreshMenuItem = NSMenuItem(title: "设置刷新频率", action: nil, keyEquivalent: "")
        let refreshSubmenu = NSMenu(title: "设置刷新频率")
        for option in RefreshIntervalOption.allCases {
            let item = NSMenuItem(
                title: option.title,
                action: #selector(selectRefreshInterval(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = option
            item.state = option == refreshInterval ? .on : .off
            refreshSubmenu.addItem(item)
        }
        menu.setSubmenu(refreshSubmenu, for: refreshMenuItem)
        menu.addItem(refreshMenuItem)

        // 价格提醒（金价 + 股票共用一套）
        let alertMenuItem = NSMenuItem(title: "价格提醒", action: nil, keyEquivalent: "")
        let alertSubmenu = NSMenu(title: "价格提醒")

        let allAlerts = priceAlertStore.alerts
        for alert in allAlerts.prefix(8) {
            let entry = NSMenuItem(
                title: "\(alert.summary(displayName: displayName(for: alert.target))) · \(alert.methods.title)",
                action: #selector(editPriceAlert(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = alert
            alertSubmenu.addItem(entry)
        }
        if allAlerts.count > 8 {
            alertSubmenu.addItem(NSMenuItem(title: "还有 \(allAlerts.count - 8) 条…", action: nil, keyEquivalent: ""))
        }
        if !allAlerts.isEmpty { alertSubmenu.addItem(.separator()) }

        let manageAlerts = NSMenuItem(title: "管理提醒…", action: #selector(showReminderList), keyEquivalent: "")
        manageAlerts.target = self
        alertSubmenu.addItem(manageAlerts)

        let addPriceAlert = NSMenuItem(title: "添加价格提醒…", action: #selector(addPriceAlert), keyEquivalent: "")
        addPriceAlert.target = self
        alertSubmenu.addItem(addPriceAlert)

        if !allAlerts.isEmpty {
            let clear = NSMenuItem(title: "清除全部", action: #selector(clearAllPriceAlerts), keyEquivalent: "")
            clear.target = self
            alertSubmenu.addItem(clear)
        }

        menu.setSubmenu(alertSubmenu, for: alertMenuItem)
        menu.addItem(alertMenuItem)

        menu.addItem(.separator())

        let floatingWindowItem = NSMenuItem(title: "浮动窗口", action: nil, keyEquivalent: "")
        let floatingWindowSubmenu = NSMenu(title: "浮动窗口")

        let visibilityItem = NSMenuItem(
            title: "显示人物",
            action: #selector(toggleFloatingCharacter),
            keyEquivalent: ""
        )
        visibilityItem.target = self
        visibilityItem.state = isFloatingCharacterVisible ? .on : .off
        floatingWindowSubmenu.addItem(visibilityItem)

        let hideAtEdgeItem = NSMenuItem(
            title: "拖到边缘自动隐藏",
            action: #selector(toggleHideAtEdge),
            keyEquivalent: ""
        )
        hideAtEdgeItem.target = self
        hideAtEdgeItem.state = hidesFloatingCharacterAtEdge ? .on : .off
        floatingWindowSubmenu.addItem(hideAtEdgeItem)

        let sizeItem = NSMenuItem(title: "调整大小", action: nil, keyEquivalent: "")
        let sizeSubmenu = NSMenu(title: "调整大小")
        for option in FloatingCharacterSizeOption.allCases {
            let item = NSMenuItem(
                title: option.title,
                action: #selector(selectFloatingCharacterSize(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = option
            item.state = option == floatingCharacterSize ? .on : .off
            sizeSubmenu.addItem(item)
        }
        floatingWindowSubmenu.setSubmenu(sizeSubmenu, for: sizeItem)
        floatingWindowSubmenu.addItem(sizeItem)

        menu.setSubmenu(floatingWindowSubmenu, for: floatingWindowItem)
        menu.addItem(floatingWindowItem)

        menu.addItem(.separator())

        menu.addItem(makeWatchlistMenuItem())
        menu.addItem(makeReminderMenuItem())
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc
    private func selectProvider(_ sender: NSMenuItem) {
        guard let provider = sender.representedObject as? GoldProvider else { return }
        selectedProvider = provider
        currentPrice = 0
        currentPriceInfo = .empty
        updateStatusTitle()
        floatingCharacterController.resetQuoteHistory()
        floatingCharacterController.update(
            price: format(price: currentPrice),
            numericPrice: currentPrice,
            isNegative: nil
        )
        rebuildMenu()
        saveSettings()
        Task {
            await self.refreshPrice()
        }
    }

    @objc
    private func selectRefreshInterval(_ sender: NSMenuItem) {
        guard let option = sender.representedObject as? RefreshIntervalOption else { return }
        refreshInterval = option
        rebuildMenu()
        restartTimer()
        saveSettings()
    }

    // MARK: - 自选配置

    private func makeWatchlistMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "自选配置", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "自选配置")

        let edit = NSMenuItem(title: "编辑自选与持仓…", action: #selector(showWatchlistSettings), keyEquivalent: "")
        edit.target = self
        submenu.addItem(edit)

        submenu.addItem(.separator())

        let open = NSMenuItem(title: "打开配置文件…", action: #selector(openWatchlistConfig), keyEquivalent: "")
        open.target = self
        submenu.addItem(open)

        let reload = NSMenuItem(title: "重新载入配置", action: #selector(reloadWatchlistConfig), keyEquivalent: "")
        reload.target = self
        submenu.addItem(reload)

        menu.setSubmenu(submenu, for: item)
        return item
    }

    /// 打开配置窗口（懒创建）。保存后由 `saveWatchlistConfig(_:)` 落盘并重载。
    @objc private func showWatchlistSettings() {
        let controller = watchlistSettings ?? {
            let created = WatchlistSettingsController()
            created.onSave = { [weak self] config in self?.saveWatchlistConfig(config) ?? false }
            return created
        }()
        watchlistSettings = controller
        controller.show()
    }

    /// 配置窗口点「保存」：写盘 + 重载 + 作废缓存里的行情。
    /// 返回是否写成功 —— 失败时窗口不关，用户的改动还留在界面上
    private func saveWatchlistConfig(_ config: WatchlistConfig) -> Bool {
        guard config.write() else {
            let alert = NSAlert()
            alert.messageText = "配置没能保存"
            alert.informativeText = "写不进 \(WatchlistConfig.fileURL.path)\n请检查目录权限或磁盘空间，改动还留在窗口里。"
            alert.addButton(withTitle: "知道了")
            alert.runModal()
            return false
        }
        applyWatchlistConfig()
        return true
    }

    /// 用默认编辑器打开配置文件（不存在会先按默认值生成一份）
    @objc private func openWatchlistConfig() {
        let url = WatchlistConfig.fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            WatchlistConfig.load().write(to: url)
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func reloadWatchlistConfig() {
        applyWatchlistConfig()
    }

    /// 重新从配置文件读清单与持仓。
    ///
    /// 行情缓存必须一起清掉：清单里删掉的代码若留在 `currentStockQuotes` /
    /// `dailyBars` 里，合计盈亏会把它算进去（面板上看不见，但数字是错的）。
    private func applyWatchlistConfig() {
        StockWatchlist.reload()
        StockHoldings.reload()
        currentStockQuotes = [:]
        dailyBars = [:]
        dailyBarsSessionKey = ""
        if hoverPanel?.isVisible == true { updateHoverPanelContent() }
    }

    // MARK: - 提醒

    private func makeReminderMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "提醒", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "提醒")

        // 菜单里只列前几条，多了就去「管理提醒…」里看 —— 免得下拉拉老长
        for reminder in reminderStore.reminders.prefix(Self.menuListLimit) {
            let entry = NSMenuItem(
                title: menuTitle(for: reminder),
                action: #selector(editReminder(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = reminder
            submenu.addItem(entry)
        }
        if reminderStore.reminders.count > Self.menuListLimit {
            let more = NSMenuItem(
                title: "还有 \(reminderStore.reminders.count - Self.menuListLimit) 条…",
                action: #selector(showReminderList),
                keyEquivalent: ""
            )
            more.target = self
            submenu.addItem(more)
        }
        if !reminderStore.reminders.isEmpty {
            submenu.addItem(.separator())
        }

        let manage = NSMenuItem(title: "管理提醒…", action: #selector(showReminderList), keyEquivalent: "")
        manage.target = self
        submenu.addItem(manage)

        let add = NSMenuItem(title: "添加提醒…", action: #selector(addReminder), keyEquivalent: "")
        add.target = self
        submenu.addItem(add)

        let waitItem = NSMenuItem(title: "提示后多久弹窗", action: nil, keyEquivalent: "")
        let waitSubmenu = NSMenu(title: "提示后多久弹窗")
        for option in ReminderAcknowledgeOption.allCases {
            let entry = NSMenuItem(
                title: option.title,
                action: #selector(selectReminderAcknowledge(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = option
            entry.state = option == reminderAcknowledge ? .on : .off
            waitSubmenu.addItem(entry)
        }
        menu.setSubmenu(waitSubmenu, for: waitItem)
        submenu.addItem(waitItem)

        let test = NSMenuItem(title: "测试：立即提醒", action: #selector(testReminder), keyEquivalent: "")
        test.target = self
        submenu.addItem(test)

        if !reminderStore.reminders.isEmpty {
            let clear = NSMenuItem(title: "清空全部", action: #selector(clearReminders), keyEquivalent: "")
            clear.target = self
            submenu.addItem(clear)
        }

        menu.setSubmenu(submenu, for: item)
        return item
    }

    /// 菜单里那一行。正在跑的倒计时把剩余时间顶在最前面，一拉开菜单就知道还剩多久
    /// （菜单每次打开都会重建，所以这个数字是新鲜的）
    private func menuTitle(for reminder: Reminder) -> String {
        guard let remaining = ReminderScheduler.remainingText(reminder, at: Date()) else {
            return reminder.summary
        }
        return "\(remaining)  \(reminder.summary)"
    }

    /// 气泡到弹窗的等待时间：只影响「两个提醒方式都勾」的那条路
    @objc private func selectReminderAcknowledge(_ sender: NSMenuItem) {
        guard let option = sender.representedObject as? ReminderAcknowledgeOption else { return }
        reminderAcknowledge = option
        reminderCenter.acknowledgeWindow = option.rawValue
        rebuildMenu()
        saveSettings()
    }

    /// 「提醒管理」窗口：定时提醒、倒计时、价格提醒都在一张表里
    @objc private func showReminderList() {
        let controller = reminderList ?? {
            let created = ReminderListController()
            created.displayName = { [weak self] target in self?.displayName(for: target) ?? "" }
            created.onAddReminder = { [weak self] in self?.showReminderDialog(editing: nil) }
            created.onAddPriceAlert = { [weak self] in self?.showPriceAlertDialog(editing: nil) }
            created.onEdit = { [weak self] entry in
                switch entry {
                case .reminder(let reminder): self?.showReminderDialog(editing: reminder)
                case .priceAlert(let alert): self?.showPriceAlertDialog(editing: alert)
                }
            }
            created.onDelete = { [weak self] entries in self?.deleteReminderEntries(entries) }
            created.onTest = { [weak self] in
                guard let self else { return }
                let sample = self.reminderStore.reminders.first
                    ?? Reminder(title: "测试提醒", body: "这是一条测试提醒", hour: 9, minute: 0)
                self.reminderCenter.presenter.fire(
                    title: sample.title,
                    body: sample.body,
                    methods: sample.methods,
                    key: UUID()
                )
            }
            return created
        }()
        reminderList = controller
        controller.show(reminders: reminderStore.reminders, priceAlerts: priceAlertStore.alerts)
    }

    private func deleteReminderEntries(_ entries: [ReminderListEntry]) {
        for entry in entries {
            switch entry {
            case .reminder(let reminder): reminderStore.remove(id: reminder.id)
            case .priceAlert(let alert): priceAlertStore.remove(id: alert.id)
            }
        }
        reminderCenter.reload()
        rebuildMenu()
        refreshReminderListIfVisible()
    }

    /// 增删改之后就地刷新管理窗口（没开着就什么都不做）
    private func refreshReminderListIfVisible() {
        reminderList?.refresh(reminders: reminderStore.reminders, priceAlerts: priceAlertStore.alerts)
    }

    @objc private func addReminder() {
        showReminderDialog(editing: nil)
    }

    @objc private func editReminder(_ sender: NSMenuItem) {
        guard let reminder = sender.representedObject as? Reminder else { return }
        showReminderDialog(editing: reminder)
    }

    @objc private func testReminder() {
        let sample = reminderStore.reminders.first
            ?? Reminder(title: "测试提醒", body: "这是一条测试提醒", hour: 9, minute: 0)
        reminderCenter.fire(sample)
    }

    /// 拖到边缘自动隐藏的开关：打开后拖到屏幕左右边缘直接收起人物，
    /// 想再见到它走上面的「显示人物」
    @objc private func toggleHideAtEdge() {
        hidesFloatingCharacterAtEdge.toggle()
        floatingCharacterController.hidesAtEdge = hidesFloatingCharacterAtEdge
        rebuildMenu()
        saveSettings()
    }

    @objc private func clearReminders() {
        reminderStore.removeAll()
        reminderCenter.reload()
        rebuildMenu()
        refreshReminderListIfVisible()
    }

    /// 添加 / 编辑提醒的对话框：定时（时刻 + 重复）或倒计时（时长 + 循环），
    /// 外加文案与两种提醒方式（宠物提示 / 弹窗）
    private func showReminderDialog(editing reminder: Reminder?) {
        let alert = NSAlert()
        alert.messageText = reminder == nil ? "添加提醒" : "编辑提醒"
        alert.informativeText = reminder == nil
            ? "定时精确到秒；倒计时会跑在人物头顶上，两种提醒方式可以都勾"
            : "改完点保存；也可以删除这条提醒"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        if reminder != nil { alert.addButton(withTitle: "删除") }

        let form = ReminderDialogView(reminder: reminder)
        alert.accessoryView = form
        alert.window.initialFirstResponder = form.firstResponderControl

        let response = alert.runModal()
        if response == .alertThirdButtonReturn, let reminder {
            reminderStore.remove(id: reminder.id)
            reminderCenter.reload()
            rebuildMenu()
            return
        }
        guard response == .alertFirstButtonReturn else { return }

        guard let edited = form.makeReminder(basedOn: reminder) else {
            NSSound.beep()
            return
        }
        reminderStore.upsert(edited)
        reminderCenter.reload()
        rebuildMenu()
        refreshReminderListIfVisible()
    }

    @objc
    private func quit() {
        NSApp.terminate(nil)
    }

    @objc
    private func toggleFloatingCharacter() {
        isFloatingCharacterVisible.toggle()
        floatingCharacterController.setVisible(isFloatingCharacterVisible)
        // 人物都藏起来了，它的聊天窗也别留着
        if !isFloatingCharacterVisible {
            chatController?.close()
        }
        rebuildMenu()
        saveSettings()
    }

    @objc
    private func selectFloatingCharacterSize(_ sender: NSMenuItem) {
        guard let option = sender.representedObject as? FloatingCharacterSizeOption else { return }
        floatingCharacterSize = option
        floatingCharacterController.setSize(option)
        rebuildMenu()
        saveSettings()
    }

    // MARK: - Price Alert

    private func checkPriceAlerts() {
        guard !priceAlertStore.alerts.isEmpty else { return }

        for alert in priceAlertStore.alerts {
            // 这只标的这轮没行情（停牌、接口没返回）就跳过，别拿旧价格去判
            guard let targetPrice = currentPrice(for: alert.target) else { continue }

            let outcome = PriceAlertEvaluator.evaluate(alert, price: targetPrice)
            // 闩锁变了就落盘：不落盘的话「不重复」的提醒重启后会再响一次
            if outcome.updated != alert {
                priceAlertStore.upsert(outcome.updated)
            }
            guard outcome.fired else { continue }

            reminderCenter.presenter.fire(
                title: "\(alert.direction.arrow) \(displayName(for: alert.target))",
                body: alert.displayMessage(price: targetPrice),
                methods: alert.methods,
                key: alert.id
            )
        }
    }

    /// 某个标的此刻的价格；没有可用价格就返回 nil
    private func currentPrice(for target: PriceAlert.Target) -> Double? {
        switch target {
        case .gold:
            return currentPrice > 0 ? currentPrice : nil
        case .stock(let code):
            return currentStockQuotes[code]?.numericPrice
        }
    }

    /// 菜单与提醒标题里用的显示名
    private func displayName(for target: PriceAlert.Target) -> String {
        switch target {
        case .gold:
            return "金价"
        case .stock(let code):
            if let quote = currentStockQuotes[code], !quote.name.isEmpty { return quote.name }
            return StockWatchlist.entries.first { $0.code == code }?.name ?? code
        }
    }

    /// 添加 / 编辑价格提醒
    @objc private func addPriceAlert() {
        showPriceAlertDialog(editing: nil)
    }

    @objc private func editPriceAlert(_ sender: NSMenuItem) {
        guard let alert = sender.representedObject as? PriceAlert else { return }
        showPriceAlertDialog(editing: alert)
    }

    @objc private func clearAllPriceAlerts() {
        priceAlertStore.removeAll()
        reminderCenter.presenter.cancelAll()
        rebuildMenu()
        refreshReminderListIfVisible()
    }

    private func showPriceAlertDialog(editing alert: PriceAlert?) {
        let form = PriceAlertDialogView(
            alert: alert,
            targets: PriceAlertDialogView.TargetOption.all(entries: StockWatchlist.entries)
        )

        let dialog = NSAlert()
        dialog.messageText = alert == nil ? "添加价格提醒" : "编辑价格提醒"
        dialog.informativeText = alert == nil
            ? "金价和股票都能盯；不填提示语就用「代码: 价格」"
            : "改完点保存；也可以删除这条"
        dialog.addButton(withTitle: "保存")
        dialog.addButton(withTitle: "取消")
        if alert != nil { dialog.addButton(withTitle: "删除") }
        dialog.accessoryView = form
        dialog.window.initialFirstResponder = form.firstResponderControl

        let response = dialog.runModal()
        if response == .alertThirdButtonReturn, let alert {
            priceAlertStore.remove(id: alert.id)
            reminderCenter.presenter.cancelAll()
            rebuildMenu()
            return
        }
        guard response == .alertFirstButtonReturn else { return }

        guard let edited = form.makeAlert(basedOn: alert) else {
            NSSound.beep()
            return
        }
        // 改了阈值/方向之后闩锁要归零，否则新条件要等价格先回到内侧才会响
        priceAlertStore.upsert(edited)
        rebuildMenu()
        refreshReminderListIfVisible()
    }

    private enum SettingsKey {
        static let provider = "selectedProvider"
        static let refreshInterval = "refreshInterval"
        static let floatingCharacterVisible = "floatingCharacterVisible"
        static let floatingCharacterSize = "floatingCharacterSize"
        static let reminderAcknowledge = "reminderAcknowledgeWindow"
        static let hidesAtEdge = "floatingCharacterHidesAtEdge"
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(selectedProvider == .zheShang ? "zheShang" : "minSheng", forKey: SettingsKey.provider)
        defaults.set(refreshInterval.rawValue, forKey: SettingsKey.refreshInterval)
        defaults.set(isFloatingCharacterVisible, forKey: SettingsKey.floatingCharacterVisible)
        defaults.set(floatingCharacterSize.rawValue, forKey: SettingsKey.floatingCharacterSize)
        defaults.set(reminderAcknowledge.rawValue, forKey: SettingsKey.reminderAcknowledge)
        defaults.set(hidesFloatingCharacterAtEdge, forKey: SettingsKey.hidesAtEdge)
    }

    private func loadSettings() {
        let defaults = UserDefaults.standard
        if let providerStr = defaults.string(forKey: SettingsKey.provider) {
            selectedProvider = providerStr == "minSheng" ? .minSheng : .zheShang
        }
        hidesFloatingCharacterAtEdge = defaults.bool(forKey: SettingsKey.hidesAtEdge)
        floatingCharacterController.hidesAtEdge = hidesFloatingCharacterAtEdge
        if let acknowledgeValue = defaults.object(forKey: SettingsKey.reminderAcknowledge) as? Double,
           let option = ReminderAcknowledgeOption(rawValue: acknowledgeValue) {
            reminderAcknowledge = option
        }
        reminderCenter.acknowledgeWindow = reminderAcknowledge.rawValue
        if let intervalValue = defaults.object(forKey: SettingsKey.refreshInterval) as? Double,
           let interval = RefreshIntervalOption(rawValue: intervalValue) {
            refreshInterval = interval
        }
        if defaults.object(forKey: SettingsKey.floatingCharacterVisible) != nil {
            isFloatingCharacterVisible = defaults.bool(forKey: SettingsKey.floatingCharacterVisible)
        }
        if let rawSize = defaults.object(forKey: SettingsKey.floatingCharacterSize) as? Double {
            // 老版本存过的 220 / 260 已经不在档位里了，按最接近的档位还原
            floatingCharacterSize = FloatingCharacterSizeOption.option(forPersistedValue: rawSize)
        }
    }

    // MARK: - Hover Panel

    private func setupHoverTracking() {
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Task { @MainActor in
                self?.handleMouseMove()
            }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Task { @MainActor in
                self?.handleMouseMove()
            }
            return event
        }
    }

    private func handleMouseMove() {
        guard !isMenuOpen,
              let button = statusItem.button,
              let buttonWindow = button.window else { return }

        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let mouseLocation = NSEvent.mouseLocation

        let isOverButton = buttonRect.contains(mouseLocation)

        let isOverPanel: Bool
        if let panel = hoverPanel, panel.isVisible {
            isOverPanel = panel.frame.contains(mouseLocation)
        } else {
            isOverPanel = false
        }

        if isOverButton && (hoverPanel == nil || !hoverPanel!.isVisible) {
            showHoverPanel(below: buttonRect)
        } else if !isOverButton && !isOverPanel {
            hoverPanel?.dismiss()
        }
    }

    /// 当日盈亏是否显示（交易日 09:00–15:30 之外不显示）
    private var showsTodayProfit: Bool {
        TradingDayDisplay.showsTodayProfit(at: Date(), holidays: holidays)
    }

    private func buildHoverPanelData() -> HoverPanelData {
        let info = currentPriceInfo
        let timeStr: String
        if let time = lastUpdateTime {
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm:ss"
            timeStr = fmt.string(from: time)
        } else {
            timeStr = "--:--:--"
        }

        var alertParts: [String] = []
        for alert in priceAlertStore.alerts(for: .gold) {
            alertParts.append("\(alert.direction.symbol) \(format(price: alert.threshold))")
        }
        let alertInfo = alertParts.isEmpty ? "未设置" : alertParts.joined(separator: " | ")

        return HoverPanelData(
            provider: selectedProvider.displayName,
            price: format(price: currentPrice),
            changeAmount: info.changeAmount,
            changePercent: info.changePercent,
            isNegative: info.isNegative,
            updateTime: timeStr,
            refreshInterval: refreshInterval.title,
            alertInfo: alertInfo,
            market: currentMarketData,
            stocks: StockWatchlist.entries.map { entry in
                let quote = currentStockQuotes[entry.code]
                    ?? .placeholder(code: entry.code, name: entry.name)
                return StockRow(
                    quote: quote,
                    volumeRatio: stockVolumeRatio(for: quote),
                    showsProfitLoss: showsTodayProfit
                )
            },
            unread: unreadCounts
        )
    }

    /// 休市时举牌显示的问候语；交易日返回 nil
    private func marketClosedGreeting() -> (headline: String, greeting: String)? {
        guard !MarketCalendar.isTradingDay(Date(), holidays: holidays) else { return nil }
        return MarketClosedGreeting.lines(
            for: Date(),
            holidayName: MarketCalendar.holidayName(on: Date(), holidays: holidays)
        )
    }

    /// 节假日按天刷新：启动时读本地缓存，每天再拉一次写回本地
    private func refreshHolidaysIfNeeded() {
        let year = MarketCalendar.HolidayCache.year(of: Date())
        if holidays.isEmpty {
            holidays = MarketCalendar.HolidayCache.load(year: year, from: .standard)
        }
        if makeupWorkdays.isEmpty {
            makeupWorkdays = MarketCalendar.HolidayCache.loadMakeupWorkdays(year: year, from: .standard)
        }
        guard holidayFetchDate.map({ !Calendar.current.isDate($0, inSameDayAs: Date()) }) ?? true else { return }
        holidayFetchDate = Date()

        Task { [weak self] in
            guard let self else { return }
            let fetched = await self.service.fetchHolidays(year: year)
            guard !fetched.holidays.isEmpty else { return }   // 拉不到就沿用缓存（可能为空 → 退化为只按周末判断）
            self.holidays = fetched.holidays
            self.makeupWorkdays = fetched.makeupWorkdays
            MarketCalendar.HolidayCache.save(fetched.holidays, year: year, to: .standard)
            MarketCalendar.HolidayCache.saveMakeupWorkdays(fetched.makeupWorkdays, year: year, to: .standard)
        }
    }

    /// 「交易日显示价格与盈亏 / 休市显示问候语」的决策收在这一处
    private func updateFloatingCharacter() {
        if let greeting = marketClosedGreeting() {
            floatingCharacterController.update(
                price: greeting.headline,
                numericPrice: currentPrice,
                isNegative: nil,
                profitLossText: greeting.greeting
            )
        } else {
            floatingCharacterController.update(
                price: format(price: currentPrice),
                numericPrice: currentPrice,
                isNegative: currentPriceInfo.isNegative,
                profitLossText: totalProfitLossText() ?? ""
            )
        }
    }

    /// 组合当日盈亏文本（如 "-8,055"）。没有可统计的持仓时返回 nil，举牌退回单行。
    ///
    /// 按自选清单顺序取行情再求和：顺序稳定，结果可复现。
    private func totalProfitLossText() -> String? {
        // 盘前/收盘后/非交易日不显示盈亏
        guard showsTodayProfit else { return nil }

        var quotesByCode: [String: StockQuote] = [:]
        for code in StockWatchlist.codes {
            quotesByCode[code] = currentStockQuotes[code]
        }
        guard let total = StockProfitLoss.totalToday(quotesByCode: quotesByCode) else { return nil }
        return HoldingFormat.profitLossText(total)
    }

    /// 量能倍数：预估全天量 ÷ 昨日全天量。
    private func stockVolumeRatio(for quote: StockQuote) -> Double? {
        guard !quote.sessionDate.isEmpty else { return nil }

        // 报价时间戳属于今天 ⟹ 今天确实有场次在跑 → 用实时进度折算；
        // 否则报价停留在上一场（周末 / 盘前 / 节假日）→ 进度按 1.0，直接显示那一场的收盘倍数。
        // 这个不对称是刻意的：冻结场景传 1.0，开盘 15 分钟的宽限就不会把上一场的收盘倍数也压掉。
        let progress = quote.sessionDate == TradingSession.dateString(for: Date())
            ? TradingSession.progress(at: Date())
            : 1.0

        return StockVolume.ratio(
            todayVolume: quote.volume,
            previousVolume: StockVolume.previousVolume(
                from: dailyBars[quote.code] ?? [],
                sessionDate: quote.sessionDate
            ),
            progress: progress
        )
    }

    private func showHoverPanel(below buttonRect: NSRect) {
        hoverPanel?.dismiss()

        let panel = HoverPanel()
        panel.show(below: buttonRect, data: buildHoverPanelData())
        hoverPanel = panel
    }

    private func updateHoverPanelContent() {
        hoverPanel?.updateContent(data: buildHoverPanelData())
    }
}

struct HoverPanelData {
    let provider: String
    let price: String
    let changeAmount: String
    let changePercent: String
    let isNegative: Bool?
    let updateTime: String
    let refreshInterval: String
    let alertInfo: String
    let market: MarketData
    let stocks: [StockRow]
    let unread: UnreadBadge.Counts
}

// MARK: - Hover Detail Panel

@MainActor
final class HoverPanel {
    private var window: NSPanel?
    private var buttonRect: NSRect = .zero

    // Mutable labels for live updates
    private var priceLabel: NSTextField?
    private var changeLabel: NSTextField?
    private var infoValueLabels: [String: NSTextField] = [:]
    private var marketValueLabels: [String: NSTextField] = [:]
    private var stockValueLabels: [String: NSTextField] = [:]
    private var stockTitleLabels: [String: NSTextField] = [:]
    private var stockVolumeLabels: [String: NSTextField] = [:]
    /// 左右两个未读徽标（左＝微信，右＝微信小号）
    private var weChatBadge: UnreadCountBadgeView?
    private var weChatSecondBadge: UnreadCountBadgeView?
    private var stockSharesLabels: [String: NSTextField] = [:]
    private var stockCostLabels: [String: NSTextField] = [:]
    private var stockFloatingLabels: [String: NSTextField] = [:]
    private var stockProfitLabels: [String: NSTextField] = [:]

    // 自选行是四列（名称+量能 | 股数 | 现价+涨跌幅 | 当日盈亏）。
    // 面板宽 = 内边距 × 2 + 三个间隙 + 四列宽度，这条等式有测试锁住。
    // 数值列宽度按实测的最宽内容定：股数 "1,100,000" 55.6pt、现价 "3936.52  -0.39%" 93.6pt、
    // 盈亏 "-1,234,567" 62.5pt；名称列吃剩余宽度（最宽 129.9pt）。
    static let panelWidth: CGFloat = 610
    static let padding: CGFloat = 16
    static let columnGap: CGFloat = 8
    static let volumeColumnWidth: CGFloat = 74
    static let sharesColumnWidth: CGFloat = 58
    static let costColumnWidth: CGFloat = 56
    static let priceColumnWidth: CGFloat = 96
    static let profitColumnWidth: CGFloat = 64
    static let floatingColumnWidth: CGFloat = 78
    /// 名称列吃剩余宽度。列多了之后这列变窄，加列时记得一起调 panelWidth
    static let nameColumnWidth: CGFloat = panelWidth - padding * 2 - columnGap * 6
        - volumeColumnWidth - sharesColumnWidth - costColumnWidth
        - priceColumnWidth - profitColumnWidth - floatingColumnWidth

    // 列表头文字（列宽测试会拿它们量宽度）
    static let volumeHeader = "量能"
    static let sharesHeader = "股数"
    static let costHeader = "成本"
    static let priceHeader = "现价"
    static let profitHeader = "当日盈亏"
    static let floatingHeader = "浮动盈亏"

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    var frame: NSRect {
        window?.frame ?? .zero
    }

    func show(below buttonRect: NSRect, data: HoverPanelData) {
        self.buttonRect = buttonRect

        let panelWidth = Self.panelWidth
        let padding = Self.padding
        let columnGap = Self.columnGap
        let labelColor = NSColor(white: 0.5, alpha: 1)
        let valueColor = NSColor(white: 0.85, alpha: 1)
        let sectionTitleColor = NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.0, alpha: 1)

        // Container
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.14, alpha: 0.96).cgColor
        container.layer?.cornerRadius = 12
        container.layer?.borderColor = NSColor(white: 0.3, alpha: 0.5).cgColor
        container.layer?.borderWidth = 0.5

        // --- Top section: Provider + Price + Change ---
        let providerLabel = NSTextField(labelWithString: data.provider)
        providerLabel.font = .systemFont(ofSize: 12, weight: .medium)
        providerLabel.textColor = labelColor
        providerLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(providerLabel)

        let pLabel = NSTextField(labelWithString: "\u{00A5} " + data.price)
        pLabel.font = .monospacedDigitSystemFont(ofSize: 26, weight: .bold)
        pLabel.textColor = .white
        pLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pLabel)
        self.priceLabel = pLabel

        let cLabel = NSTextField(labelWithString: "\(data.changeAmount)  \(data.changePercent)")
        cLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        cLabel.textColor = changeColor(for: data.isNegative)
        cLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(cLabel)
        self.changeLabel = cLabel

        // --- Divider 1 ---
        let divider1 = makeDivider()
        container.addSubview(divider1)

        // --- Market data section ---
        let marketTitle = NSTextField(labelWithString: "行情数据")
        marketTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        marketTitle.textColor = sectionTitleColor
        marketTitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(marketTitle)

        let m = data.market
        let marketRows: [(key: String, title: String, value: String, raise: Double)] = [
            ("londonGold", "伦敦金", formatValueWithPercent(price: m.londonGold.price, raisePercent: m.londonGold.raisePercent), m.londonGold.raise),
            ("goldTD", "黄金T+D", formatValueWithPercent(price: m.goldTD.price, raisePercent: m.goldTD.raisePercent), m.goldTD.raise),
            ("converted", "伦敦金换算 (¥/g)", m.convertedPrice > 0 ? String(format: "%.2f", m.convertedPrice) : "--", 0),
            ("premium", "溢价 (¥/g)", m.convertedPrice > 0 ? String(format: "%+.2f", m.premium) : "--", m.premium),
            ("usdcnh", "离岸人民币", formatValueWithPercent(price: m.usdCnh.price, raisePercent: m.usdCnh.raisePercent), m.usdCnh.raise),
            ("dxy", "美元指数", formatValueWithPercent(price: m.dollarIndex.price, raisePercent: m.dollarIndex.raisePercent), m.dollarIndex.raise),
        ]

        var marketLabelPairs: [(NSTextField, NSTextField)] = []
        for row in marketRows {
            let tl = NSTextField(labelWithString: row.title)
            tl.font = .systemFont(ofSize: 11, weight: .regular)
            tl.textColor = labelColor
            tl.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(tl)

            let vl = NSTextField(labelWithString: row.value)
            vl.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            vl.alignment = .right
            vl.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(vl)

            if row.key == "converted" {
                vl.textColor = valueColor
            } else {
                vl.textColor = raisedColor(row.raise, fallback: valueColor)
            }

            marketLabelPairs.append((tl, vl))
            marketValueLabels[row.key] = vl
        }

        // --- 自选行情 section ---
        // 行数恒等于 StockWatchlist.entries（没数据的先占位显示 "--"），
        // 因为面板高度是在 show() 里一次性算出来的。
        let stockSectionTitle = NSTextField(labelWithString: "自选行情")
        stockSectionTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        stockSectionTitle.textColor = sectionTitleColor
        stockSectionTitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stockSectionTitle)

        // 名称列：唯一允许被截断的一列，所以压缩阻力最低
        func makeStockTitleLabel() -> NSTextField {
            let label = NSTextField(labelWithString: "")
            // 名称列的颜色要和其他标签一致（拆列时漏了这行，导致名称变成系统默认的亮白）
            label.textColor = labelColor
            label.lineBreakMode = .byTruncatingTail
            label.usesSingleLineMode = true
            label.maximumNumberOfLines = 1
            // 预算不够时只截断名称；两侧都不要用 .required，否则真挤不下时会打
            // "Unable to simultaneously satisfy constraints"。其余列 751 保证数字永远完整。
            label.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(749), for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            return label
        }

        func makeStockCell(_ text: String, weight: NSFont.Weight, color: NSColor) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: weight)
            label.textColor = color
            // 整张表都左对齐：每列起始位置固定，读起来是整齐的表格
            label.alignment = .left
            label.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(751), for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            return label
        }

        typealias StockCells = (
            title: NSTextField, volume: NSTextField, shares: NSTextField,
            cost: NSTextField, value: NSTextField, profit: NSTextField, floating: NSTextField
        )
        var stockRowCells: [StockCells] = []

        // 列表头。名称格给一个空格而不是空串：NSTextField 空串的固有高度是 0，
        // 会把这一行压扁（行高取自名称格）。
        let headerTitle = makeStockTitleLabel()
        headerTitle.stringValue = " "
        stockRowCells.append((
            headerTitle,
            makeStockCell(Self.volumeHeader, weight: .medium, color: labelColor),
            makeStockCell(Self.sharesHeader, weight: .regular, color: labelColor),
            makeStockCell(Self.costHeader, weight: .regular, color: labelColor),
            makeStockCell(Self.priceHeader, weight: .regular, color: labelColor),
            makeStockCell(Self.profitHeader, weight: .regular, color: labelColor),
            makeStockCell(Self.floatingHeader, weight: .regular, color: labelColor)
        ))

        for row in data.stocks {
            let quote = row.quote

            // 名称单独一列；倍数与「放量/缩量」各占一列，这样数字才能竖向对齐
            let tl = makeStockTitleLabel()
            tl.stringValue = quote.name

            let volumeLabel = makeStockCell(
                StockVolume.volumeText(row.volumeRatio),
                weight: .medium,
                color: HoverPalette.volumeColor(for: StockVolume.word(for: row.volumeRatio))
            )

            let sharesLabel = makeStockCell(row.sharesText, weight: .regular, color: valueColor)
            let costLabel = makeStockCell(row.costText, weight: .regular, color: valueColor)
            let vl = makeStockCell(
                formatValueWithPercent(price: quote.price, raisePercent: quote.raisePercent),
                weight: .medium,
                color: raisedColor(quote.raise, fallback: valueColor)
            )
            let profitLabel = makeStockCell(
                row.profitLossText,
                weight: .medium,
                color: HoverPalette.trendColor(row.profitLoss, fallback: valueColor)
            )

            let floatingLabel = makeStockCell(
                row.floatingProfitText,
                weight: .medium,
                color: HoverPalette.trendColor(row.floatingProfit, fallback: valueColor)
            )

            stockRowCells.append((tl, volumeLabel, sharesLabel, costLabel, vl, profitLabel, floatingLabel))
            stockTitleLabels[quote.code] = tl
            stockVolumeLabels[quote.code] = volumeLabel
            stockSharesLabels[quote.code] = sharesLabel
            stockCostLabels[quote.code] = costLabel
            stockFloatingLabels[quote.code] = floatingLabel
            stockValueLabels[quote.code] = vl
            stockProfitLabels[quote.code] = profitLabel
        }

        // --- 未读徽标（贴在面板左右上角）---
        let leftBadge = UnreadCountBadgeView()
        let rightBadge = UnreadCountBadgeView()
        leftBadge.translatesAutoresizingMaskIntoConstraints = false
        rightBadge.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(leftBadge)
        container.addSubview(rightBadge)
        weChatBadge = leftBadge
        weChatSecondBadge = rightBadge
        leftBadge.update(data.unread.weChat)
        rightBadge.update(data.unread.weChatSecond)

        // --- Divider 2 ---
        let divider2 = makeDivider()
        container.addSubview(divider2)

        // --- Info section ---
        let infoRows: [(key: String, title: String, value: String)] = [
            ("updateTime", "更新时间", data.updateTime),
            ("refreshInterval", "刷新频率", data.refreshInterval),
            ("alert", "价格提醒", data.alertInfo),
        ]

        var infoLabelPairs: [(NSTextField, NSTextField)] = []
        for row in infoRows {
            let tl = NSTextField(labelWithString: row.title)
            tl.font = .systemFont(ofSize: 11, weight: .regular)
            tl.textColor = labelColor
            tl.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(tl)

            let vl = NSTextField(labelWithString: row.value)
            vl.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            vl.textColor = valueColor
            vl.alignment = .right
            vl.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(vl)

            infoLabelPairs.append((tl, vl))
            infoValueLabels[row.key] = vl
        }

        // --- Layout ---
        var constraints: [NSLayoutConstraint] = [
            providerLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            providerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),

            pLabel.topAnchor.constraint(equalTo: providerLabel.bottomAnchor, constant: 4),
            pLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),

            cLabel.topAnchor.constraint(equalTo: pLabel.bottomAnchor, constant: 2),
            cLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),

            divider1.topAnchor.constraint(equalTo: cLabel.bottomAnchor, constant: 12),
            divider1.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            divider1.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            divider1.heightAnchor.constraint(equalToConstant: 0.5),

            marketTitle.topAnchor.constraint(equalTo: divider1.bottomAnchor, constant: 10),
            marketTitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
        ]

        var prev = marketTitle.bottomAnchor
        for (i, (tl, vl)) in marketLabelPairs.enumerated() {
            let top: CGFloat = i == 0 ? 8 : 5
            constraints.append(contentsOf: [
                tl.topAnchor.constraint(equalTo: prev, constant: top),
                tl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
                vl.centerYAnchor.constraint(equalTo: tl.centerYAnchor),
                vl.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
                vl.leadingAnchor.constraint(greaterThanOrEqualTo: tl.trailingAnchor, constant: 8),
            ])
            prev = tl.bottomAnchor
        }

        constraints.append(contentsOf: [
            divider2.topAnchor.constraint(equalTo: prev, constant: 10),
            divider2.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            divider2.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            divider2.heightAnchor.constraint(equalToConstant: 0.5),
        ])

        prev = divider2.bottomAnchor
        constraints.append(contentsOf: [
            stockSectionTitle.topAnchor.constraint(equalTo: prev, constant: 10),
            stockSectionTitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
        ])

        constraints.append(contentsOf: [
            leftBadge.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: -6),
            leftBadge.topAnchor.constraint(equalTo: container.topAnchor, constant: -6),
            rightBadge.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: 6),
            rightBadge.topAnchor.constraint(equalTo: container.topAnchor, constant: -6),
        ])

        prev = stockSectionTitle.bottomAnchor
        for (i, cells) in stockRowCells.enumerated() {
            let top: CGFloat = i == 0 ? 8 : 5
            // 每列都是固定宽度、左对齐，所以每行的每一列都从同一 x 开始 —— 这样才齐
            constraints.append(contentsOf: [
                cells.title.topAnchor.constraint(equalTo: prev, constant: top),
                cells.title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
                cells.title.widthAnchor.constraint(equalToConstant: Self.nameColumnWidth),

                cells.volume.leadingAnchor.constraint(equalTo: cells.title.trailingAnchor, constant: columnGap),
                cells.volume.centerYAnchor.constraint(equalTo: cells.title.centerYAnchor),
                cells.volume.widthAnchor.constraint(equalToConstant: Self.volumeColumnWidth),

                cells.shares.leadingAnchor.constraint(equalTo: cells.volume.trailingAnchor, constant: columnGap),
                cells.shares.centerYAnchor.constraint(equalTo: cells.title.centerYAnchor),
                cells.shares.widthAnchor.constraint(equalToConstant: Self.sharesColumnWidth),

                cells.cost.leadingAnchor.constraint(equalTo: cells.shares.trailingAnchor, constant: columnGap),
                cells.cost.centerYAnchor.constraint(equalTo: cells.title.centerYAnchor),
                cells.cost.widthAnchor.constraint(equalToConstant: Self.costColumnWidth),

                cells.value.leadingAnchor.constraint(equalTo: cells.cost.trailingAnchor, constant: columnGap),
                cells.value.centerYAnchor.constraint(equalTo: cells.title.centerYAnchor),
                cells.value.widthAnchor.constraint(equalToConstant: Self.priceColumnWidth),

                cells.profit.leadingAnchor.constraint(equalTo: cells.value.trailingAnchor, constant: columnGap),
                cells.profit.centerYAnchor.constraint(equalTo: cells.title.centerYAnchor),
                cells.profit.widthAnchor.constraint(equalToConstant: Self.profitColumnWidth),

                cells.floating.leadingAnchor.constraint(equalTo: cells.profit.trailingAnchor, constant: columnGap),
                cells.floating.centerYAnchor.constraint(equalTo: cells.title.centerYAnchor),
                cells.floating.widthAnchor.constraint(equalToConstant: Self.floatingColumnWidth),
            ])
            prev = cells.title.bottomAnchor
        }

        // --- Divider 3 (信息段) ---
        let divider3 = makeDivider()
        container.addSubview(divider3)
        constraints.append(contentsOf: [
            divider3.topAnchor.constraint(equalTo: prev, constant: 10),
            divider3.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            divider3.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            divider3.heightAnchor.constraint(equalToConstant: 0.5),
        ])

        prev = divider3.bottomAnchor
        for (i, (tl, vl)) in infoLabelPairs.enumerated() {
            let top: CGFloat = i == 0 ? 8 : 5
            constraints.append(contentsOf: [
                tl.topAnchor.constraint(equalTo: prev, constant: top),
                tl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
                vl.centerYAnchor.constraint(equalTo: tl.centerYAnchor),
                vl.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
                vl.leadingAnchor.constraint(greaterThanOrEqualTo: tl.trailingAnchor, constant: 8),
            ])
            prev = tl.bottomAnchor
        }

        constraints.append(prev.constraint(equalTo: container.bottomAnchor, constant: -padding))
        NSLayoutConstraint.activate(constraints)

        // Size and position — force a layout pass first so fittingSize is accurate
        container.translatesAutoresizingMaskIntoConstraints = false
        // Give container a temporary width constraint so it can resolve height
        let tempWidthConstraint = container.widthAnchor.constraint(equalToConstant: panelWidth)
        tempWidthConstraint.isActive = true
        container.layoutSubtreeIfNeeded()
        tempWidthConstraint.isActive = false

        let fittingSize = container.fittingSize
        // Guard against zero/negative dimensions which cause the WindowServer error
        let panelHeight = max(fittingSize.height, 100)
        let panelX = buttonRect.midX - panelWidth / 2
        let panelY = buttonRect.minY - panelHeight - 4

        // Clamp to screen bounds
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let clampedX = max(screenFrame.minX, min(panelX, screenFrame.maxX - panelWidth))
        let clampedY = max(screenFrame.minY, min(panelY, screenFrame.maxY - panelHeight))

        let panel = NSPanel(
            contentRect: NSRect(x: clampedX, y: clampedY, width: panelWidth, height: panelHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.contentView = container
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }

        self.window = panel
    }

    func updateContent(data: HoverPanelData) {
        priceLabel?.stringValue = "\u{00A5} " + data.price
        changeLabel?.stringValue = "\(data.changeAmount)  \(data.changePercent)"
        changeLabel?.textColor = changeColor(for: data.isNegative)

        infoValueLabels["updateTime"]?.stringValue = data.updateTime
        infoValueLabels["refreshInterval"]?.stringValue = data.refreshInterval
        infoValueLabels["alert"]?.stringValue = data.alertInfo

        let m = data.market
        let fallback = NSColor(white: 0.85, alpha: 1)

        marketValueLabels["londonGold"]?.stringValue = formatValueWithPercent(price: m.londonGold.price, raisePercent: m.londonGold.raisePercent)
        marketValueLabels["londonGold"]?.textColor = raisedColor(m.londonGold.raise, fallback: fallback)

        marketValueLabels["goldTD"]?.stringValue = formatValueWithPercent(price: m.goldTD.price, raisePercent: m.goldTD.raisePercent)
        marketValueLabels["goldTD"]?.textColor = raisedColor(m.goldTD.raise, fallback: fallback)

        marketValueLabels["converted"]?.stringValue = m.convertedPrice > 0 ? String(format: "%.2f", m.convertedPrice) : "--"

        marketValueLabels["premium"]?.stringValue = m.convertedPrice > 0 ? String(format: "%+.2f", m.premium) : "--"
        marketValueLabels["premium"]?.textColor = raisedColor(m.premium, fallback: fallback)

        marketValueLabels["usdcnh"]?.stringValue = formatValueWithPercent(price: m.usdCnh.price, raisePercent: m.usdCnh.raisePercent)
        marketValueLabels["usdcnh"]?.textColor = raisedColor(m.usdCnh.raise, fallback: fallback)

        marketValueLabels["dxy"]?.stringValue = formatValueWithPercent(price: m.dollarIndex.price, raisePercent: m.dollarIndex.raisePercent)
        marketValueLabels["dxy"]?.textColor = raisedColor(m.dollarIndex.raise, fallback: fallback)

        for row in data.stocks {
            let quote = row.quote
            stockValueLabels[quote.code]?.stringValue =
                formatValueWithPercent(price: quote.price, raisePercent: quote.raisePercent)
            stockValueLabels[quote.code]?.textColor = raisedColor(quote.raise, fallback: fallback)
            stockTitleLabels[quote.code]?.stringValue = quote.name
            weChatBadge?.update(data.unread.weChat)
        weChatSecondBadge?.update(data.unread.weChatSecond)

        stockVolumeLabels[quote.code]?.stringValue = StockVolume.volumeText(row.volumeRatio)
            stockVolumeLabels[quote.code]?.textColor =
                HoverPalette.volumeColor(for: StockVolume.word(for: row.volumeRatio))

            // 持仓两列：无持仓时是空串（留白）
            stockSharesLabels[quote.code]?.stringValue = row.sharesText
            stockCostLabels[quote.code]?.stringValue = row.costText
            stockFloatingLabels[quote.code]?.stringValue = row.floatingProfitText
            stockFloatingLabels[quote.code]?.textColor = HoverPalette.trendColor(row.floatingProfit, fallback: fallback)
            stockProfitLabels[quote.code]?.stringValue = row.profitLossText
            stockProfitLabels[quote.code]?.textColor = HoverPalette.trendColor(row.profitLoss, fallback: fallback)
        }
    }

    func dismiss() {
        guard let window = self.window else { return }
        self.window = nil
        priceLabel = nil
        changeLabel = nil
        infoValueLabels.removeAll()
        marketValueLabels.removeAll()
        stockValueLabels.removeAll()
        stockTitleLabels.removeAll()
        stockVolumeLabels.removeAll()
        weChatBadge = nil
        weChatSecondBadge = nil
        stockSharesLabels.removeAll()
        stockCostLabels.removeAll()
        stockFloatingLabels.removeAll()
        stockProfitLabels.removeAll()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            window.animator().alphaValue = 0
        }, completionHandler: {
            DispatchQueue.main.async {
                window.orderOut(nil)
            }
        })
    }

    // MARK: - Helpers

    private func changeColor(for isNegative: Bool?) -> NSColor {
        guard let isNeg = isNegative else { return .secondaryLabelColor }
        return isNeg ? HoverPalette.fall : HoverPalette.rise
    }

    private func raisedColor(_ raise: Double, fallback: NSColor) -> NSColor {
        HoverPalette.trendColor(raise, fallback: fallback)
    }

    private func formatValueWithPercent(price: String, raisePercent: Double) -> String {
        guard price != "--" else { return price }
        let pctValue = raisePercent * 100
        let truncated = (pctValue * 100).rounded(.towardZero) / 100
        let sign = truncated > 0 ? "+" : ""
        return String(format: "%@  %@%.2f%%", price, sign, truncated)
    }

    /// 给约束降优先级用（列对齐约束不需要 required）
    private func priority(_ constraint: NSLayoutConstraint, _ value: Float) -> NSLayoutConstraint {
        constraint.priority = NSLayoutConstraint.Priority(value)
        return constraint
    }

    private func makeDivider() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 0.3, alpha: 0.5).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }
}

@main
struct MarketBarApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.mainMenu = makeEditMenu()
        app.run()
    }

    /// 这个菜单**永远不会显示**（app 是 .accessory，没有菜单栏），它的唯一作用是让
    /// ⌘V / ⌘C / ⌘X / ⌘A / ⌘Z 这些编辑快捷键能通过菜单路由进到文本视图。
    /// 不加的话：聊天输入框能打字，但粘贴、复制、全选全都没反应。
    /// （顺带修好了「价格提醒」输入框的同一个问题。）
    static func makeEditMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        mainMenu.addItem(editItem)

        return mainMenu
    }
}
