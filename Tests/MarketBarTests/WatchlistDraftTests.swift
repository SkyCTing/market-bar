import Foundation
import XCTest

@testable import MarketBar

/// 配置页面的编辑草稿：表格 ↔ 配置文件的换算、代码补全、校验。
final class WatchlistDraftTests: XCTestCase {

    // MARK: - 铺开

    func testDraftKeepsOrderAndAttachesShares() {
        let config = WatchlistConfig(
            watchlist: [
                .init(code: "sh600036", name: "招商银行"),
                .init(code: "sh000001", name: "上证指数"),
            ],
            holdings: ["sh600036": 1_500]
        )

        let draft = WatchlistDraft(config: config)

        XCTAssertEqual(draft.rows.map(\.code), ["sh600036", "sh000001"])
        XCTAssertEqual(draft.rows.map(\.name), ["招商银行", "上证指数"])
        XCTAssertEqual(draft.rows[0].shares, 1_500)
        XCTAssertNil(draft.rows[1].shares, "没持仓的应该是 nil，不是 0")
    }

    /// 持仓里有、自选里没有的代码必须补成一行 —— 否则它永远不出现在页面上，
    /// 用户点一次保存就被静默抹掉了。
    func testOrphanHoldingBecomesItsOwnRow() {
        let config = WatchlistConfig(
            watchlist: [.init(code: "sh600036", name: "招商银行")],
            holdings: ["sh600036": 1_500, "sz300750": 200]
        )

        let draft = WatchlistDraft(config: config)

        XCTAssertEqual(draft.rows.map(\.code), ["sh600036", "sz300750"])
        XCTAssertEqual(draft.rows[1].shares, 200)
        XCTAssertEqual(draft.rows[1].name, "", "名字待用户补")
    }

    // MARK: - 回写

    func testRoundTripThroughDraftKeepsEverything() {
        let config = WatchlistConfig.default

        XCTAssertEqual(WatchlistDraft(config: config).config(), config)
    }

    func testEmptyNameFallsBackToCode() {
        let draft = WatchlistDraft(rows: [WatchlistRow(code: "sh600036", name: "", shares: nil)])

        XCTAssertEqual(draft.config().watchlist.first?.name, "sh600036")
    }

    func testNonPositiveSharesAreDropped() {
        let draft = WatchlistDraft(rows: [
            WatchlistRow(code: "sh600036", name: "招商银行", shares: 0),
            WatchlistRow(code: "sh000001", name: "上证指数", shares: -5),
            WatchlistRow(code: "sz300750", name: "宁德时代", shares: 100),
        ])

        XCTAssertEqual(draft.config().holdings, ["sz300750": 100])
    }

    /// 代码被清空的那一行不该混进配置（保存前会先被 issues() 拦下，这里是兜底）
    func testEmptyCodeRowIsDroppedOnSave() {
        let draft = WatchlistDraft(rows: [
            WatchlistRow(code: "sh600036", name: "招商银行", shares: nil),
            WatchlistRow(code: "", name: "", shares: nil),
        ])

        XCTAssertEqual(draft.config().watchlist.map(\.code), ["sh600036"])
    }

    // MARK: - 代码补全

    func testNormalizeCodeAddsExchangePrefix() {
        XCTAssertEqual(WatchlistDraft.normalizeCode("600036"), "sh600036")
        XCTAssertEqual(WatchlistDraft.normalizeCode("000001"), "sz000001")
        XCTAssertEqual(WatchlistDraft.normalizeCode("300750"), "sz300750")
        XCTAssertEqual(WatchlistDraft.normalizeCode("830799"), "bj830799")   // 北交所
        XCTAssertEqual(WatchlistDraft.normalizeCode("430047"), "bj430047")
    }

    /// ⚠️ 这条本该一开始就有：默认清单里 16 只有 4 只是 ETF（1 / 5 开头），
    /// 前缀表漏掉那两个号段的话，用户按提示只打 6 位数字会被判成非法代码、保存直接被拦。
    /// 逐只走一遍，任何号段再漏都会立刻红。
    func testEveryDefaultCodeCanBeTypedAsSixDigits() {
        // 000001 同时是上证指数（sh）和平安银行（sz），补前缀只能给一个 —— 真歧义，不算漏
        let ambiguous = ["sh000001"]

        for item in WatchlistConfig.default.watchlist {
            let bare = String(item.code.dropFirst(2))
            let normalized = WatchlistDraft.normalizeCode(bare)

            if ambiguous.contains(item.code) {
                XCTAssertTrue(WatchlistDraft.isValidCode(normalized), "\(bare) 至少要补成一个合法代码")
                continue
            }
            XCTAssertEqual(
                normalized,
                item.code,
                "\(item.name)（\(item.code)）只打 \(bare) 补不出前缀"
            )
        }
    }

