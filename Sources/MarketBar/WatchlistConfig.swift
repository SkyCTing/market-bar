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

    static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("MarketBar", isDirectory: true)
            .appendingPathComponent("watchlist.json")
    }

    /// 读配置：文件不存在就用默认值生成一份；文件损坏则回退默认值（并保留坏文件供排查）
    static func load(from url: URL = fileURL) -> WatchlistConfig {
        if let data = try? Data(contentsOf: url) {
            if let decoded = try? JSONDecoder().decode(WatchlistConfig.self, from: data) {
                return decoded
            }
            // 坏文件：改名留证，避免每次启动都解析失败
            try? FileManager.default.moveItem(
                at: url,
                to: url.deletingPathExtension().appendingPathExtension("broken.json")
            )
        }
        let config = WatchlistConfig.default
        config.write(to: url)
        return config
    }

    func write(to url: URL = fileURL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? encoder.encode(self).write(to: url, options: .atomic)
    }
}
