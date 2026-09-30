import Foundation

// 这个文件只有 Foundation —— 版本比较、响应模型、地址校验、发布说明处理、
// 网络与下载，全部不碰 AppKit。弹框和状态机在 AppUpdateController.swift。
//
// 分两个文件是按 AISign.swift / AISignController.swift 的切法：纯逻辑与 UI 分开，
// 前者可以直接在普通 XCTestCase 里测，不用起 NSApplication。

// MARK: - 版本号

/// 版本号的解析与比较。
///
/// 全是纯函数 —— 「1.0.10 比 1.0.9 新」这种地方最容易顺手写成字符串比较，
/// 一旦写错就是「用户永远收不到更新」，而且是静默的。所以这里必须有测试钉住。
enum AppVersion {
    /// 超过这个长度直接判为解析失败：正常版本号不会有这么长，
    /// 而放进来只会让后面几段分割白跑
    static let maximumLength = 64

    struct Parsed: Equatable {
        var components: [Int]
        /// 带预发布后缀（`1.1.0-beta.1` 这类）
        var isPrerelease: Bool
    }

    /// `v1.2.3` / `1.2.3` → `[1, 2, 3]`；`1.2.3-beta.1` → `[1, 2, 3]` + 预发布标记。
    /// 解析不出来返回 nil —— 调用方要当作「无法比较」，不是「没有更新」
    static func parse(_ raw: String) -> Parsed? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maximumLength else { return nil }
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }

        // 数字和点之外的第一处就是后缀的起点
        var digits = ""
        var index = text.startIndex
        while index < text.endIndex, text[index].isNumber || text[index] == "." {
            digits.append(text[index])
            index = text.index(after: index)
        }
        let isPrerelease = index < text.endIndex
        guard !digits.isEmpty else { return nil }

        // omittingEmptySubsequences: false —— "1..2" 要解析失败，不能悄悄当成 "1.2"
        var components: [Int] = []
        for part in digits.split(separator: ".", omittingEmptySubsequences: false) {
            guard let value = Int(part) else { return nil }
            components.append(value)
        }
        guard !components.isEmpty else { return nil }
        return Parsed(components: components, isPrerelease: isPrerelease)
    }

    /// candidate 是否比 current 新。
    ///
    /// 任一边解析不出来就返回 false：宁可漏报一次，也不要把「看不懂的版本号」
    /// 当成新版本去骚扰用户
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let incoming = parse(candidate), let installed = parse(current) else { return false }
        // 预发布版不推给普通用户（releases/latest 本来也不会返回预发布，这里是兜底）
        guard !incoming.isPrerelease else { return false }

        // 短的一边补 0：1.1 和 1.1.0 是同一个版本
        for index in 0 ..< max(incoming.components.count, installed.components.count) {
            let fresh = index < incoming.components.count ? incoming.components[index] : 0
            let old = index < installed.components.count ? installed.components[index] : 0
            if fresh != old { return fresh > old }
        }
        return false
    }

    /// 运行中的版本号。`swift run` 时没有 app bundle，这个键不存在 —— 返回 nil
    static func current(info: [String: Any]) -> String? {
        guard let version = info["CFBundleShortVersionString"] as? String,
              !version.isEmpty else { return nil }
        return version
    }

    /// 当前这个进程的版本号
    static var installed: String? { current(info: Bundle.main.infoDictionary ?? [:]) }
}

// MARK: - GitHub 响应

/// GitHub `releases/latest` 的响应。**这是不可信输入** ——
/// 只挑用得上的字段，缺必需字段就当格式错误
struct AppRelease: Decodable, Equatable, Sendable {
    struct Asset: Decodable, Equatable, Sendable {
        var name: String
        var downloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case downloadURL = "browser_download_url"
        }

        /// 单条资源解不出来只丢这一条：一个坏资源不该让整次检查失败
        /// （`ReminderStore` 那个坑的同款处理）
        struct Lossy: Decodable {
            let value: Asset?
            init(from decoder: Decoder) throws { value = try? Asset(from: decoder) }
        }
    }

    var tag: String
    var pageURL: URL
    /// 发布说明（markdown）
    var notes: String
    var assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name"
        case pageURL = "html_url"
        case notes = "body"
        case assets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tag = try container.decode(String.self, forKey: .tag)
        pageURL = try container.decode(URL.self, forKey: .pageURL)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        // `try?` 套在返回可选值的 throwing 调用上会得到双层可选，摊平一次再兜底
        let assets = (try? container.decodeIfPresent([Asset.Lossy].self, forKey: .assets)) ?? nil
        self.assets = (assets ?? []).compactMap(\.value)
    }

    init(tag: String, pageURL: URL, notes: String, assets: [Asset]) {
        self.tag = tag
        self.pageURL = pageURL
        self.notes = notes
        self.assets = assets
    }
}

