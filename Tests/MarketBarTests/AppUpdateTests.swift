import Foundation
import XCTest

@testable import MarketBar

// MARK: - 脚手架

private actor UpdateHTTPStub {
    private var responses: [(Int, Data)]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [(Int, Data)]) { self.responses = responses }

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw AppUpdateError.message("Unexpected request") }
        let (status, data) = responses.removeFirst()
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private actor DownloadStub {
    private(set) var calls: [(url: URL, name: String)] = []
    private var result: Result<URL, Error> = .success(URL(fileURLWithPath: "/tmp/MarketBar-test.dmg"))

    func record(_ url: URL, _ name: String) { calls.append((url, name)) }
    func setResult(_ value: Result<URL, Error>) { result = value }
    func resolved() throws -> URL { try result.get() }
}

/// 弹框/报错/打开这三件事都发生在主线程上，用一个 @MainActor 的记录器收着
@MainActor
private final class UIRecorder {
    var prompts: [AppUpdatePrompt] = []
    var reports: [(title: String, body: String)] = []
    var opened: [URL] = []
    var choice: AppUpdateChoice = .later
    var openSucceeds = true

    var lastReport: (title: String, body: String)? { reports.last }
}

/// 实测抓到的 releases/latest 响应结构
private func releasePayload(
    tag: String = "v1.1.0",
    body: String = "## 新功能\n\n- 支持 **自选分组**\n- 修了 `几个` bug",
    assets: [[String: Any]] = [[
        "name": "MarketBar-1.1.0.dmg",
        "browser_download_url": "https://github.com/SkyCTing/market-bar/releases/download/v1.1.0/MarketBar-1.1.0.dmg",
    ]],
    pageURL: String = "https://github.com/SkyCTing/market-bar/releases/tag/v1.1.0"
) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "tag_name": tag, "html_url": pageURL, "body": body, "assets": assets,
    ])
}

private func makeRelease(
    tag: String = "v1.1.0",
    pageURL: String = "https://github.com/SkyCTing/market-bar/releases/tag/v1.1.0",
    assets: [AppRelease.Asset] = []
) throws -> AppRelease {
    AppRelease(
        tag: tag,
        pageURL: try XCTUnwrap(URL(string: pageURL)),
        notes: "",
        assets: assets
    )
}

// MARK: - 版本号

final class AppVersionTests: XCTestCase {
    func testNewerPatchComparesNumericallyNotLexically() {
        // 字符串比较会把 1.0.10 判成小于 1.0.9，然后用户永远收不到 1.0.10
        XCTAssertTrue(AppVersion.isNewer("v1.0.10", than: "1.0.9"))
        XCTAssertTrue(AppVersion.isNewer("v1.0.2", than: "1.0.10") == false)
        XCTAssertTrue(AppVersion.isNewer("v1.0.11", than: "1.0.2"))
    }

    func testLeadingVIsIgnored() {
        XCTAssertEqual(AppVersion.parse("v1.2.3"), AppVersion.parse("1.2.3"))
        XCTAssertEqual(AppVersion.parse("V1.2.3"), AppVersion.parse("1.2.3"))
    }

    func testTrailingZeroComponentsCompareEqual() {
        XCTAssertFalse(AppVersion.isNewer("1.1", than: "1.1.0"))
        XCTAssertFalse(AppVersion.isNewer("1.1.0", than: "1.1"))
        XCTAssertEqual(AppVersion.parse("1.1"), AppVersion.parse("1.1.0")?.components.isEmpty == false
            ? AppVersion.Parsed(components: [1, 1], isPrerelease: false) : nil)
    }

    func testSameVersionIsNotNewer() {
        XCTAssertFalse(AppVersion.isNewer("v1.0.0", than: "1.0.0"))
    }

    func testMajorAndMinorBumpsAreNewer() {
        XCTAssertTrue(AppVersion.isNewer("v2.0.0", than: "1.9.9"))
        XCTAssertTrue(AppVersion.isNewer("v1.2.0", than: "1.1.99"))
        XCTAssertFalse(AppVersion.isNewer("v1.1.0", than: "1.2.0"))
    }

    func testPrereleaseIsNotOffered() {
        // -beta / -rc 这类不该推给普通用户
        XCTAssertFalse(AppVersion.isNewer("v1.1.0-beta.1", than: "1.0.0"))
        XCTAssertTrue(AppVersion.parse("v1.1.0-beta.1")?.isPrerelease == true)
        XCTAssertTrue(AppVersion.parse("v1.1.0")?.isPrerelease == false)
    }

