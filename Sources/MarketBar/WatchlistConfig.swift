import Foundation

/// 自选清单与持仓的配置文件。
///
/// 以前这两份数据写死在代码里（`StockWatchlist` / `StockHoldings`），改一只标的都得重编译；
/// 现在放在 `~/Library/Application Support/MarketBar/watchlist.json`，改完在菜单里点「重新载入配置」即可。
/// 文件不存在时会自动用内置默认值生成一份，所以升级上来不会丢东西。
struct WatchlistConfig: Codable, Equatable {
    struct Item: Codable, Equatable, Sendable {
        var code: String   // 腾讯行情代码，如 "sh512170"
        var name: String   // 显示名（写死，不用接口返回的 GBK 名称）
    }

    var watchlist: [Item]
    var holdings: [String: Int]
    /// 每只的持仓成本（每股均价）。没设过的不在字典里
    var costs: [String: Double] = [:]

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
        ],
        costs: [:]
    )

    /// ⚠️ 必须手写：合成的解码器**不会**用属性默认值，缺键直接抛 keyNotFound。
    /// `costs` 是后加的，老配置文件没有这个键 —— 用合成的解码器会把用户的整份清单
    /// 当成坏文件、备份走再回退成内置默认值。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        watchlist = try container.decode([Item].self, forKey: .watchlist)
        holdings = try container.decode([String: Int].self, forKey: .holdings)
        costs = try container.decodeIfPresent([String: Double].self, forKey: .costs) ?? [:]
    }

    init(watchlist: [Item], holdings: [String: Int], costs: [String: Double] = [:]) {  // swiftlint:disable:this line_length
        self.watchlist = watchlist
        self.holdings = holdings
        self.costs = costs
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
