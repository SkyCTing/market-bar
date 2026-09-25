import Foundation

/// 自选清单与持仓的配置文件。
///
/// 以前这两份数据写死在代码里（`StockWatchlist` / `StockHoldings`），改一只标的都得重编译；
/// 现在放在 `~/Library/Application Support/MarketBar/watchlist.json`，改完在菜单里点「重新载入配置」即可。
/// 文件不存在时会自动用内置默认值生成一份，所以升级上来不会丢东西。
struct WatchlistConfig: Codable, Equatable {
    /// 一只标的的全部信息都在这儿 —— 名字、股数、成本放一起。
    ///
    /// 原来是三份按 code 索引的数据（`watchlist` 放名字、`holdings` 放股数、
    /// `costs` 放成本），一只标的的资料散在三个地方，改一处要同步三处。
    struct Item: Codable, Equatable, Sendable {
        var code: String   // 腾讯行情代码，如 "sh512170"
        var name: String   // 显示名（写死，不用接口返回的 GBK 名称）
        /// 持仓股数；nil / 非正 = 只看不持
        var shares: Int?
        /// 每股持仓成本（均价）；nil = 没设过
        var cost: Double?

        init(code: String, name: String, shares: Int? = nil, cost: Double? = nil) {
            self.code = code
            self.name = name
            self.shares = shares
            self.cost = cost
        }
    }

    var watchlist: [Item]

    /// 持仓表（派生）。保留这个视图是因为不少地方按 code 索引取股数
    var holdings: [String: Int] {
        watchlist.reduce(into: [:]) { result, item in
            if let shares = item.shares, shares > 0 { result[item.code] = shares }
        }
    }

    /// 成本表（派生）
    var costs: [String: Double] {
        watchlist.reduce(into: [:]) { result, item in
            if let cost = item.cost, cost > 0 { result[item.code] = cost }
        }
    }

    /// 内置默认值：首次运行会把它写成配置文件
    static let `default` = WatchlistConfig(
        watchlist: [
            Item(code: "sh000001", name: "上证指数"),
            Item(code: "sh512170", name: "医疗ETF华宝"),
            Item(code: "sz159813", name: "半导体ETF鹏华"),
            Item(code: "sh513130", name: "恒生科技ETF"),
            Item(code: "sz159567", name: "港股创新药ETF"),
            Item(code: "sz300657", name: "弘信电子"),
            Item(code: "sz300375", name: "鹏翎股份"),
            Item(code: "sh600036", name: "招商银行"),
            Item(code: "sz000564", name: "供销大集"),
            Item(code: "sz300803", name: "指南针"),
            Item(code: "sz300468", name: "四方精创"),
            Item(code: "sz002657", name: "中科金财"),
            Item(code: "sz300339", name: "润和软件"),
            Item(code: "sh603406", name: "天富龙"),
            Item(code: "sz301609", name: "山大电力"),
            Item(code: "sz000034", name: "神州数码"),
        ],
        holdings: [
            "sh600036": 1_500,
            "sz300803": 435,
            "sz000034": 980,
            "sz300339": 500,
            "sz002657": 1_100,
            "sz300468": 700,
            "sz300657": 400,
            "sz000564": 10_000,
            "sh603406": 400,
            "sz300375": 2_000,
            "sz301609": 200,
            "sh513130": 880_000,
            "sh512170": 1_100_000,
            "sz159813": 140_000,
            "sz159567": 110_000,
        ]
    )

    /// 只有 `watchlist` 会被写出去；`holdings` / `costs` 只是给老文件读的键
    enum CodingKeys: String, CodingKey {
        case watchlist
        /// 老格式才有的两个键（见 init(from:)）
        case holdings, costs
    }

    /// ⚠️ 必须手写：合成的解码器**不会**用属性默认值，老文件缺 `shares` / `cost`
    /// 两个键时直接抛 keyNotFound —— 那会把用户的整份清单当成坏文件、
    /// 备份走再回退成内置默认值。
    ///
    /// 老格式把股数和成本放在 `holdings` / `costs` 两个独立字典里，
    /// 这里读进来合并进各自的条目，写回去就成新格式了。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let items = try container.decode([Item].self, forKey: .watchlist)
        let legacyShares = try container.decodeIfPresent([String: Int].self, forKey: .holdings) ?? [:]
        let legacyCosts = try container.decodeIfPresent([String: Double].self, forKey: .costs) ?? [:]

