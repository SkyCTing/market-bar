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

    /// 代码为空的行（用户点了「添加」但没填）不该混进配置
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

    func testAppendRowAddsABlankRow() {
        var draft = WatchlistDraft(config: .default)

        draft.appendRow()

        XCTAssertEqual(draft.rows.count, WatchlistConfig.default.watchlist.count + 1)
        XCTAssertEqual(draft.rows.last, WatchlistRow(code: "", name: "", shares: nil))
    }

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
