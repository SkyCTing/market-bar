import AppKit

@MainActor
final class AISignController {
    static let settingsKey = "aiSignSettings"
    static let refreshInterval: TimeInterval = 30 * 60
    private let defaults: UserDefaults
    private let keys: any AIKeyStore
    private let service: AISignService
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var nextRefresh = Date.distantPast
    private(set) var settings = AISignSettings()
    private(set) var content: AISignContent?
    private(set) var lastError: String?
    var onChange: (() -> Void)?

    init(
        defaults: UserDefaults = .standard,
        keys: any AIKeyStore = KeychainAIKeyStore(),
        service: AISignService = AISignService()
    ) {
        self.defaults = defaults
        self.keys = keys
        self.service = service
        if let data = defaults.data(forKey: Self.settingsKey) {
            do {
                settings = try JSONDecoder().decode(AISignSettings.self, from: data)
                try settings.validate()
            } catch {
                settings = AISignSettings()
                lastError = "AI 举牌配置无效，请重新保存设置"
                NSLog("AI sign settings could not be loaded")
            }
        }
    }

    var status: String {
        if let lastError { return lastError }
        if !settings.enabled { return "未启用" }
        if task != nil { return "正在更新…" }
        if content != nil { return "已更新 · 30 分钟刷新" }
        return "等待休市时更新"
    }

    func lines(at date: Date, isTradingDay: Bool) -> (headline: String, greeting: String)? {
        guard settings.enabled, !isTradingDay else { return nil }
        return content?.lines(at: date)
    }