    func testGarbageVersionsAreRejected() {
        for text in ["", "v", "V", "abc", "1.a", "1..2", "1.", ".1", "  "] {
            XCTAssertNil(AppVersion.parse(text), "「\(text)」不该被解析成版本号")
            XCTAssertFalse(AppVersion.isNewer(text, than: "1.0.0"), "「\(text)」不该被判成新版本")
            XCTAssertFalse(AppVersion.isNewer("v9.9.9", than: text), "本地版本是「\(text)」时不该提示更新")
        }
    }

    func testOverlongVersionIsRejected() {
        XCTAssertNil(AppVersion.parse(String(repeating: "1", count: 100)))
    }

    func testCurrentVersionIsNilWhenUnpackaged() {
        XCTAssertNil(AppVersion.current(info: [:]))
        XCTAssertNil(AppVersion.current(info: ["CFBundleShortVersionString": ""]))
        XCTAssertEqual(AppVersion.current(info: ["CFBundleShortVersionString": "1.0.0"]), "1.0.0")
    }
}

// MARK: - 地址校验

final class AppUpdateLinkTests: XCTestCase {
    private let dmgPath = "https://github.com/SkyCTing/market-bar/releases/download/v1.1.0/MarketBar-1.1.0.dmg"

    func testAcceptsCanonicalDownloadURL() throws {
        let url = try XCTUnwrap(URL(string: dmgPath))
        XCTAssertEqual(AppUpdateLink.validated(url), url)
    }

    func testRejectsNonHTTPS() throws {
        // app 的 ATS 是放开的，系统不会拦 http —— 这道校验是唯一的闸门
        let url = try XCTUnwrap(URL(string: dmgPath.replacingOccurrences(of: "https://", with: "http://")))
        XCTAssertNil(AppUpdateLink.validated(url))
    }

    func testRejectsForeignHost() throws {
        let url = try XCTUnwrap(URL(string: "https://evil.example.com/SkyCTing/market-bar/releases/download/x.dmg"))
        XCTAssertNil(AppUpdateLink.validated(url))
    }

    func testRejectsHostSuffixSpoofing() throws {
        // hasSuffix 匹配会放行这两个
        for host in ["github.com.evil.com", "evilgithub.com"] {
            let url = try XCTUnwrap(URL(string: "https://\(host)/SkyCTing/market-bar/releases/download/x.dmg"))
            XCTAssertNil(AppUpdateLink.validated(url), "\(host) 不该被放行")
        }
    }

    func testRejectsCredentialsInURL() throws {
        let url = try XCTUnwrap(URL(string: "https://user:pw@github.com/SkyCTing/market-bar/releases/download/x.dmg"))
        XCTAssertNil(AppUpdateLink.validated(url))
    }

    func testRejectsURLOutsideThisRepository() throws {
        let url = try XCTUnwrap(URL(string: "https://github.com/SomeoneElse/other-app/releases/download/x.dmg"))
        XCTAssertNil(AppUpdateLink.validated(url))
    }

    func testRejectsRepositoryNamePrefixSpoofing() throws {
        // 只做 hasPrefix("/SkyCTing/market-bar") 的话这个会被放行
        let url = try XCTUnwrap(URL(string: "https://github.com/SkyCTing/market-bar-evil/releases/download/x.dmg"))
        XCTAssertNil(AppUpdateLink.validated(url))
    }

    func testPrefersCanonicalAssetName() throws {
        let other = try XCTUnwrap(URL(string: "https://github.com/SkyCTing/market-bar/releases/download/v1.1.0/extra.dmg"))
        let canonical = try XCTUnwrap(URL(string: dmgPath))
        let release = try makeRelease(assets: [
            AppRelease.Asset(name: "extra.dmg", downloadURL: other),
            AppRelease.Asset(name: "MarketBar-1.1.0.dmg", downloadURL: canonical),
        ])
        XCTAssertEqual(AppUpdateLink.downloadTarget(for: release), canonical)
    }

    func testFallsBackToReleasePageWhenNoDMG() throws {
        let release = try makeRelease(assets: [
            AppRelease.Asset(
                name: "source.zip",
                downloadURL: try XCTUnwrap(URL(string: "https://github.com/SkyCTing/market-bar/archive/v1.1.0.zip"))
            ),
        ])
        XCTAssertEqual(AppUpdateLink.downloadTarget(for: release), release.pageURL)
    }

