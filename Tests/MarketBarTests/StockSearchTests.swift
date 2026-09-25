import Foundation
import XCTest

@testable import MarketBar

/// 腾讯搜索建议接口的解析（fixture 都是实测抓到的真实响应）
final class StockSearchTests: XCTestCase {

    // MARK: - 解析

    func testParsesRealResponse() {
        let body = #"v_hint="sh~600036~招商银行~zsyh~GP-A""#

        let results = StockSearch.parse(body)

        XCTAssertEqual(results, [
            StockSearchResult(code: "sh600036", name: "招商银行", pinyin: "zsyh", kind: "GP-A"),
        ])
    }

    func testParsesMultipleResultsInOrder() {
        let body = #"v_hint="sh~600036~招商银行~zsyh~GP-A^sh~601872~招商轮船~zslc~GP-A""#

        let results = StockSearch.parse(body)

        XCTAssertEqual(results.map(\.code), ["sh600036", "sh601872"])
        XCTAssertEqual(results.map(\.name), ["招商银行", "招商轮船"])
    }

    func testParsesEtf() {
        let body = #"v_hint="sh~512170~医疗ETF华宝~yletfhb~ETF""#

        let results = StockSearch.parse(body)

        XCTAssertEqual(results.first?.name, "医疗ETF华宝")
        XCTAssertEqual(results.first?.kind, "ETF")
    }

    /// 回车／换行包在响应外面时也要能认出来（接口偶尔带尾部换行）
    func testParsesWhenSurroundedByNoise() {
        let body = "\nv_hint=\"sh~600036~\\u62db\\u5546\\u94f6\\u884c~zsyh~GP-A\";\n"

        XCTAssertEqual(StockSearch.parse(body).map(\.code), ["sh600036"])
    }