        // ⚠️ 老格式允许 holdings / costs 里有清单里没有的代码（配置窗口会把这类补成行
        // 显示，免得它们看不见就被静默丢掉）。合并时要把它们补成条目，
        // 否则升级一次这些持仓就没了
        watchlist = Self.merging(items, shares: legacyShares, costs: legacyCosts)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(watchlist, forKey: .watchlist)
    }

    /// 便利构造：从「代码 → 股数 / 成本」两张表拼出来（老的调用点还能用）。
    /// 和 `init(from:)` 一样，清单里没有的代码也要补成条目
    init(watchlist: [Item], holdings: [String: Int] = [:], costs: [String: Double] = [:]) {
        // ⚠️ 不能写 self.init(watchlist: watchlist) —— 那个签名和这里同名，
        // 会解析成它自己，直接栈溢出（signal 11）
        self.watchlist = Self.merging(watchlist, shares: holdings, costs: costs)
    }

    /// 把「代码 → 股数 / 成本」两张表合并进条目；清单里没有的代码补成新条目
    private static func merging(
        _ items: [Item],
        shares: [String: Int],
        costs: [String: Double]
    ) -> [Item] {
        var merged = items.map { item -> Item in
            var copy = item
            if copy.shares == nil { copy.shares = shares[item.code] }
            if copy.cost == nil { copy.cost = costs[item.code] }
            return copy
        }
        let listed = Set(items.map(\.code))
        let orphans = Set(shares.keys).union(costs.keys).subtracting(listed).sorted()
        // 名字留空：配置窗口里是个空单元格 + 占位符，提示用户去补；
        // 写回时 WatchlistDraft 会用代码兜底，所以不会存成空白名
        merged.append(contentsOf: orphans.map {
            Item(code: $0, name: "", shares: shares[$0], cost: costs[$0])
        })
        return merged
    }

    static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("MarketBar", isDirectory: true)
            .appendingPathComponent("watchlist.json")
    }

    /// 读配置：文件不存在就用默认值生成一份；文件损坏则**先留副本**再回退默认值
    static func load(from url: URL = fileURL) -> WatchlistConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let config = WatchlistConfig.default
            config.write(to: url)
            return config
        }

        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(WatchlistConfig.self, from: data) {
            return decoded
        }

        // 走到这里说明文件在、但读不出来或者解不开。
        //
        // ⚠️ 原来的写法是「改名成 broken.json」，两种情况会静默吃掉用户配置：
        //   1. broken.json 已经存在 → moveItem 失败被 try? 吞掉 → 紧接着被默认值覆盖
        //   2. Data(contentsOf:) 本身抛错 → 改名那段根本不在执行路径上 → 同样直接覆盖
        // 现在改成**先复制一份带时间戳的副本**（绝不覆盖已有副本）再回退
        backUpCorruptFile(url)

        let config = WatchlistConfig.default
        config.write(to: url)
        return config
    }

    /// 给读不出来的配置留副本。用 copy 不用 move：万一下面的写入也失败，
    /// 原文件还在。名字撞了就加时间戳，绝不覆盖已有的副本。
    private static func backUpCorruptFile(_ url: URL) {
        let base = url.deletingPathExtension()
        let stamp = Int(Date().timeIntervalSince1970)
        for candidate in [
            base.appendingPathExtension("broken.json"),
            base.appendingPathExtension("broken-\(stamp).json"),
        ] where !FileManager.default.fileExists(atPath: candidate.path) {
            if (try? FileManager.default.copyItem(at: url, to: candidate)) != nil { return }
        }
    }

    /// 写配置。返回是否真的写成功了 —— 原来吞掉所有错误，
    /// 「磁盘满 / 目录不可写」时会伪装成保存成功，用户的改动无声消失。
    @discardableResult
    func write(to url: URL = fileURL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(self).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
