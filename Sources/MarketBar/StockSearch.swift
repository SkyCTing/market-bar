import Foundation

/// 一条搜索候选项。
struct StockSearchResult: Equatable, Sendable {
    /// 完整代码，如 "sh600036"
    var code: String
    /// 中文名，如 "招商银行"
    var name: String
    /// 拼音首字母，如 "zsyh"（接口偶尔不给）
    var pinyin: String
    /// 品种，如 "GP-A"（A股）、"ETF"
    var kind: String
}

/// 腾讯的搜索建议接口（smartbox）—— 输代码、中文名、拼音都能命中。
///
/// 纯逻辑（建 URL + 解析），网络那层在 `StockSearchService`。
enum StockSearch {
    /// 少于 2 个字不搜：单字符会返回一大串无关结果，纯噪声
    static let minimumKeywordLength = 2

    /// 一次最多采纳多少条。接口一般给 10 条，这里留点余量。
    static let maximumResults = 20

    /// 拿去搜的关键词。
    ///
    /// ⚠️ 接口**只认裸的 6 位数字**：`q=sh600519` 返回 `v_hint="N"`，
    /// `q=600519` 才有结果。所以带交易所前缀的完整代码要先摘掉前缀再搜。
    static func keyword(forCode code: String) -> String {
        let lower = code.lowercased()
        guard WatchlistDraft.isValidCode(lower) else { return code }
        return String(lower.dropFirst(2))
    }

    static func url(keyword: String) -> URL? {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        // 用户在搜索框里粘一个 "sh600519" 进来，也要能搜到
        // （要写全名：这里的 `keyword` 是参数，直接调会被它遮住）
        let normalized = StockSearch.keyword(forCode: trimmed)
        guard normalized.count >= minimumKeywordLength else { return nil }
        guard let encoded = normalized.addingPercentEncoding(withAllowedCharacters: urlAllowed) else {
            return nil
        }
        return URL(string: "https://smartbox.gtimg.cn/s3/?v=2&t=all&q=\(encoded)")
    }

    /// 只放行 RFC 3986 的 unreserved。
    ///
    /// ⚠️ 不能用 `CharacterSet.alphanumerics`：它是**全 Unicode** 的字母表，
    /// 中文会被当成「字母」而不做百分号编码，拼出来的 URL 直接不合法。
    private static let urlAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// 解析 `v_hint="sh~600036~招商银行~zsyh~GP-A^..."`
    ///
    /// 没有结果时接口给的是 `v_hint="N"`。
    static func parse(_ body: String) -> [StockSearchResult] {
        guard let first = body.firstIndex(of: "\""),
              let last = body.lastIndex(of: "\""),
              first < last
        else { return [] }

        let payload = String(body[body.index(after: first)..<last])
        guard !payload.isEmpty, payload != "N" else { return [] }

        var results: [StockSearchResult] = []
        var seen = Set<String>()

        for entry in payload.components(separatedBy: "^") {
            let fields = entry.components(separatedBy: "~")
            guard fields.count >= 3 else { continue }

            let market = fields[0].lowercased()
            // 面板只认沪深两市。港股/美股/场外基金搜出来也用不了（代码对不上行情接口）
            guard market == "sh" || market == "sz" else { continue }

            let code = market + fields[1].trimmingCharacters(in: .whitespaces)
            guard WatchlistDraft.isValidCode(code), seen.insert(code).inserted else { continue }

            results.append(StockSearchResult(
                code: code,
                name: decodeUnicodeEscapes(fields[2]).trimmingCharacters(in: .whitespaces),
                pinyin: fields.count > 3 ? fields[3] : "",
                kind: fields.count > 4 ? fields[4] : ""
            ))

            if results.count >= maximumResults { break }
        }

        return results
    }

    /// 按名称补全代码时，从候选里挑一条。
    ///
    /// 比按代码补名称保守得多：重名、近名的标的一抓一大把（搜「招商」能出十条），
    /// 随便挑一条填进去比不填更糟。所以只认两种情况：**名字完全相同的恰好一条**，
    /// 或者**整个结果就只有一条**。其余一律返回 nil，让用户自己去搜。
    static func bestMatch(forName name: String, in results: [StockSearchResult]) -> StockSearchResult? {
        let exact = results.filter { $0.name == name }
        if exact.count == 1 { return exact[0] }
        if results.count == 1 { return results[0] }
        return nil
    }

    /// 把 `招商` 还原成「招商」。
    ///
    /// 先攒成 UTF-16 码元再交给 `String(decoding:as:)`：这样代理对（emoji 之类）
    /// 也能正确合并，非法码元退化成 U+FFFD 而不是崩掉。
    static func decodeUnicodeEscapes(_ text: String) -> String {
        guard text.contains("\\u") else { return text }

        let characters = Array(text)
        var units: [UInt16] = []
        var index = 0

        while index < characters.count {
            let isEscape = characters[index] == "\\"
                && index + 5 < characters.count
                && characters[index + 1] == "u"
            if isEscape, let value = UInt16(String(characters[(index + 2)...(index + 5)]), radix: 16) {
                units.append(value)
                index += 6
            } else {
                units.append(contentsOf: Array(String(characters[index]).utf16))
                index += 1
            }
        }

        return String(decoding: units, as: UTF16.self)
    }
}

/// 搜索建议的网络请求。
enum StockSearchService {
    static func search(_ keyword: String, session: URLSession = .shared) async -> [StockSearchResult] {
        guard let url = StockSearch.url(keyword: keyword) else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (data, _) = try await session.data(for: request)
            // 正文是 ASCII（中文被转义成 \uXXXX），所以 UTF-8 一定解得出；
            // isoLatin1 只是兜底，保证任何字节序列都不会解成 nil
            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
            return StockSearch.parse(text)
        } catch {
            return []
        }
    }
}