// MARK: - 从响应里挑地址

enum AppUpdateLink {
    /// 本仓库在 GitHub 上的路径。响应里给的地址必须落在这下面
    static let repositoryPath = "/SkyCTing/market-bar"

    /// 只放行 https + github.com + 本仓库路径。
    ///
    /// 响应里的 URL 是不可信输入：直接拿它去下载或打开，等于把「打开任意网址 /
    /// 往磁盘写任意文件」的能力交出去。注意 app 的 Info.plist 里
    /// `NSAllowsArbitraryLoads` 是开的，所以 http 也不会被系统拦 —— 这道校验是
    /// 唯一的闸门，不是锦上添花。
    ///
    /// host 用**精确相等**而不是 hasSuffix：`github.com.evil.com` 和
    /// `evilgithub.com` 都能骗过后缀匹配
    static func validated(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com",
              // 带用户名密码的地址是钓鱼常用手法，一律不收
              url.user == nil, url.password == nil,
              // 下一段必须是 `/` 或到头：只写 hasPrefix 的话
              // `/SkyCTing/market-bar-evil/...` 也会被放行
              url.path == repositoryPath || url.path.hasPrefix(repositoryPath + "/") else { return nil }
        return url
    }

    /// 发布脚本产出的资源名固定是 `MarketBar-<版本>.dmg`（见 scripts/release.sh）
    static func canonicalAssetName(for tag: String) -> String {
        var version = tag
        if version.hasPrefix("v") || version.hasPrefix("V") { version.removeFirst() }
        return "MarketBar-\(version).dmg"
    }

    /// 「下载并打开」用哪个地址：优先本仓库那个 .dmg，否则退回发布页；都没有就 nil。
    ///
    /// 真正下载时会被 302 到 objects.githubusercontent.com，这个不用管 ——
    /// URLSession 默认跟随跳转，而被信任的源头是 github.com，且我们不带任何凭据
    static func downloadTarget(for release: AppRelease) -> URL? {
        let usable = release.assets
            .filter { $0.name.lowercased().hasSuffix(".dmg") }
            .compactMap { asset -> (name: String, url: URL)? in
                guard let url = validated(asset.downloadURL) else { return nil }
                return (asset.name, url)
            }
        let canonical = canonicalAssetName(for: release.tag)
        if let match = usable.first(where: { $0.name == canonical }) { return match.url }
        return usable.first?.url ?? validated(release.pageURL)
    }

    static func pageTarget(for release: AppRelease) -> URL? {
        validated(release.pageURL)
    }
}

// MARK: - 发布说明

enum AppUpdateNotes {
    /// 处理前先砍一刀：下面几步都是正则，不该让一段超长文本白跑
    static let maximumInputCharacters = 20_000

    /// GitHub 的发布说明是 markdown，而 `NSAlert.informativeText` 只显示纯文本 ——
    /// 不处理的话弹框里就是一屏 `##` 和 `**`
    static func summary(from body: String, limit: Int = 400) -> String {
        var text = body.count > maximumInputCharacters
            ? String(body.prefix(maximumInputCharacters))
            : body

        // 图片直接去掉，链接只留文字
        text = text.replacingOccurrences(
            of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression
        )

        var lines: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            // 行首的标题/引用/列表记号
            while let first = line.first, "#>-*+".contains(first) {
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            // 行内的强调与代码记号
            line = line.replacingOccurrences(of: #"[*`_]"#, with: "", options: .regularExpression)
            if !line.isEmpty { lines.append(line) }
        }

        let joined = lines.joined(separator: "\n")
        guard joined.count > limit else { return joined }

        // 按行边界截，免得切在半句话上
        var result = ""
        for line in lines {
            if result.count + line.count + 1 > limit { break }
            result += (result.isEmpty ? "" : "\n") + line
        }
        if result.isEmpty { result = String(joined.prefix(limit)) }
        return result + "…"
    }
}

// MARK: - 错误

enum AppUpdateError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

// MARK: - 网络

struct AppUpdateService: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let feedURL = URL(string: "https://api.github.com/repos/SkyCTing/market-bar/releases/latest")!
    /// 一次版本检查的响应不该有这么大；超了直接判为异常，别去解它
    static let maximumResponseBytes = 1_000_000