    func testNonGithubAssetFallsBackToReleasePage() throws {
        let release = try makeRelease(assets: [
            AppRelease.Asset(
                name: "MarketBar-1.1.0.dmg",
                downloadURL: try XCTUnwrap(URL(string: "https://evil.example.com/MarketBar-1.1.0.dmg"))
            ),
        ])
        XCTAssertEqual(AppUpdateLink.downloadTarget(for: release), release.pageURL)
    }

    func testRejectsReleasePageOnAnotherHost() throws {
        let release = try makeRelease(pageURL: "https://evil.example.com/SkyCTing/market-bar/releases")
        XCTAssertNil(AppUpdateLink.downloadTarget(for: release))
        XCTAssertNil(AppUpdateLink.pageTarget(for: release))
    }

    func testDiskImageCheckRejectsNonDiskImageBytes() {
        XCTAssertFalse(AppUpdateDownloader.isDiskImage(Data(repeating: 0, count: 4096)))
        XCTAssertFalse(AppUpdateDownloader.isDiskImage(Data("koly".utf8)))
        var looksLikeDMG = Data(repeating: 0, count: 600)
        looksLikeDMG.replaceSubrange(600 - 512 ..< 600 - 508, with: Data("koly".utf8))
        XCTAssertTrue(AppUpdateDownloader.isDiskImage(looksLikeDMG))
    }
}

// MARK: - 发布说明

final class AppUpdateNotesTests: XCTestCase {
    func testStripsHeadingAndEmphasisMarkers() {
        let text = AppUpdateNotes.summary(from: "## 主要功能\n\n**加粗**和`代码`")
        XCTAssertFalse(text.contains("#"))
        XCTAssertFalse(text.contains("*"))
        XCTAssertFalse(text.contains("`"))
        XCTAssertTrue(text.contains("主要功能"))
        XCTAssertTrue(text.contains("加粗和代码"))
    }

    func testLinksReduceToTheirTextAndImagesAreDropped() {
        let text = AppUpdateNotes.summary(from: "见 [发布说明](https://example.com/a)\n\n![截图](https://example.com/b.png)")
        XCTAssertEqual(text, "见 发布说明")
    }

    func testBlankLinesAreCollapsed() {
        XCTAssertEqual(AppUpdateNotes.summary(from: "第一行\n\n\n\n第二行"), "第一行\n第二行")
    }

    func testLongNotesAreTruncatedOnALineBoundary() {
        let body = (1 ... 40).map { "第 \($0) 行说明文字" }.joined(separator: "\n")
        let text = AppUpdateNotes.summary(from: body, limit: 60)
        XCTAssertTrue(text.hasSuffix("…"))
        XCTAssertTrue(text.count <= 61)
        // 不是硬切：每一段都还是完整的行
        for line in text.dropLast().components(separatedBy: "\n") {
            XCTAssertTrue(line.hasPrefix("第 ") && line.hasSuffix("行说明文字"), "被切碎的片段：\(line)")
        }
    }

    func testEmptyNotesStayEmpty() {
        XCTAssertEqual(AppUpdateNotes.summary(from: ""), "")
        XCTAssertEqual(AppUpdateNotes.summary(from: "   \n\n  "), "")
    }

    func testHugeBodyIsBoundedBeforeProcessing() {
        let text = AppUpdateNotes.summary(from: String(repeating: "a", count: 500_000), limit: 10)
        XCTAssertTrue(text.count <= 11)
    }
}

// MARK: - Service

final class AppUpdateServiceTests: XCTestCase {
    func testLatestReleaseParsesTagNotesAndAsset() async throws {
        let stub = UpdateHTTPStub([(200, try releasePayload())])
        let service = AppUpdateService(transport: { try await stub.send($0) })
        let release = try await service.latestRelease()
        XCTAssertEqual(release.tag, "v1.1.0")
        XCTAssertEqual(release.assets.count, 1)
        XCTAssertEqual(release.assets.first?.name, "MarketBar-1.1.0.dmg")
        XCTAssertEqual(release.notes.contains("新功能"), true)
    }

