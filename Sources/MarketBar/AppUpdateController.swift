import AppKit

/// 「有新版本」那个弹框。和 `AboutMarketBar.show()` 同款：同步 runModal
@MainActor
enum AppUpdateAlert {
    static func prompt(_ update: AppUpdatePrompt) -> AppUpdateChoice {
        let alert = NSAlert()
        alert.messageText = "有新版本 \(update.newVersion)"
        var body = "当前版本 \(update.currentVersion)"
        if !update.notes.isEmpty { body += "\n\n" + update.notes }
        alert.informativeText = body
        // 三个按钮的含义固定，不因为「这次有没有 .dmg 可下」而变位置
        alert.addButton(withTitle: "下载并打开")
        alert.addButton(withTitle: "打开发布页")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .download
        case .alertSecondButtonReturn: return .openPage
        default: return .later
        }
    }

    static func report(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// 检查更新的状态机：节流、开关、弹框、下载。
///
/// 形状照 `AISignController`：`@MainActor` + 注入 `defaults` + `task` 句柄 +
/// `generation` 令牌丢过期结果 + `onChange` 通知重画菜单。
@MainActor
final class AppUpdateController {
    typealias Prompt = @MainActor (AppUpdatePrompt) -> AppUpdateChoice
    typealias Report = @MainActor (String, String) -> Void
    typealias Open = @MainActor (URL) -> Bool
    typealias Download = @Sendable (URL, String) async throws -> URL
    typealias CanPresent = @MainActor () -> Bool

    static let autoCheckKey = "appUpdateAutoCheck"
    static let lastCheckKey = "appUpdateLastCheck"
    static let skippedVersionKey = "appUpdateSkippedVersion"
    /// 自动检查的间隔。按 24 小时算，不是「每个自然日」——
    /// 后者会让每天第一次启动都发请求，而这个 app 一天可能启动很多次。
    /// ⚠️ 必须**持久化**：`refreshHolidaysIfNeeded` 参考的那个 `holidayFetchDate`
    /// 是内存变量（MarketBar.swift:628），每次启动都归零，等于每次启动查一次。
    /// 节假日一天查几次无所谓，GitHub 是 60 次/小时的限额，不能这么花
    static let checkInterval: TimeInterval = 24 * 60 * 60

    private let defaults: UserDefaults
    private let service: AppUpdateService
    private let currentVersion: @Sendable () -> String?
    private let prompt: Prompt
    private let report: Report
    private let open: Open
    private let download: Download
    private let canPresent: CanPresent

    private var task: Task<Void, Never>?
    private var generation = UUID()
    private(set) var isDownloading = false

    /// 下载状态变了要重画菜单（标题里的「正在下载更新…」）
    var onChange: (() -> Void)?

    init(
        defaults: UserDefaults = .standard,
        service: AppUpdateService = AppUpdateService(),
        currentVersion: @escaping @Sendable () -> String? = { AppVersion.installed },
        prompt: @escaping Prompt = { AppUpdateAlert.prompt($0) },
        report: @escaping Report = { AppUpdateAlert.report($0, $1) },
        open: @escaping Open = { NSWorkspace.shared.open($0) },
        download: @escaping Download = { try await AppUpdateDownloader.download($0, as: $1) },
        canPresent: @escaping CanPresent = { NSApp.modalWindow == nil }
    ) {
        self.defaults = defaults
        self.service = service
        self.currentVersion = currentVersion
        self.prompt = prompt
        self.report = report
        self.open = open
        self.download = download
        self.canPresent = canPresent
    }

    /// 缺省的 Bool 读出来是 false，所以要先判「这个键到底存过没有」，
    /// 否则默认值就成了「关」，整个功能等于没上
    var autoCheckEnabled: Bool {
        get {
            guard defaults.object(forKey: Self.autoCheckKey) != nil else { return true }
            return defaults.bool(forKey: Self.autoCheckKey)
        }
        set { defaults.set(newValue, forKey: Self.autoCheckKey) }
    }

    /// 用户在弹框里选了「稍后」的那个版本。
    ///
    /// 自动检查不再为**这个**版本打扰人；发布了更新的版本自然是另一个 tag，照常提醒。
    /// 手动点「检查更新…」不受它影响 —— 那是用户自己要看，不能替他决定不看
    var skippedVersion: String? {
        get { defaults.string(forKey: Self.skippedVersionKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Self.skippedVersionKey)
            } else {
                defaults.removeObject(forKey: Self.skippedVersionKey)
            }
        }
    }

    var menuTitle: String { isDownloading ? "正在下载更新…" : "检查更新…" }

    /// 手头有活（正在查或正在下）
    var isBusy: Bool { task != nil }

    /// 自动检查：关掉开关、跑在未打包的构建里、24 小时内查过、正在下载 —— 都不查
    func checkForUpdatesIfNeeded(at now: Date = Date()) {
        guard autoCheckEnabled, task == nil, currentVersion() != nil else { return }
        if let last = defaults.object(forKey: Self.lastCheckKey) as? Date {
            let elapsed = now.timeIntervalSince(last)
            // elapsed < 0 说明系统时钟被往回调过，按「该查了」处理 ——
            // 否则用户会被锁到时钟追上来为止
            if elapsed >= 0, elapsed < Self.checkInterval { return }
        }
        checkForUpdates(at: now, interactive: false)
    }

    /// 手动检查（interactive）不管开关和节流，点了就查
    func checkForUpdates(at now: Date = Date(), interactive: Bool = true) {
        guard task == nil else { return }
        guard let current = currentVersion() else {
            // 未打包（swift run）时版本号无从比较，直接说清楚，不发请求
            if interactive {
                report(
                    "没法检查更新",
                    "这是未打包的开发版本（swift run），没有版本号可以比较。"
                        + "打包成 .app 之后「关于」里能看到版本号，更新检查也才能用。"
                )
            }
            return
        }

        // ⚠️ 戳在**发请求之前**写：写在之后的话，接口一直失败就会变成每次刷新都重试。
        // 代价是「这次因为弹不出框而没提醒」会顺延到明天，这个可以接受。
        // 手动检查也走这一行 —— 手动点完不该马上又被自动检查查一遍，那样是白花配额
        defaults.set(now, forKey: Self.lastCheckKey)

        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            // 无论查成没查成都要通知一次：菜单要重画，测试也靠它知道这次结束了
            defer {
                if self.generation == token { self.onChange?() }
            }
            do {
                let release = try await self.service.latestRelease()
                try Task.checkCancellation()
                guard self.generation == token else { return }
                self.task = nil
                self.settle(release: release, current: current, interactive: interactive)
            } catch is CancellationError {
                guard self.generation == token else { return }
                self.task = nil
            } catch {
                guard self.generation == token else { return }
                self.task = nil
                if interactive {
                    self.report("检查更新失败", error.localizedDescription)
                } else {
                    // 自动检查是静默的：失败不该弹框打断人
                    NSLog("MarketBar: 检查更新失败 %@", error.localizedDescription)
                }
            }
        }
    }

    func shutdown() {
        generation = UUID()
        task?.cancel()
        task = nil
    }

    private func settle(release: AppRelease, current: String, interactive: Bool) {
        guard AppVersion.isNewer(release.tag, than: current) else {
            // 「已是最新」只在手动点的时候说；自动检查必须彻底安静
            if interactive {
                report("已是最新版本", "当前 \(current)，GitHub 上最新的是 \(release.tag)。")
            }
            return
        }

        if !interactive {
            // 用户已经对这个版本说过「稍后」，别再问了
            guard release.tag != skippedVersion else { return }
            // 已经有别的模态框（提醒弹窗之类）挂着时别再叠一个 —— 两个框叠在一起
            // 用户分不清哪个是哪个。自动检查就当这次没发生，明天再说
            guard canPresent() else { return }
        }

        let update = AppUpdatePrompt(
            currentVersion: current,
            newVersion: release.tag,
            notes: AppUpdateNotes.summary(from: release.notes),
            downloadURL: AppUpdateLink.downloadTarget(for: release),
            pageURL: AppUpdateLink.pageTarget(for: release)
        )

        // runModal 是同步的：它返回之后才轮到下载。
        // 期间主队列还在跑（模态框会转自己的 runloop），所以这之后的状态要重新读，
        // 不能信进弹框之前抓的快照 —— startDownload 里就是这么做的
        switch prompt(update) {
        case .download:
            guard let url = update.downloadURL else {
                openPage(update)
                return
            }
            startDownload(from: url, version: release.tag)
        case .openPage:
            openPage(update)
        case .later:
            // 记住这个版本，明天自动检查不再为它打扰
            skippedVersion = release.tag
        }
    }

    private func openPage(_ update: AppUpdatePrompt) {
        guard let page = update.pageURL else {
            report(
                "没有可用的链接",
                "GitHub 返回的版本信息里没有能打开的地址。"
                    + "可以手动访问 github.com/SkyCTing/market-bar/releases 看看。"
            )
            return
        }
        if !open(page) {
            report("没能打开浏览器", "手动访问 \(page.absoluteString) 即可。")
        }
    }

    private func startDownload(from url: URL, version: String) {
        // 下载中再点一次不该起第二个任务（弹框期间主队列还在跑，所以这里要重判）
        guard !isDownloading else { return }
        isDownloading = true
        onChange?()

        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let file = try await self.download(url, "MarketBar-\(version).dmg")
                try Task.checkCancellation()
                guard self.generation == token else { return }
                self.settleDownload()
                // 打开 DMG 本身就是「下好了」的反馈；只有打不开时才需要报一句
                if !self.open(file) {
                    self.report(
                        "更新已下载",
                        "安装包在 \(file.path)。双击打开，把 MarketBar 拖进「应用程序」就完成更新了。"
                    )
                }
            } catch {
                guard self.generation == token else { return }
                self.settleDownload()
                self.report("下载更新失败", error.localizedDescription)
            }
        }
    }

    private func settleDownload() {
        isDownloading = false
        task = nil
        onChange?()
    }
}
