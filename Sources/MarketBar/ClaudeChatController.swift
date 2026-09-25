import AppKit

/// 聊天窗 + 会话状态 + 在途请求的粘合层。
@MainActor
final class ClaudeChatController {
    private enum Key {
        static let sessionID = "claudeChatSessionID"
        static let executablePath = "claudeChatExecutablePath"
        static let workingDirectory = "claudeChatWorkingDirectory"
    }

    private let defaults: UserDefaults
    private var panel: ClaudeChatPanel?
    private var chatView: ClaudeChatView?
    private var sessionState: ClaudeChatSessionState
    private var resolvedExecutable: URL?
    private var workingDirectory: URL
    private var currentTask: Task<Void, Never>?
    private var statusTimer: Timer?
    private var streamDisplayTimer: Timer?
    private var sendStartedAt: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.sessionState = ClaudeChatSessionState(
            sessionID: defaults.string(forKey: Key.sessionID).flatMap(UUID.init(uuidString:))
        )
        self.resolvedExecutable = defaults.string(forKey: Key.executablePath)
            .map { URL(fileURLWithPath: $0) }
        self.workingDirectory = defaults.string(forKey: Key.workingDirectory)
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory())

        // 全新安装 / 换过工作目录时没有存过会话 id：接管该目录下最近用过的那个会话，
        // 这样能接上之前在终端或旧版本里聊的内容，而不是从空会话开始
        if self.sessionState.sessionID == nil, let adopted = ClaudeChatHistory.mostRecentSessionID(in: self.workingDirectory) {
            self.sessionState = ClaudeChatSessionState(sessionID: adopted)
            defaults.set(adopted.uuidString, forKey: Key.sessionID)
        }
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var sessionID: UUID? { sessionState.sessionID }
    var chatWorkingDirectory: URL { workingDirectory }

    // MARK: - 显示 / 关闭

    func toggle(anchor: NSRect) {
        if isVisible {
            close()
        } else {
            show(anchor: anchor)
        }
    }

    func show(anchor: NSRect) {
        let view = chatView ?? makeChatView()
        let panel = panel ?? makePanel(contentView: view)

        let restored = !panel.frameAutosaveName.isEmpty && panel.setFrameUsingName(panel.frameAutosaveName)
        if !restored || !isFrameOnAnyScreen(panel.frame) || !isFrameOnAnchorScreen(panel.frame, anchor: anchor) {
            // 位置记忆只在「和宠物同一块屏」时沿用；宠物换了屏幕就重新贴过去
            position(panel, anchor: anchor)
        }

        // 顺序有讲究：先定第一响应者，orderFront 之后再设一次（AppKit 可能重置）
        panel.makeFirstResponder(view.inputResponder)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view.inputResponder)

        if view.isTranscriptEmpty {
            loadHistory(into: view)
        }
    }

    func showDraft(_ text: String, anchor: NSRect) {
        show(anchor: anchor)
        guard currentTask == nil else {
            chatView?.setStatus("请等待当前回复结束，再插入行情草稿")
            return
        }
        chatView?.insertDraft(text)
        chatView?.setStatus("草稿未发送；确认内容后按 Enter")
    }

    /// 首次打开时把历史对话铺进来（app 自己存的记录，见 ChatTranscriptStore）
    private func loadHistory(into view: ClaudeChatView) {
        guard let sessionID = sessionState.sessionID else {
            view.append(ChatMessage(role: .system, text: "右键随时叫我。消息会记在同一个会话里。"))
            return
        }

        // 首选 CLI 的会话文件（与 claude --resume 同源，覆盖整个会话，含终端里聊的）；
        // 读不到再退回 app 自己存的那份
        let file = ClaudeChatHistory.sessionFile(sessionID: sessionID, workingDirectory: workingDirectory)
        var history = ClaudeChatHistory.messages(from: file)
        if history.isEmpty {
            history = ChatTranscriptStore.load(sessionID: sessionID)
        }

        guard !history.isEmpty else {
            view.append(ChatMessage(role: .system, text: "右键随时叫我。消息会记在同一个会话里。"))
            return
        }

        view.append(ChatMessage(
            role: .system,
            text: "以下是这个会话的历史消息（最近 \(history.count) 条），往上翻可以看更早的"
        ))
        for message in history {
            view.append(message)
        }
        view.setStatus("已载入历史 \(history.count) 条")
    }

    func close() {
        cancelInFlight()
        panel?.orderOut(nil)
    }

    /// app 退出时调用：不取消的话，claude 子进程会被 launchd 收养继续烧钱
    func shutdown() {
        cancelInFlight()
        panel?.orderOut(nil)
    }

    // MARK: - 面板构建

    private func makeChatView() -> ClaudeChatView {
        let view = ClaudeChatView(frame: NSRect(origin: .zero, size: ClaudeChatPanelLayout.defaultSize))
        view.onSend = { [weak self] text in self?.send(text) }
        view.onCancel = { [weak self] in self?.cancelInFlight() }
        view.onNewSession = { [weak self] in self?.startNewSession() }
        view.onEditSession = { [weak self] in self?.promptForSession() }
        view.onPickExecutable = { [weak self] in self?.promptForExecutable() }
        view.setStatus("复用同一个会话")
        chatView = view
        return view
    }

    private func makePanel(contentView: ClaudeChatView) -> ClaudeChatPanel {
        let panel = ClaudeChatPanel(
            contentRect: NSRect(origin: .zero, size: ClaudeChatPanelLayout.defaultSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = ClaudeChatPalette.background
        panel.minSize = ClaudeChatPanelLayout.minimumSize
        // 高于宠物（.floating）和气泡（.floating + 1）
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // 这三个默认值不对的话会静默失效：打字没反应 / 切个 app 窗口就消失 / 关一次就崩
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.onEscape = { [weak self] in self?.handleEscape() }
        panel.contentView = contentView
        panel.setFrameAutosaveName("ClaudeChatPanel")
        self.panel = panel
        return panel
    }

    private func position(_ panel: ClaudeChatPanel, anchor: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }

        let size = panel.frame.size == .zero ? ClaudeChatPanelLayout.defaultSize : panel.frame.size
        let origin = ClaudeChatPanelLayout.origin(anchor: anchor, panelSize: size, visibleFrame: visibleFrame)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    private func isFrameOnAnyScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }

    private func isFrameOnAnchorScreen(_ frame: NSRect, anchor: NSRect) -> Bool {
        guard let anchorScreen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) else {
            return true
        }
        return anchorScreen.visibleFrame.intersects(frame)
    }

    // MARK: - 交互

    private func handleEscape() {
        if currentTask != nil {
            cancelInFlight()
        } else {
            close()
        }
    }

    private func startNewSession() {
        cancelInFlight()
        if let previous = sessionState.sessionID {
            ChatTranscriptStore.remove(sessionID: previous)
        }
        sessionState.reset()
        saveSession()
        chatView?.clearTranscript()
        chatView?.append(ChatMessage(role: .system, text: "—— 新会话 ——"))
        chatView?.setStatus("已开新会话")
        chatView?.focusInput()
    }

    /// 查看/修改复用的会话 id：粘一个已有 id 进来就能接管那个会话（比如终端里聊过的）
    private func promptForSession() {
        let alert = NSAlert()
        alert.messageText = "复用的会话"
        alert.informativeText = "粘贴一个会话 id 可接管该会话；留空表示下次从新会话开始。"
        alert.addButton(withTitle: "使用")
        alert.addButton(withTitle: "取消")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.placeholderString = "例如 D09437B2-A9EC-4800-BFA8-B05AABABB4D9"
        input.stringValue = sessionState.sessionID?.uuidString ?? ""
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let raw = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            sessionState.reset()
            saveSession()
            chatView?.clearTranscript()
            chatView?.append(ChatMessage(role: .system, text: "已清空会话，下次发送会开新会话"))
        } else if let id = UUID(uuidString: raw) {
            sessionState = ClaudeChatSessionState(sessionID: id)
            saveSession()
            chatView?.clearTranscript()
            loadHistory(into: chatView ?? ClaudeChatView())
        } else {
            chatView?.append(ChatMessage(role: .error, text: "会话 id 格式不对：\(raw)"))
        }
    }

    // MARK: - 发送

    private func send(_ text: String, isRetry: Bool = false) {
        guard currentTask == nil || isRetry else { return }

        if !isRetry {
            appendMessage(ChatMessage(role: .user, text: text))
        }
        beginSendingStatus()

        currentTask = Task { [weak self] in
            guard let self else { return }
            await self.performSend(text, isRetry: isRetry)
            self.finishSendingStatus()
            self.currentTask = nil
        }
    }

    private func performSend(_ text: String, isRetry: Bool) async {
        guard let executable = await resolveExecutable() else {
            chatView?.setExecutableMissing(true)
            appendMessage(ChatMessage(role: .error, text: ClaudeChatError.executableNotFound.message))
            return
        }
        chatView?.setExecutableMissing(false)

        let (sessionID, isResume) = sessionState.begin()
        saveSession()

        let spec = ClaudeChatInvocation.spec(
            prompt: text,
            sessionID: sessionID,
            isResume: isResume,
            claudePath: executable,
            workingDirectory: workingDirectory
        )

        let stream = LockedStreamState()
        let streamStart = Date()
        chatView?.beginStream()
        beginStreamDisplay(stream: stream, startedAt: streamStart)

        do {
            let output = try await ClaudeProcessRunner.run(
                spec,
                timeout: ClaudeChatTiming.responseTimeout,
                onLine: { line in stream.consume(line) }
            )
            endStreamDisplay()

            if output.status != 0 {
                // 存的会话在服务端不存在 → 清掉并**只重试一次**
                if isResume, !isRetry, ClaudeChatParser.indicatesBrokenSession(output) {
                    sessionState.sessionBroke()
                    saveSession()
                    appendMessage(ChatMessage(role: .system, text: ClaudeChatError.sessionNotFound.message))
                    await performSend(text, isRetry: true)
                    return
                }
                throw ClaudeChatError.commandFailed(status: output.status, stderrTail: output.stderrTail)
            }

            // stream-json 的输出是 NDJSON，最终结果取自流里那个 result 事件
            let snapshot = stream.snapshot()
            guard let result = snapshot.result else {
                throw ClaudeChatError.invalidResponse(
                    String(decoding: output.stdout.suffix(200), as: UTF8.self)
                )
            }
            if result.isError == true {
                finalizeStream(stream, fallbackText: nil, isError: true)
                appendMessage(ChatMessage(role: .error, text: result.text ?? "未知错误"))
                chatView?.setStatus("出错")
                return
            }

            let replyText = snapshot.text.isEmpty ? (result.text ?? "") : snapshot.text
            sessionState.succeeded(returnedID: result.sessionID)
            saveSession()

            let tokens = result.usage?.totalTokens
            chatView?.renderStream(
                thinking: snapshot.thinking,
                text: replyText,
                tokens: tokens,
                date: streamStart,
                isFinal: true
            )
            persist(ChatMessage(role: .assistant, text: replyText, tokens: tokens))
            chatView?.setStatus(ChatTokenFormat.text(tokens) ?? "复用同一个会话")
        } catch let error as ClaudeChatError {
            // 已经流出来的内容保留，后面再接错误说明
            finalizeStream(stream, fallbackText: nil, isError: true)
            appendMessage(ChatMessage(role: .error, text: error.message))
            chatView?.setStatus(error == .cancelled ? "已停止" : "出错")
        } catch {
            finalizeStream(stream, fallbackText: nil, isError: true)
            appendMessage(ChatMessage(role: .error, text: error.localizedDescription))
            chatView?.setStatus("出错")
        }
    }

    /// 出错/取消时把已经流出来的内容定稿（不丢），没有内容就把流出块清掉
    private func finalizeStream(_ stream: LockedStreamState, fallbackText: String?, isError: Bool) {
        let snapshot = stream.snapshot()
        let text = snapshot.text.isEmpty ? (fallbackText ?? "") : snapshot.text
        guard !snapshot.thinking.isEmpty || !text.isEmpty else {
            chatView?.renderStream(thinking: "", text: "", tokens: nil, date: Date(), isFinal: true)
            return
        }
        chatView?.renderStream(
            thinking: snapshot.thinking,
            text: text,
            tokens: snapshot.result?.usage?.totalTokens,
            date: Date(),
            isFinal: true
        )
    }

    private func cancelInFlight() {
        currentTask?.cancel()
        currentTask = nil
        finishSendingStatus()
    }

    /// 显示 + 落盘（历史就靠这份记录，见 ChatTranscriptStore）
    private func appendMessage(_ message: ChatMessage) {
        chatView?.append(message)
        persist(message)
    }

    /// 只落盘：内容已经在界面上（流式渲染的回复走这条，避免重复渲染）
    private func persist(_ message: ChatMessage) {
        guard let sessionID = sessionState.sessionID else { return }
        ChatTranscriptStore.append(message, sessionID: sessionID)
    }

    // MARK: - 状态显示

    private func beginSendingStatus() {
        chatView?.setSending(true)
        sendStartedAt = Date()
        chatView?.setStatus("思考中…")
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let started = self.sendStartedAt else { return }
                let elapsed = Int(Date().timeIntervalSince(started))
                guard Double(elapsed) >= ClaudeChatTiming.progressHintDelay else { return }
                self.chatView?.setStatus("思考中… \(elapsed)s")
            }
        }
        RunLoop.main.add(statusTimer!, forMode: .common)
    }

    private func finishSendingStatus() {
        statusTimer?.invalidate()
        statusTimer = nil
        sendStartedAt = nil
        endStreamDisplay()
        chatView?.setSending(false)
    }

    /// 流式显示：每 0.12 秒从共享状态里拉一次快照刷到界面上。
    /// 逐行往主线程跳会有乱序风险（增量一乱序就成了乱码），所以用拉取而不是推送。
    private func beginStreamDisplay(stream: LockedStreamState, startedAt: Date) {
        endStreamDisplay()
        streamDisplayTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let snapshot = stream.snapshot()
                self.chatView?.renderStream(
                    thinking: snapshot.thinking,
                    text: snapshot.text,
                    tokens: snapshot.result?.usage?.totalTokens,
                    date: startedAt,
                    isFinal: false
                )
            }
        }
        RunLoop.main.add(streamDisplayTimer!, forMode: .common)
    }

    private func endStreamDisplay() {
        streamDisplayTimer?.invalidate()
        streamDisplayTimer = nil
    }

    // MARK: - claude 路径

    private func resolveExecutable() async -> URL? {
        if let resolvedExecutable, FileManager.default.isExecutableFile(atPath: resolvedExecutable.path) {
            return resolvedExecutable
        }

        if let output = try? await ClaudeProcessRunner.run(
            ClaudeChatInvocation.pathProbeSpec(),
            timeout: ClaudeChatTiming.resolveTimeout
        ), let url = ClaudeExecutableResolver.parse(String(decoding: output.stdout, as: UTF8.self)) {
            rememberExecutable(url)
            return url
        }

        for candidate in ClaudeExecutableResolver.fallbackPaths {
            let path = (candidate as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: path) {
                let url = URL(fileURLWithPath: path)
                rememberExecutable(url)
                return url
            }
        }

        return nil
    }

    private func rememberExecutable(_ url: URL) {
        resolvedExecutable = url
        defaults.set(url.path, forKey: Key.executablePath)
    }

    private func promptForExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "选择 claude 可执行文件"
        panel.prompt = "选择"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        rememberExecutable(url)
        chatView?.setExecutableMissing(false)
        chatView?.append(ChatMessage(role: .system, text: "已记录 claude 路径：\(url.path)"))
    }

    // MARK: - 持久化

    private func saveSession() {
        if let id = sessionState.sessionID {
            defaults.set(id.uuidString, forKey: Key.sessionID)
        } else {
            defaults.removeObject(forKey: Key.sessionID)
        }
    }

    func setWorkingDirectory(_ url: URL) {
        workingDirectory = url
        defaults.set(url.path, forKey: Key.workingDirectory)
        chatView?.append(ChatMessage(role: .system, text: "工作目录已改为：\(url.path)"))
    }
}