    /// 基金 / ETF 的号段（app 自带清单里就有）
    func testNormalizeCodeCoversFundAndEtfRanges() {
        XCTAssertEqual(WatchlistDraft.normalizeCode("512170"), "sh512170", "沪市 ETF")
        XCTAssertEqual(WatchlistDraft.normalizeCode("159813"), "sz159813", "深市 ETF")
        XCTAssertEqual(WatchlistDraft.normalizeCode("200011"), "sz200011", "深市 B 股")
    }

    /// 9 开头故意不猜：900xxx 是沪市 B 股、920xxx 是北交所，猜错不如让用户自己写
    func testNormalizeCodeDoesNotGuessTheNinthRange() {
        XCTAssertEqual(WatchlistDraft.normalizeCode("900901"), "900901")
        XCTAssertEqual(WatchlistDraft.normalizeCode("920099"), "920099")
    }

    func testNormalizeCodeLeavesUsableInputAlone() {
        XCTAssertEqual(WatchlistDraft.normalizeCode("SH600036"), "sh600036", "前缀大小写不敏感")
        XCTAssertEqual(WatchlistDraft.normalizeCode("  sh600036  "), "sh600036", "两侧空格要吃掉")
        XCTAssertEqual(WatchlistDraft.normalizeCode("sh513130"), "sh513130")
        XCTAssertEqual(WatchlistDraft.normalizeCode(""), "")
    }

    func testNormalizeCodeDoesNotInventPrefixForGarbage() {
        XCTAssertEqual(WatchlistDraft.normalizeCode("12345"), "12345")     // 位数不对
        XCTAssertEqual(WatchlistDraft.normalizeCode("60003x"), "60003x")   // 不是纯数字
        XCTAssertEqual(WatchlistDraft.normalizeCode("abc"), "abc")
    }

    func testIsValidCode() {
        XCTAssertTrue(WatchlistDraft.isValidCode("sh600036"))
        XCTAssertTrue(WatchlistDraft.isValidCode("sz000001"))
        XCTAssertTrue(WatchlistDraft.isValidCode("bj830799"))

        XCTAssertFalse(WatchlistDraft.isValidCode("600036"), "缺前缀")
        XCTAssertFalse(WatchlistDraft.isValidCode("hk00700"), "不支持的交易所")
        XCTAssertFalse(WatchlistDraft.isValidCode("sh60003"), "位数不对")
        XCTAssertFalse(WatchlistDraft.isValidCode("sh6000366"), "位数不对")
        XCTAssertFalse(WatchlistDraft.isValidCode("sh60003x"))
        // Character.isNumber 会把阿拉伯数字也算数字，这里必须挡住
        XCTAssertFalse(WatchlistDraft.isValidCode("sh6000٣6"))
    }

    // MARK: - 校验

    func testValidDraftHasNoIssues() {
        XCTAssertTrue(WatchlistDraft(config: .default).issues().isEmpty)
        XCTAssertTrue(WatchlistDraft().issues().isEmpty, "空表是合法的：一只都不看")
    }

    func testEmptyCodeIsReported() {
        let draft = WatchlistDraft(rows: [WatchlistRow(code: "", name: "手滑", shares: nil)])

        let issues = draft.issues()

        XCTAssertEqual(issues.map(\.kind), [.emptyCode])
        XCTAssertEqual(issues.first?.row, 0)
    }

    func testMalformedCodeIsReported() {
        let draft = WatchlistDraft(rows: [
            WatchlistRow(code: "sh600036", name: "招商银行", shares: nil),
            WatchlistRow(code: "600519", name: "茅台", shares: nil),
        ])

        let issues = draft.issues()

        XCTAssertEqual(issues.map(\.kind), [.malformedCode])
        XCTAssertEqual(issues.first?.row, 1)
        XCTAssertTrue(issues[0].message.contains("600519"), "提示里要带上出错的代码")
    }