    func testRequestCarriesUserAgentAndPinsAPIVersion() async throws {
        let stub = UpdateHTTPStub([(200, try releasePayload())])
        let service = AppUpdateService(transport: { try await stub.send($0) })
        _ = try await service.latestRelease()
        let requests = await stub.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url, AppUpdateService.feedURL)
        // GitHub 的 API 不带 User-Agent 会直接 403
        XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        // 公共仓库，任何时候都不该带凭据
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testNotFoundMeansNoReleaseYet() async throws {
        let stub = UpdateHTTPStub([(404, Data(#"{"message":"Not Found"}"#.utf8))])
        let service = AppUpdateService(transport: { try await stub.send($0) })
        do {
            _ = try await service.latestRelease()
            XCTFail("404 应该抛错")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("还没有发布"), error.localizedDescription)
        }
    }

    func testRateLimitIsReportedAsThrottling() async throws {
        let stub = UpdateHTTPStub([(403, Data())])
        let service = AppUpdateService(transport: { try await stub.send($0) })
        do {
            _ = try await service.latestRelease()
            XCTFail("403 应该抛错")
        } catch {
            // 403 但没有 ratelimit 头 = 不是限流，走通用提示
            XCTAssertFalse(error.localizedDescription.contains("限流"), error.localizedDescription)
        }
    }

    func testMalformedResponseDoesNotLeakServerBody() async throws {
        let secret = "private error content"
        let stub = UpdateHTTPStub([(200, Data(#"{"oops":"\#(secret)"}"#.utf8))])
        let service = AppUpdateService(transport: { try await stub.send($0) })
        do {
            _ = try await service.latestRelease()
            XCTFail("格式不对应该抛错")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains(secret), error.localizedDescription)
        }
    }

    func testOversizedResponseIsRejected() async throws {
        let huge = Data(repeating: 0x20, count: AppUpdateService.maximumResponseBytes + 1)
        let stub = UpdateHTTPStub([(200, huge)])
        let service = AppUpdateService(transport: { try await stub.send($0) })
        do {
            _ = try await service.latestRelease()
            XCTFail("超大响应应该抛错")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("异常大"), error.localizedDescription)
        }
    }

    func testMissingTagIsTreatedAsMalformed() async throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "html_url": "https://github.com/SkyCTing/market-bar/releases/tag/v1.0.0",
        ])
        let stub = UpdateHTTPStub([(200, payload)])
        let service = AppUpdateService(transport: { try await stub.send($0) })
        do {
            _ = try await service.latestRelease()
            XCTFail("缺 tag_name 应该抛错")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("看不懂"), error.localizedDescription)
        }
    }

    func testOneBrokenAssetDoesNotDiscardTheRelease() async throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "tag_name": "v1.1.0",
            "html_url": "https://github.com/SkyCTing/market-bar/releases/tag/v1.1.0",
            "body": "",
            "assets": [
                ["name": "broken.dmg"],  // 缺 browser_download_url
                ["name": "MarketBar-1.1.0.dmg",
                 "browser_download_url": "https://github.com/SkyCTing/market-bar/releases/download/v1.1.0/MarketBar-1.1.0.dmg"],
            ],
        ])
        let stub = UpdateHTTPStub([(200, payload)])
        let service = AppUpdateService(transport: { try await stub.send($0) })
        let release = try await service.latestRelease()
        XCTAssertEqual(release.assets.map(\.name), ["MarketBar-1.1.0.dmg"])
    }
}

// MARK: - Controller