    func testNoMatchYieldsNoResults() {
        XCTAssertTrue(StockSearch.parse(#"v_hint="N";"#).isEmpty)
        XCTAssertTrue(StockSearch.parse(#"v_hint=""#).isEmpty)
        XCTAssertTrue(StockSearch.parse("").isEmpty)
        XCTAssertTrue(StockSearch.parse("完全不是这个格式").isEmpty)
    }

    /// 港股、美股、场外基金搜出来也用不了：面板的行情接口只认沪深代码
    func testFiltersOutMarketsThePanelCannotQuote() {
        let body = #"v_hint="sh~600036~招商银行~zsyh~GP-A^hk~03968~招商银行~zsyh~GP^us~cihky.ps~招商银行~zsyh~GP^jj~014840~招商裕华混合~zsyhhh~KJ""#

        let results = StockSearch.parse(body)

        XCTAssertEqual(results.map(\.code), ["sh600036"], "只留沪深")
    }

    func testKeepsShenzhenCodes() {
        let body = #"v_hint="sz~000001~平安银行~payh~GP-A""#

        XCTAssertEqual(StockSearch.parse(body).map(\.code), ["sz000001"])
    }

    func testDeduplicatesRepeatedCodes() {
        let body = #"v_hint="sh~600036~A~a~GP-A^sh~600036~B~b~GP-A""#

        XCTAssertEqual(StockSearch.parse(body).count, 1)
    }

    func testSkipsMalformedEntries() {
        // 字段不足、代码位数不对、市场是空的 —— 都跳过，但不影响同一批里正常的那条
        let body = #"v_hint="sh~600036^sh~60003~坏的~h~GP-A^^sh~600519~贵州茅台~gzmt~GP-A""#

        XCTAssertEqual(StockSearch.parse(body).map(\.code), ["sh600519"])
    }

    func testCapsResultCount() {
        let entries = (0..<40).map { "sh~60\(String(format: "%04d", $0))~N\($0)~p~GP-A" }
        let body = "v_hint=\"\(entries.joined(separator: "^"))\""

        XCTAssertEqual(StockSearch.parse(body).count, StockSearch.maximumResults)
    }

    // MARK: - \uXXXX 还原

    func testDecodesUnicodeEscapes() {
        XCTAssertEqual(StockSearch.decodeUnicodeEscapes(#"招商银行"#), "招商银行")
        XCTAssertEqual(StockSearch.decodeUnicodeEscapes(#"医疗ETF华宝"#), "医疗ETF华宝")
    }

    func testDecodeLeavesPlainTextAlone() {
        XCTAssertEqual(StockSearch.decodeUnicodeEscapes("招商银行"), "招商银行")
        XCTAssertEqual(StockSearch.decodeUnicodeEscapes(""), "")
    }

    /// 转义和普通字符混在一起时，普通字符要原样保留
    func testDecodeKeepsLiteralTextAroundEscapes() {
        XCTAssertEqual(StockSearch.decodeUnicodeEscapes(#"A中B"#), "A中B")
    }

    func testDecodeHandlesSurrogatePairs() {
        // U+1F600 拆成 D83D DE00 两个码元
        XCTAssertEqual(StockSearch.decodeUnicodeEscapes(#"😀"#), "😀")
    }

    func testDecodePassesThroughMalformedEscapes() {
        XCTAssertEqual(StockSearch.decodeUnicodeEscapes(#"\uZZZZ"#), #"\uZZZZ"#)
    }

    // MARK: - URL

    /// ⚠️ 这条是关键：`CharacterSet.alphanumerics` 是全 Unicode 的字母表，
    /// 中文会被当成字母而不做百分号编码，拼出来的 URL 直接不合法。
    func testURLPercentEncodesChinese() {
        let url = StockSearch.url(keyword: "招商")

        XCTAssertEqual(url?.absoluteString, "https://smartbox.gtimg.cn/s3/?v=2&t=all&q=%E6%8B%9B%E5%95%86")
    }

    func testURLKeepsDigitsAndLetters() {
        let url = StockSearch.url(keyword: "600036")

        XCTAssertEqual(url?.absoluteString, "https://smartbox.gtimg.cn/s3/?v=2&t=all&q=600036")
    }

    func testURLTrimsSurroundingWhitespace() {
        XCTAssertEqual(StockSearch.url(keyword: "  600036 "), StockSearch.url(keyword: "600036"))
    }

    /// ⚠️ 接口只认裸的 6 位数字：`q=sh600036` 返回 v_hint="N"，`q=600036` 才有结果。
    /// 所以拿完整代码去搜之前必须把交易所前缀摘掉。
    func testURLStripsExchangePrefix() {
        XCTAssertEqual(StockSearch.url(keyword: "sh600036"), StockSearch.url(keyword: "600036"))
        XCTAssertEqual(StockSearch.url(keyword: "SZ000001"), StockSearch.url(keyword: "000001"))
    }

    func testKeywordForCode() {
        XCTAssertEqual(StockSearch.keyword(forCode: "sh600519"), "600519")
        XCTAssertEqual(StockSearch.keyword(forCode: "SZ000001"), "000001")
        XCTAssertEqual(StockSearch.keyword(forCode: "600519"), "600519", "本来就是裸代码")
        XCTAssertEqual(StockSearch.keyword(forCode: "招商银行"), "招商银行", "不是代码就别动")
        XCTAssertEqual(StockSearch.keyword(forCode: "sh6005"), "sh6005", "位数不对，不当代码处理")
    }

    /// 一个字搜出来全是噪声，不值得发请求
    func testURLRequiresAtLeastTwoCharacters() {
        XCTAssertNil(StockSearch.url(keyword: "6"))
        XCTAssertNil(StockSearch.url(keyword: "招"))
        XCTAssertNil(StockSearch.url(keyword: ""))
        XCTAssertNil(StockSearch.url(keyword: "   "))
        XCTAssertNotNil(StockSearch.url(keyword: "60"))
    }

    // MARK: - 按名称挑一条

    func testBestMatchTakesTheOnlyResult() {
        let only = StockSearchResult(code: "sh600519", name: "贵州茅台", pinyin: "gzmt", kind: "GP-A")

        XCTAssertEqual(StockSearch.bestMatch(forName: "茅台", in: [only]), only)
    }

    func testBestMatchTakesAnExactNameMatch() {
        let results = [
            StockSearchResult(code: "sz000024", name: "招商地产", pinyin: "zsdc", kind: "GP-A"),
            StockSearchResult(code: "sh600036", name: "招商银行", pinyin: "zsyh", kind: "GP-A"),
        ]

        XCTAssertEqual(StockSearch.bestMatch(forName: "招商银行", in: results)?.code, "sh600036")
    }

    /// 搜「招商」出来十条、没有一条名字完全对上 —— 宁可不填，也不能瞎挑第一条
    func testBestMatchRefusesWhenAmbiguous() {
        let results = [
            StockSearchResult(code: "sh601872", name: "招商轮船", pinyin: "zslc", kind: "GP-A"),
            StockSearchResult(code: "sh600999", name: "招商证券", pinyin: "zszq", kind: "GP-A"),
        ]

        XCTAssertNil(StockSearch.bestMatch(forName: "招商", in: results))
    }

    func testBestMatchRefusesOnDuplicateNames() {
        let results = [
            StockSearchResult(code: "sh600036", name: "招商银行", pinyin: "zsyh", kind: "GP-A"),
            StockSearchResult(code: "sz000001", name: "招商银行", pinyin: "zsyh", kind: "GP-A"),
        ]

        XCTAssertNil(StockSearch.bestMatch(forName: "招商银行", in: results), "同名两条也说不准是哪条")
    }

    func testBestMatchHandlesNoResults() {
        XCTAssertNil(StockSearch.bestMatch(forName: "查无此股", in: []))
    }
}