    /// 重复的代码必须在保存前拦住：面板用 code 当字典 key，重复会互相覆盖
    func testDuplicateCodeIsReportedAndPointsAtBothRows() {
        let draft = WatchlistDraft(rows: [
            WatchlistRow(code: "sh600036", name: "招商银行", shares: nil),
            WatchlistRow(code: "sh600036", name: "招商银行（重复）", shares: nil),
        ])

        let issues = draft.issues()

        XCTAssertEqual(issues.map(\.kind), [.duplicateCode])
        XCTAssertEqual(issues.first?.row, 1, "报在后出现的那一行")
        XCTAssertTrue(issues[0].message.contains("第 1 行"), "要指出和谁重复")
    }

    /// 同一个错误只报一次：大小写不同但规范化后相同的代码也算重复
    func testDuplicateDetectionRunsAfterNormalization() {
        var draft = WatchlistDraft(rows: [
            WatchlistRow(code: "sh600036", name: "招商银行", shares: nil),
            WatchlistRow(code: "600036", name: "招商银行", shares: nil),
        ])
        draft.normalizeCode(at: 1)

        XCTAssertEqual(draft.rows[1].code, "sh600036")
        XCTAssertEqual(draft.issues().map(\.kind), [.duplicateCode])
    }

    // MARK: - 股数解析

    func testParseShares() {
        XCTAssertEqual(WatchlistDraft.parseShares("1500"), 1_500)
        XCTAssertEqual(WatchlistDraft.parseShares(" 1,100,000 "), 1_100_000, "面板上显示的就是带千分位的，要能粘回来")
    }

    func testParseSharesRejectsNonHoldings() {
        XCTAssertNil(WatchlistDraft.parseShares(""))
        XCTAssertNil(WatchlistDraft.parseShares("   "))
        XCTAssertNil(WatchlistDraft.parseShares("0"))
        XCTAssertNil(WatchlistDraft.parseShares("-500"))
        XCTAssertNil(WatchlistDraft.parseShares("abc"))
        XCTAssertNil(WatchlistDraft.parseShares("1.5"))
    }

    func testSharesTextMatchesThePanel() {
        XCTAssertEqual(WatchlistDraft.sharesText(1_100_000), "1,100,000")
        XCTAssertEqual(WatchlistDraft.sharesText(435), "435")
        XCTAssertEqual(WatchlistDraft.sharesText(nil), "")
        XCTAssertEqual(WatchlistDraft.sharesText(0), "")
    }

    // MARK: - 增删排序

    func testRemoveMultipleRowsUsesPreDeletionIndexes() {
        var draft = WatchlistDraft(rows: [
            WatchlistRow(code: "a", name: "", shares: nil),
            WatchlistRow(code: "b", name: "", shares: nil),
            WatchlistRow(code: "c", name: "", shares: nil),
            WatchlistRow(code: "d", name: "", shares: nil),
        ])

        draft.remove(at: IndexSet([1, 3]))

        XCTAssertEqual(draft.rows.map(\.code), ["a", "c"], "从大到小删才不会被下标位移带偏")
    }

    func testMoveRow() {
        var draft = WatchlistDraft(rows: [
            WatchlistRow(code: "a", name: "", shares: nil),
            WatchlistRow(code: "b", name: "", shares: nil),
            WatchlistRow(code: "c", name: "", shares: nil),
        ])

        draft.move(from: 0, to: 2)

        XCTAssertEqual(draft.rows.map(\.code), ["b", "c", "a"])
    }

    func testMoveRowClampsOutOfRangeTargets() {
        var draft = WatchlistDraft(rows: [
            WatchlistRow(code: "a", name: "", shares: nil),
            WatchlistRow(code: "b", name: "", shares: nil),
        ])

        draft.move(from: 0, to: 99)      // 越界 → 夹到末尾
        XCTAssertEqual(draft.rows.map(\.code), ["b", "a"])

        draft.move(from: 0, to: -99)     // 越界 → 夹回队首，也就是原地不动
        XCTAssertEqual(draft.rows.map(\.code), ["b", "a"])
    }

    func testMoveIgnoresOutOfRangeSource() {
        var draft = WatchlistDraft(rows: [WatchlistRow(code: "a", name: "", shares: nil)])

        draft.move(from: 5, to: 0)

        XCTAssertEqual(draft.rows.map(\.code), ["a"])
    }