@MainActor
final class AppUpdateControllerTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "AppUpdateControllerTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
    }

    /// 检查是异步的，而 controller 只在 onChange 里冒头（下载状态变化、一次检查收尾）
    private func waitUntilIdle(_ controller: AppUpdateController, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while controller.isBusy, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func makeController(
        stub: UpdateHTTPStub,
        ui: UIRecorder,
        downloads: DownloadStub = DownloadStub(),
        version: String? = "1.0.0",
        canPresent: Bool = true
    ) -> AppUpdateController {
        AppUpdateController(
            defaults: defaults,
            service: AppUpdateService(transport: { try await stub.send($0) }),
            currentVersion: { version },
            prompt: { prompt in
                ui.prompts.append(prompt)
                return ui.choice
            },
            report: { ui.reports.append(($0, $1)) },
            open: { url in
                ui.opened.append(url)
                return ui.openSucceeds
            },
            download: { url, name in
                await downloads.record(url, name)
                return try await downloads.resolved()
            },
            canPresent: { canPresent }
        )
    }

    func testAutoCheckIsOnByDefaultButHonorsAStoredFalse() {
        let ui = UIRecorder()
        let controller = makeController(stub: UpdateHTTPStub([]), ui: ui)
        // 缺省的 Bool 读出来是 false —— 不判「存过没有」就等于默认关
        XCTAssertTrue(controller.autoCheckEnabled)
        controller.autoCheckEnabled = false
        XCTAssertFalse(controller.autoCheckEnabled)
        let reloaded = makeController(stub: UpdateHTTPStub([]), ui: ui)
        XCTAssertFalse(reloaded.autoCheckEnabled)
    }

    func testAutoCheckIsThrottledWithinADay() async throws {
        let stub = UpdateHTTPStub([(200, try releasePayload(tag: "v1.0.0", assets: []))])
        let ui = UIRecorder()
        let controller = makeController(stub: stub, ui: ui)
        let now = Date()
        controller.checkForUpdatesIfNeeded(at: now)
        await waitUntilIdle(controller)
        let afterFirst = await stub.requests.count
        XCTAssertEqual(afterFirst, 1)

        // 同一天内再来几次都不该发请求
        for offset in [60.0, 3_600.0, 23 * 3_600.0] {
            controller.checkForUpdatesIfNeeded(at: now.addingTimeInterval(offset))
            await waitUntilIdle(controller)
        }
        let stillOne = await stub.requests.count
        XCTAssertEqual(stillOne, 1)

        // 过了 24 小时才再查
        controller.checkForUpdatesIfNeeded(at: now.addingTimeInterval(AppUpdateController.checkInterval + 1))
        await waitUntilIdle(controller)
        let afterADay = await stub.requests.count
        XCTAssertEqual(afterADay, 2)
    }

    func testClockRollbackDoesNotLockTheUserOut() async throws {
        let stub = UpdateHTTPStub([(200, try releasePayload(tag: "v1.0.0", assets: []))])
        let controller = makeController(stub: stub, ui: UIRecorder())
        let now = Date()
        controller.checkForUpdatesIfNeeded(at: now)
        await waitUntilIdle(controller)
        // 系统时钟被往回调：elapsed 是负数，不处理的话要等到时钟追上来才会再查
        controller.checkForUpdatesIfNeeded(at: now.addingTimeInterval(-90 * 24 * 3_600))
        await waitUntilIdle(controller)
        let count = await stub.requests.count
        XCTAssertEqual(count, 2)
    }

    func testAutoCheckDoesNothingWhenDisabled() async throws {
        let stub = UpdateHTTPStub([(200, try releasePayload())])
        let controller = makeController(stub: stub, ui: UIRecorder())
        controller.autoCheckEnabled = false
        controller.checkForUpdatesIfNeeded()
        await waitUntilIdle(controller)
        let requests = await stub.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testUnpackagedBuildMakesNoRequest() async throws {
        let stub = UpdateHTTPStub([(200, try releasePayload())])
        let ui = UIRecorder()
        let controller = makeController(stub: stub, ui: ui, version: nil)

        controller.checkForUpdatesIfNeeded()
        await waitUntilIdle(controller)
        let requests = await stub.requests
        XCTAssertTrue(requests.isEmpty, "未打包的构建不该发请求")

        // 手动点会解释一句为什么不能查，但也不发请求
        controller.checkForUpdates()
        await waitUntilIdle(controller)
        let afterManual = await stub.requests
        XCTAssertTrue(afterManual.isEmpty)
        XCTAssertEqual(ui.lastReport?.title, "没法检查更新")
    }

    func testAlreadyLatestIsReportedWithoutDownloadOffer() async throws {
        let stub = UpdateHTTPStub([(200, try releasePayload(tag: "v1.0.0", assets: []))])
        let ui = UIRecorder()
        let controller = makeController(stub: stub, ui: ui)
        controller.checkForUpdates()
        await waitUntilIdle(controller)
        XCTAssertTrue(ui.prompts.isEmpty, "没有新版本就不该弹升级框")
        XCTAssertEqual(ui.lastReport?.title, "已是最新版本")
    }

    func testAutomaticCheckStaysSilentWhenAlreadyLatest() async throws {
        let stub = UpdateHTTPStub([(200, try releasePayload(tag: "v1.0.0", assets: []))])
        let ui = UIRecorder()
        let controller = makeController(stub: stub, ui: ui)
        controller.checkForUpdatesIfNeeded()
        await waitUntilIdle(controller)
        XCTAssertTrue(ui.reports.isEmpty, "自动检查必须彻底安静")
    }

    func testAutomaticFailureIsSilent() async throws {
        let stub = UpdateHTTPStub([(500, Data())])
        let ui = UIRecorder()
        let controller = makeController(stub: stub, ui: ui)
        controller.checkForUpdatesIfNeeded()
        await waitUntilIdle(controller)
        XCTAssertTrue(ui.reports.isEmpty)
    }

    func testManualFailureIsReported() async throws {
        let stub = UpdateHTTPStub([(500, Data())])
        let ui = UIRecorder()
        let controller = makeController(stub: stub, ui: ui)
        controller.checkForUpdates()
        await waitUntilIdle(controller)
        XCTAssertEqual(ui.lastReport?.title, "检查更新失败")
    }

    func testNewVersionPromptsAndDownloadsOnlyAfterUserChoosesDownload() async throws {
        // 两次检查（第一次选「稍后」、第二次选「下载」），所以排两个响应
        let stub = UpdateHTTPStub([(200, try releasePayload()), (200, try releasePayload())])
        let ui = UIRecorder()
        let downloads = DownloadStub()
        let controller = makeController(stub: stub, ui: ui, downloads: downloads)

        controller.checkForUpdates()
        await waitUntilIdle(controller)

        let prompt = try XCTUnwrap(ui.prompts.first)
        XCTAssertEqual(prompt.newVersion, "v1.1.0")
        XCTAssertEqual(prompt.currentVersion, "1.0.0")
        XCTAssertTrue(prompt.notes.contains("自选分组"), "发布说明该被处理成纯文本：\(prompt.notes)")
        XCTAssertFalse(prompt.notes.contains("*"))

        // 默认选「稍后」—— 没选下载就不该下任何东西
        let beforeChoice = await downloads.calls
        XCTAssertTrue(beforeChoice.isEmpty)

        ui.choice = .download
        controller.checkForUpdates()
        await waitUntilIdle(controller)
        let calls = await downloads.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "MarketBar-v1.1.0.dmg")
        XCTAssertEqual(ui.opened.last?.path, "/tmp/MarketBar-test.dmg")
        // 第一次选的「稍后」已经把 v1.1.0 记成跳过了；后来改成下载**不清掉**它 ——
        // 用户已经拿到这个版本了，自动检查对同一个版本保持安静才是对的
        XCTAssertEqual(controller.skippedVersion, "v1.1.0")
    }

    func testOpenPageChoiceOpensTheReleasePage() async throws {
        let stub = UpdateHTTPStub([(200, try releasePayload())])
        let ui = UIRecorder()
        ui.choice = .openPage
        let controller = makeController(stub: stub, ui: ui)
        controller.checkForUpdates()
        await waitUntilIdle(controller)
        XCTAssertEqual(ui.opened.last?.absoluteString,
                       "https://github.com/SkyCTing/market-bar/releases/tag/v1.1.0")
    }

    func testFailedDownloadIsSurfaced() async throws {
        let stub = UpdateHTTPStub([(200, try releasePayload())])
        let ui = UIRecorder()
        ui.choice = .download
        let downloads = DownloadStub()
        await downloads.setResult(.failure(AppUpdateError.message("下载到的文件不是磁盘映像，已放弃")))
        let controller = makeController(stub: stub, ui: ui, downloads: downloads)

        controller.checkForUpdates()
        await waitUntilIdle(controller)

        XCTAssertEqual(ui.lastReport?.title, "下载更新失败")
        XCTAssertEqual(ui.lastReport?.body, "下载到的文件不是磁盘映像，已放弃")
        XCTAssertFalse(controller.isDownloading, "失败之后要恢复可点状态")
    }

    func testDownloadFailureToOpenFallsBackToAPathHint() async throws {
        let stub = UpdateHTTPStub([(200, try releasePayload())])
        let ui = UIRecorder()
        ui.choice = .download
        ui.openSucceeds = false
        let controller = makeController(stub: stub, ui: ui)

        controller.checkForUpdates()
        await waitUntilIdle(controller)

        XCTAssertEqual(ui.lastReport?.title, "更新已下载")
        XCTAssertTrue(ui.lastReport?.body.contains("/tmp/MarketBar-test.dmg") == true)
    }

    func testAutomaticCheckSkipsPresentationWhenAModalIsAlreadyUp() async throws {
        // 自动一次 + 手动一次，各要一个响应
        let stub = UpdateHTTPStub([(200, try releasePayload()), (200, try releasePayload())])
        let ui = UIRecorder()
        let controller = makeController(stub: stub, ui: ui, canPresent: false)

        controller.checkForUpdatesIfNeeded()
        await waitUntilIdle(controller)

        let count = await stub.requests.count
        XCTAssertEqual(count, 1, "该查还是要查")
        XCTAssertTrue(ui.prompts.isEmpty, "已经有模态框时不能叠一个上去")

        // 手动点不受这个限制：本来就是用户自己发起的
        controller.checkForUpdates()
        await waitUntilIdle(controller)
        XCTAssertEqual(ui.prompts.count, 1)
    }

    func testManualCheckIsNotThrottled() async throws {
        let stub = UpdateHTTPStub([(200, try releasePayload()), (200, try releasePayload())])
        let controller = makeController(stub: stub, ui: UIRecorder())
        controller.checkForUpdates()
        await waitUntilIdle(controller)
        controller.checkForUpdates()
        await waitUntilIdle(controller)
        let count = await stub.requests.count
        XCTAssertEqual(count, 2)
    }

    func testSkippedVersionSuppressesTheAutomaticAlertButNotTheManualOne() async throws {
        // 三次检查：自动（选稍后）→ 自动（该被跳过）→ 手动（该显示）
        let stub = UpdateHTTPStub([
            (200, try releasePayload()), (200, try releasePayload()), (200, try releasePayload()),
        ])
        let ui = UIRecorder()
        let controller = makeController(stub: stub, ui: ui)

        controller.checkForUpdatesIfNeeded()
        await waitUntilIdle(controller)
        XCTAssertEqual(ui.prompts.count, 1)
        // 默认选「稍后」
        XCTAssertEqual(controller.skippedVersion, "v1.1.0", "选了「稍后」要记住这个版本")

        controller.checkForUpdatesIfNeeded(at: Date().addingTimeInterval(AppUpdateController.checkInterval + 1))
        await waitUntilIdle(controller)
        XCTAssertEqual(ui.prompts.count, 1, "同一个版本不该再打扰")

        controller.checkForUpdates()
        await waitUntilIdle(controller)
        XCTAssertEqual(ui.prompts.count, 2, "手动点必须还能看到")
    }

    func testSkippingOneVersionDoesNotSuppressTheNext() async throws {
        let stub = UpdateHTTPStub([
            (200, try releasePayload(tag: "v1.1.0")),
            (200, try releasePayload(tag: "v1.2.0")),
        ])
        let ui = UIRecorder()
        let controller = makeController(stub: stub, ui: ui)

        controller.checkForUpdatesIfNeeded()
        await waitUntilIdle(controller)
        XCTAssertEqual(controller.skippedVersion, "v1.1.0")

        // 来了更新的版本 —— 不是被跳过那个，照常提醒
        controller.checkForUpdatesIfNeeded(at: Date().addingTimeInterval(AppUpdateController.checkInterval + 1))
        await waitUntilIdle(controller)
        XCTAssertEqual(ui.prompts.count, 2)
        XCTAssertEqual(ui.prompts.last?.newVersion, "v1.2.0")
    }

    func testSkipIsPersisted() throws {
        let controller = makeController(stub: UpdateHTTPStub([]), ui: UIRecorder())
        XCTAssertNil(controller.skippedVersion)
        controller.skippedVersion = "v1.1.0"
        let reloaded = makeController(stub: UpdateHTTPStub([]), ui: UIRecorder())
        XCTAssertEqual(reloaded.skippedVersion, "v1.1.0")
        reloaded.skippedVersion = nil
        XCTAssertNil(makeController(stub: UpdateHTTPStub([]), ui: UIRecorder()).skippedVersion)
    }

    func testShutdownCancelsAnInFlightCheck() async throws {
        let stub = UpdateHTTPStub([(200, try releasePayload())])
        let ui = UIRecorder()
        let controller = makeController(stub: stub, ui: ui)
        controller.checkForUpdates()
        controller.shutdown()
        await waitUntilIdle(controller)
        XCTAssertTrue(ui.prompts.isEmpty)
        XCTAssertTrue(ui.reports.isEmpty)
    }
}