    func refreshIfNeeded(at now: Date = Date(), canDisplay: Bool, force: Bool = false) {
        guard settings.enabled, canDisplay, task == nil, force || now >= nextRefresh else { return }
        nextRefresh = now.addingTimeInterval(Self.refreshInterval)
        let token = generation
        let settings = settings
        lastError = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let key = try self.keys.read("deepseek") ?? ""
                let searchKey = settings.usesWebSearch ? try self.keys.read("tavily") : nil
                let result = try await self.service.generate(
                    settings: settings, deepSeekKey: key, searchKey: searchKey, at: now
                )
                try Task.checkCancellation()
                guard self.generation == token else { return }
                self.content = result
            } catch {
                guard self.generation == token else { return }
                self.lastError = error.localizedDescription
                NSLog("AI sign refresh failed: %@", error.localizedDescription)
            }
            guard self.generation == token else { return }
            self.task = nil
            self.onChange?()
        }
        onChange?()
    }

    func shutdown() {
        generation = UUID()
        task?.cancel()
        task = nil
    }

    func save(_ value: AISignSettings, deepSeekKey: String, searchKey: String) throws {
        try value.validate()
        let deepSeekKey = deepSeekKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchKey = searchKey.trimmingCharacters(in: .whitespacesAndNewlines)
        for key in [deepSeekKey, searchKey] where key.contains(where: \.isWhitespace) {
            throw AISignError.message("Key 中间不能包含空白字符")
        }
        if value.enabled {
            if deepSeekKey.isEmpty, try (keys.read("deepseek") ?? "").isEmpty {
                throw AISignError.message("启用 AI 举牌需要填写 DeepSeek Key")
            }
            if value.usesWebSearch, searchKey.isEmpty, try (keys.read("tavily") ?? "").isEmpty {
                throw AISignError.message("启用联网搜索需要填写 Tavily Key")
            }
        }
        if !deepSeekKey.isEmpty { try keys.save(deepSeekKey, account: "deepseek") }
        if !searchKey.isEmpty { try keys.save(searchKey, account: "tavily") }
        let encoded = try JSONEncoder().encode(value)
        shutdown()
        settings = value
        content = nil
        lastError = nil
        nextRefresh = .distantPast
        defaults.set(encoded, forKey: Self.settingsKey)
        onChange?()
    }

    func showSettings() {
        let alert = NSAlert()
        alert.messageText = "AI 举牌 · DeepSeek"
        alert.informativeText = """
        仅替换休市问候，不改交易日金价/盈亏和 Claude 聊天。
        开启后，宠物可见且休市时每 30 分钟请求一次，可能产生 API 费用。
        只发送主题、北京时间和搜索摘要，不发送持仓、聊天或本地文件。
        """
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 280))
        let enabled = NSButton(checkboxWithTitle: "休市时启用 AI 举牌", target: nil, action: nil)
        enabled.frame = NSRect(x: 0, y: 250, width: 450, height: 24)
        enabled.state = settings.enabled ? .on : .off
        form.addSubview(enabled)
        let search = NSButton(checkboxWithTitle: "联网资讯（Tavily 搜索；关闭则为非实时灵感）", target: nil, action: nil)
        search.frame = NSRect(x: 0, y: 220, width: 455, height: 24)
        search.state = settings.usesWebSearch ? .on : .off
        form.addSubview(search)

        func field(_ title: String, y: CGFloat, secure: Bool = false) -> NSTextField {
            let label = NSTextField(labelWithString: title)
            label.frame = NSRect(x: 0, y: y, width: 125, height: 24)
            form.addSubview(label)
            let input: NSTextField = secure ? NSSecureTextField() : NSTextField()
            input.frame = NSRect(x: 130, y: y, width: 325, height: 24)
            form.addSubview(input)
            return input
        }
        let topic = field("关注主题", y: 185)
        topic.stringValue = settings.topic
        let model = field("DeepSeek 模型", y: 150)
        model.stringValue = settings.model
        let deepSeekKey = field("DeepSeek Key", y: 115, secure: true)
        let searchKey = field("Tavily Key（可选）", y: 80, secure: true)
        deepSeekKey.placeholderString = "填新 Key；留空保留已保存的 Key"
        searchKey.placeholderString = "联网搜索需要独立 Key"
        let hint = NSTextField(wrappingLabelWithString:
            "Key 仅存入 macOS 钥匙串。申请入口：platform.deepseek.com / app.tavily.com\n未启用时不请求；结果保留最多 2 小时，来源可从菜单查看。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 0, y: 5, width: 455, height: 58)
        form.addSubview(hint)
        alert.accessoryView = form
        while alert.runModal() == .alertFirstButtonReturn {
            do {
                try save(
                    AISignSettings(
                        enabled: enabled.state == .on, usesWebSearch: search.state == .on,
                        model: model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                        topic: topic.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    ),
                    deepSeekKey: deepSeekKey.stringValue, searchKey: searchKey.stringValue
                )
                return
            } catch {
                let failure = NSAlert()
                failure.messageText = "AI 举牌设置未保存"
                failure.informativeText = error.localizedDescription
                failure.runModal()
            }
        }
    }

    func showDetails() {
        let alert = NSAlert()
        alert.messageText = "AI 举牌 · 内容与来源"
        guard let content else {
            alert.informativeText = status
            alert.runModal()
            return
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        alert.informativeText = """
        生成于 \(formatter.string(from: content.generatedAt))
        \(content.searched ? "联网摘要；搜索结果不保证为今日事件，投资信息请核对原文。" : "非联网生成，不代表实时资讯。")
        \(content.lines(at: Date()) == nil ? "内容已过期，不再显示在举牌上。" : "")
        \(lastError.map { "最近更新失败：\($0)" } ?? "")
        """
        let text = NSMutableAttributedString(
            string: "\(content.line)\n\n\(content.detail)\n",
            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        )
        for (index, source) in content.sources.enumerated() {
            text.append(NSAttributedString(
                string: "\n[\(index + 1)] \(source.title)\n\(source.url.absoluteString)\n",
                attributes: [.link: source.url, .font: NSFont.systemFont(ofSize: 12)]
            ))
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 260))
        scroll.hasVerticalScroller = true
        let view = NSTextView(frame: scroll.bounds)
        view.isEditable = false
        view.isSelectable = true
        view.textContainer?.widthTracksTextView = true
        view.autoresizingMask = [.width]
        view.textStorage?.setAttributedString(text)
        scroll.documentView = view
        alert.accessoryView = scroll
        alert.runModal()
    }
}