    func testNormalizeCodeAtRowReportsWhetherItChanged() {
        var draft = WatchlistDraft(rows: [WatchlistRow(code: "600036", name: "", shares: nil)])

        XCTAssertTrue(draft.normalizeCode(at: 0))
        XCTAssertEqual(draft.rows[0].code, "sh600036")

        XCTAssertFalse(draft.normalizeCode(at: 0), "已经是规范形式就不算改动")
        XCTAssertFalse(draft.normalizeCode(at: 9), "越界不该崩")
    }
}


// MARK: - 持仓成本

final class WatchlistCostTests: XCTestCase {
    func testRoundTripThroughDraftKeepsCosts() {
        let config = WatchlistConfig(
            watchlist: [.init(code: "sh600036", name: "招商银行")],
            holdings: ["sh600036": 1_500],
            costs: ["sh600036": 38.5]
        )

        XCTAssertEqual(WatchlistDraft(config: config).config(), config)
    }

    /// 没填股数的行不写成本：免得以后补上股数时冒出一个陈年成本
    func testCostIsDroppedWithoutShares() {
        let draft = WatchlistDraft(rows: [
            WatchlistRow(code: "sh600036", name: "招商银行", shares: nil, cost: 38.5),
        ])

        XCTAssertTrue(draft.config().costs.isEmpty)
        XCTAssertTrue(draft.config().holdings.isEmpty)
    }

    func testParseCostRejectsNonPositive() {
        XCTAssertEqual(WatchlistDraft.parseCost("38.5"), 38.5)
        XCTAssertEqual(WatchlistDraft.parseCost(" 1,234.56 "), 1_234.56)
        XCTAssertNil(WatchlistDraft.parseCost(""))
        XCTAssertNil(WatchlistDraft.parseCost("0"))
        XCTAssertNil(WatchlistDraft.parseCost("-3"))
        XCTAssertNil(WatchlistDraft.parseCost("abc"))
    }

    func testCostText() {
        XCTAssertEqual(WatchlistDraft.costText(38.5), "38.5", "末尾的 0 去掉")
        XCTAssertEqual(WatchlistDraft.costText(nil), "")
        XCTAssertEqual(WatchlistDraft.costText(0), "")
    }

    /// 基金/ETF 的成本常常是 3 位小数。只显示 2 位的话，
    /// 填进去的值会在下次编辑那个格子时被静默四舍五入掉
    func testCostSupportsThreeDecimals() {
        XCTAssertEqual(WatchlistDraft.costText(1.234), "1.234")
        XCTAssertEqual(WatchlistDraft.costText(1.2), "1.2")
        XCTAssertEqual(WatchlistDraft.parseCost("1.234"), 1.234)

        // 走一遍「显示 → 解析」不能丢精度
        let original = 1.234
        let roundTripped = WatchlistDraft.parseCost(WatchlistDraft.costText(original))
        XCTAssertEqual(roundTripped, original)
    }

    /// 超过 3 位的按 3 位四舍五入（再多也没意义）
    func testCostRoundsBeyondThreeDecimals() {
        XCTAssertEqual(WatchlistDraft.costText(1.23456), "1.235")
    }

    /// 浮动盈亏 =（现价 − 成本）× 股数；缺任何一项都是 nil（不显示 0）
    func testFloatingProfit() {
        XCTAssertEqual(WatchlistDraft.floatingProfit(price: 45, cost: 38.5, shares: 1_000), 6_500)
        XCTAssertNil(WatchlistDraft.floatingProfit(price: 45, cost: nil, shares: 1_000))
        XCTAssertNil(WatchlistDraft.floatingProfit(price: nil, cost: 38.5, shares: 1_000))
        XCTAssertNil(WatchlistDraft.floatingProfit(price: 45, cost: 38.5, shares: nil))
    }

    /// ⚠️ 回归：`costs` 是后加的字段，合成的解码器缺键会抛 keyNotFound ——
    /// 那会把用户的整份清单当成坏文件、备份走再回退成内置默认值。必须手写容错。
    func testDecodesLegacyConfigWithoutCostsKey() throws {
        let legacy = """
        {"watchlist":[{"code":"sh600036","name":"招商银行"}],"holdings":{"sh600036":1500}}
        """

        let config = try JSONDecoder().decode(WatchlistConfig.self, from: Data(legacy.utf8))

        XCTAssertEqual(config.watchlist.map(\.code), ["sh600036"])
        XCTAssertEqual(config.holdings["sh600036"], 1_500)
        XCTAssertTrue(config.costs.isEmpty, "老文件没有 costs 键，应当是空的而不是解码失败")
    }
}