    var transport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw AppUpdateError.message("GitHub 没有返回 HTTP 响应")
        }
        return (data, response)
    }

    func latestRelease() async throws -> AppRelease {
        var request = URLRequest(url: Self.feedURL, timeoutInterval: 5)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // 钉住 API 版本：不钉的话 GitHub 换默认版本时字段可能悄悄变，解析就断了
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // ⚠️ 这是本 app 里**第一处** User-Agent。GitHub 的 API 强制要求它，
        // 不带会直接 403（不是被限流，是拒答）
        request.setValue(
            "MarketBar (+https://github.com/SkyCTing/market-bar)",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await transport(request)
        switch response.statusCode {
        case 200:
            break
        case 404:
            throw AppUpdateError.message("GitHub 上还没有发布过版本")
        case 403, 429:
            // 限流和「没权限」都是这两个码，靠这个头区分
            if response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" {
                throw AppUpdateError.message("GitHub 接口被限流了，过一会儿再试")
            }
            throw AppUpdateError.message("检查更新失败（HTTP \(response.statusCode)），稍后再试")
        default:
            throw AppUpdateError.message("检查更新失败（HTTP \(response.statusCode)），稍后再试")
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw AppUpdateError.message("GitHub 返回的内容异常大，已放弃这次检查")
        }
        do {
            return try JSONDecoder().decode(AppRelease.self, from: data)
        } catch {
            // ⚠️ 不要把 response body 拼进错误信息 —— 404 时它是一串英文 JSON
            // （`{"message":"Not Found",…}`），弹给用户看毫无意义。
            // AISign 那边有同款约定和一条钉住它的测试
            throw AppUpdateError.message("看不懂 GitHub 返回的版本信息，可能接口变了")
        }
    }
}

/// 把 DMG 下到「下载」文件夹
enum AppUpdateDownloader {
    /// 小于这个字节数就一定不是安装包（多半是错误页）
    static let minimumBytes = 100_000
    static let maximumBytes = 200 * 1_000 * 1_000

    /// DMG 最后 512 字节是以 `koly` 开头的 trailer。
    /// 状态码查过之后再加这一道：状态码 200 但内容是个错误页/跳转页是现实的，
    /// 存下来再双击打开就变成一个说不清的报错
    static func isDiskImage(_ data: Data) -> Bool {
        guard data.count >= 512 else { return false }
        return data.suffix(512).prefix(4) == Data("koly".utf8)
    }

    /// 用 `data(from:)` 而不是 `download(from:)`：安装包 7MB 左右，进内存无所谓，
    /// 而临时文件「下完必须立刻搬走」的生命周期不值得为这点内存去踩。
    /// 代价是这里的上限是**事后**判的 —— 挡的是「存下垃圾」，不是「内存被打爆」；
    /// 地址已经限定在 github.com 本仓库路径下，这个残余风险认了
    static func download(_ url: URL, as name: String) async throws -> URL {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("MarketBar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw AppUpdateError.message("下载失败（HTTP \(http.statusCode)），稍后再试")
        }
        guard data.count >= minimumBytes, data.count <= maximumBytes else {
            throw AppUpdateError.message("下载到的内容不像是安装包，已放弃")
        }
        guard isDiskImage(data) else {
            throw AppUpdateError.message("下载到的文件不是磁盘映像，已放弃")
        }

        let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let destination = directory.appendingPathComponent(name)
        do {
            // 覆盖同名的旧包：留着只会让人分不清哪个是新的
            try? FileManager.default.removeItem(at: destination)
            try data.write(to: destination, options: .atomic)
        } catch {
            throw AppUpdateError.message("下载完成但保存失败：\(error.localizedDescription)")
        }
        return destination
    }
}

// MARK: - 弹框要用的数据

/// 用户面对「有新版本」时选了什么
enum AppUpdateChoice: Equatable {
    case download
    case openPage
    case later
}

/// 一次「发现有新版本」的完整描述，交给弹框层显示。
/// 单独抽出来是为了让 controller 不直接依赖 AppKit 的弹框，测试时可以注入假的
struct AppUpdatePrompt: Equatable {
    var currentVersion: String
    /// 带 v 的 tag，比如 v1.0.1
    var newVersion: String
    /// 已经处理成纯文本的发布说明
    var notes: String
    var downloadURL: URL?
    var pageURL: URL?
}