// MARK: - 浮动盈亏那一格的格式

final class FloatingProfitFormatTests: XCTestCase {
    func testAmountAndPercent() {
        XCTAssertEqual(HoldingFormat.floatingProfit(profit: 6_500, percent: 0.1234), "+6,500  +12.34%")
        XCTAssertEqual(HoldingFormat.floatingProfit(profit: -1_200.4, percent: -0.0512), "-1,200  -5.12%")
    }

    /// 只显示半个（只有金额没有收益率）比不显示更让人犯嘀咕
    func testEmptyWhenEitherSideIsMissing() {
        XCTAssertEqual(HoldingFormat.floatingProfit(profit: nil, percent: 0.1), "")
        XCTAssertEqual(HoldingFormat.floatingProfit(profit: 100, percent: nil), "")
    }

    /// 收益率按两位小数截断，和现价那列的涨跌幅口径一致
    func testPercentTruncatesRatherThanRounds() {
        XCTAssertEqual(HoldingFormat.floatingProfit(profit: 100, percent: 0.129_99), "+100  +12.99%")
    }

    func testZeroIsUnsigned() {
        XCTAssertEqual(HoldingFormat.floatingProfit(profit: 0, percent: 0), "0  0.00%")
    }
}


// MARK: - 老格式迁移（股数 / 成本从独立字典并进条目）

final class WatchlistConfigMigrationTests: XCTestCase {
    /// ⚠️ 老文件是「watchlist 放名字 + holdings 放股数 + costs 放成本」三份数据，
    /// 现在合并成一份。读老文件必须读得进来且一个都不丢。
    func testMergesLegacyDictionariesIntoItems() throws {
        let legacy = """
        {"watchlist":[{"code":"sh600036","name":"招商银行"},{"code":"sh000001","name":"上证指数"}],
         "holdings":{"sh600036":1500},
         "costs":{"sh600036":38.123}}
        """

        let config = try JSONDecoder().decode(WatchlistConfig.self, from: Data(legacy.utf8))

        XCTAssertEqual(config.watchlist.count, 2)
        XCTAssertEqual(config.watchlist[0].shares, 1_500)
        XCTAssertEqual(config.watchlist[0].cost, 38.123)
        XCTAssertNil(config.watchlist[1].shares, "上证指数只看不持")
        // 派生视图照旧
        XCTAssertEqual(config.holdings["sh600036"], 1_500)
        XCTAssertEqual(config.costs["sh600036"], 38.123)
    }

    /// 老格式允许 holdings 里有清单里没有的代码（配置窗口会把它们补成行）。
    /// 合并时要补成条目，否则升级一次这些持仓就没了
    func testLegacyOrphanHoldingBecomesAnItem() throws {
        let legacy = """
        {"watchlist":[{"code":"sh600036","name":"招商银行"}],
         "holdings":{"sh600036":1500,"sz300750":200}}
        """

        let config = try JSONDecoder().decode(WatchlistConfig.self, from: Data(legacy.utf8))

        XCTAssertEqual(config.watchlist.map(\.code), ["sh600036", "sz300750"])
        XCTAssertEqual(config.watchlist[1].shares, 200)
        XCTAssertEqual(config.watchlist[1].name, "", "名字留空，等用户补")
    }

    /// 写回去只有一份数据，不再有 holdings / costs 两个键
    func testEncodesAsASingleWatchlist() throws {
        let config = WatchlistConfig(
            watchlist: [.init(code: "sh600036", name: "招商银行", shares: 1_500, cost: 38.123)]
        )

        let json = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)

        XCTAssertTrue(json.contains("\"shares\""))
        XCTAssertTrue(json.contains("\"cost\""))
        XCTAssertFalse(json.contains("\"holdings\""), "不该再写独立的 holdings 键")
        XCTAssertFalse(json.contains("\"costs\""), "不该再写独立的 costs 键")
    }

    /// 新格式 round-trip
    func testNewFormatRoundTrips() throws {
        let config = WatchlistConfig(
            watchlist: [.init(code: "sh512170", name: "医疗ETF华宝", shares: 1_100_000, cost: 1.234)]
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(WatchlistConfig.self, from: data)

        XCTAssertEqual(decoded.watchlist[0].shares, 1_100_000)
        XCTAssertEqual(decoded.watchlist[0].cost, 1.234)
    }
}
