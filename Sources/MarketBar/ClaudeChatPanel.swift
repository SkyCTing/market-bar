import AppKit

// MARK: - 配色

@MainActor
enum ClaudeChatPalette {
    static let background = NSColor(white: 0.14, alpha: 0.98)
    static let border = NSColor(white: 0.3, alpha: 0.5)
    static let divider = NSColor(white: 0.3, alpha: 0.5)
    static let title = HoverPalette.sectionTitle
    static let label = HoverPalette.labelText
    static let value = HoverPalette.valueText
    static let user = NSColor.white
    /// 错误用琥珀色：本 app 里红=涨、绿=跌，不能拿它们表示错误
    static let error = NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.25, alpha: 1)
    static let placeholder = NSColor(white: 0.35, alpha: 1)
    /// 思考过程：比正文更暗，作为次要信息
    static let thinking = NSColor(white: 0.58, alpha: 1)
}

// MARK: - 纯几何 / 纯测量

/// 面板定位与输入框高度。纯函数，便于单测（沿用 FloatingCharacterSignLayout 的写法）。
enum ClaudeChatPanelLayout {
    static let defaultSize = NSSize(width: 420, height: 520)
    static let minimumSize = NSSize(width: 360, height: 320)
    static let gap: CGFloat = 12

    /// 默认贴在宠物左侧；左边放不下就换右侧；最后统一夹到可见区域内。
    static func origin(anchor: NSRect, panelSize: NSSize, visibleFrame: NSRect) -> NSPoint {
        var x = anchor.minX - panelSize.width - gap
        if x < visibleFrame.minX {
            x = anchor.maxX + gap
        }
        x = min(max(x, visibleFrame.minX), visibleFrame.maxX - panelSize.width)

        let centeredY = anchor.midY - panelSize.height / 2
        let y = min(max(centeredY, visibleFrame.minY), visibleFrame.maxY - panelSize.height)
        return NSPoint(x: x, y: y)
    }

    static let inputMinimumHeight: CGFloat = 34
    static let inputMaximumHeight: CGFloat = 110

    /// 按内容算输入框高度（测量而非估算），再夹到上下限之间
    static func inputHeight(
        for text: String,
        width: CGFloat,
        font: NSFont,
        fallbackLineHeight: CGFloat = 17
    ) -> CGFloat {
        guard !text.isEmpty, width > 0 else {
            return inputMinimumHeight
        }
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).height
        let withPadding = max(measured + 10, fallbackLineHeight + 10)
        return min(max(withPadding, inputMinimumHeight), inputMaximumHeight)
    }
}

// MARK: - 面板

/// 聊天面板。必须能成为 key window 才能打字 —— 本 app 其它窗口都是
/// `.nonactivatingPanel` 且 `canBecomeKey = false`，这一条是区别所在。
@MainActor
final class ClaudeChatPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

// MARK: - 文本视图

/// 转写区：只读、可选中、可跨消息复制
final class ChatTranscriptTextView: NSTextView {
    override var acceptsFirstResponder: Bool { true }
}

/// 输入框：Enter 发送、Shift+Enter 换行
final class ChatInputTextView: NSTextView {
    var onSend: (() -> Void)?

    /// 用 insertNewline 而不是 keyDown：中文输入法确认候选词时的回车会被输入法自己处理掉，
    /// 只有真正落到编辑命令上的回车才该触发发送。
    override func insertNewline(_ sender: Any?) {
        if NSEvent.modifierFlags.contains(.shift) {
            super.insertNewline(sender)
        } else {
            onSend?()
        }
    }
}

// MARK: - 内容视图

@MainActor
final class ClaudeChatView: NSView {
    var onSend: ((String) -> Void)?
    var onNewSession: (() -> Void)?
    var onEditSession: (() -> Void)?
    var onCancel: (() -> Void)?
    var onPickExecutable: (() -> Void)?

    private let transcript = ChatTranscriptTextView(frame: .zero)
    private let transcriptScroll = NSScrollView()
    private let input = ChatInputTextView(frame: .zero)
    private let inputScroll = NSScrollView()
    /// NSTextView 没有占位符，自己叠一个
    private let inputPlaceholder = NSTextField(labelWithString: "说点什么…（Enter 发送，Shift+Enter 换行）")
    private let statusLabel = NSTextField(labelWithString: "")
    private let sendButton = NSButton(title: "发送", target: nil, action: nil)
    private let newSessionButton = NSButton(title: "新会话", target: nil, action: nil)
    private let sessionButton = NSButton(title: "会话…", target: nil, action: nil)
    private let pickExecutableButton = NSButton(title: "选择 claude 路径…", target: nil, action: nil)
    private var inputHeightConstraint: NSLayoutConstraint?
    private var isSending = false
    /// 当前流式块的起始位置（块永远在转写区末尾）
    private var streamStart: Int?

    private static let bodyFont = NSFont.systemFont(ofSize: 13)
    private static let headerHeight: CGFloat = 38

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = ClaudeChatPalette.background.cgColor
        layer?.cornerRadius = 12
        layer?.borderColor = ClaudeChatPalette.border.cgColor
        layer?.borderWidth = 0.5
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: 对外接口

    func append(_ message: ChatMessage) {
        let stickToBottom = isScrolledToBottom()
        transcript.textStorage?.append(Self.attributed(for: message))
        if stickToBottom {
            scrollTranscriptToBottom()
        }
    }

    func clearTranscript() {
        transcript.textStorage?.setAttributedString(NSAttributedString(string: ""))
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    func setSending(_ sending: Bool) {
        isSending = sending
        sendButton.title = sending ? "停止" : "发送"
        input.isEditable = !sending
    }

    func setExecutableMissing(_ missing: Bool) {
        pickExecutableButton.isHidden = !missing
    }

    func focusInput() {
        window?.makeFirstResponder(input)
    }

    var inputText: String { input.string }
    /// 面板打开时要把第一响应者交给它
    var inputResponder: NSView { input }
    var isTranscriptEmpty: Bool { transcript.string.isEmpty }

    func insertDraft(_ text: String) {
        input.string += (input.string.isEmpty ? "" : "\n\n") + text
        inputDidChange()
        focusInput()
    }

    // MARK: 流式渲染（思考 + 正文边生成边显示）

    /// 开始一次流式：记住尾部起点，之后的增量都替换这一段
    func beginStream() {
        streamStart = (transcript.string as NSString).length
    }

    func renderStream(thinking: String, text: String, tokens: Int?, date: Date, isFinal: Bool) {
        guard let start = streamStart, let storage = transcript.textStorage else { return }
        let rendered = Self.attributedStream(thinking: thinking, text: text, tokens: tokens, date: date)
        let stickToBottom = isScrolledToBottom()

        storage.replaceCharacters(
            in: NSRange(location: start, length: storage.length - start),
            with: rendered
        )
        if isFinal { streamStart = nil }
        if stickToBottom { scrollTranscriptToBottom() }
    }

    func clearInput() {
        input.string = ""
        inputDidChange()
    }

    // MARK: 布局

    private func buildLayout() {
        let header = NSView()
        let headerDivider = Self.makeDivider()
        let inputDivider = Self.makeDivider()

        // ── 头部（左侧给红绿灯留位）
        let titleLabel = NSTextField(labelWithString: "小丁助手")
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = ClaudeChatPalette.title

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = ClaudeChatPalette.label
        statusLabel.lineBreakMode = .byTruncatingTail

        for button in [newSessionButton, pickExecutableButton, sessionButton] {
            button.isBordered = false
            button.font = .systemFont(ofSize: 11)
            button.contentTintColor = ClaudeChatPalette.label
            button.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(button)
        }
        newSessionButton.target = self
        newSessionButton.action = #selector(handleNewSession)
        sessionButton.target = self
        sessionButton.action = #selector(handleEditSession)
        pickExecutableButton.target = self
        pickExecutableButton.action = #selector(handlePickExecutable)
        pickExecutableButton.isHidden = true

        // ── 转写区
        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.isRichText = true
        transcript.drawsBackground = false
        transcript.backgroundColor = .clear
        transcript.textContainerInset = NSSize(width: 0, height: 8)
        transcript.isVerticallyResizable = true
        transcript.isHorizontallyResizable = false
        // documentView 用 autoresizing 而不是 Auto Layout：给 documentView 加约束会让宽度算成 0
        transcript.autoresizingMask = [.width]
        transcript.minSize = .zero
        transcript.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        transcript.textContainer?.widthTracksTextView = true
        transcript.textContainer?.containerSize = NSSize(
            width: transcriptScroll.contentSize.width,
            height: .greatestFiniteMagnitude
        )

        transcriptScroll.documentView = transcript
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.drawsBackground = false
        transcriptScroll.contentView.drawsBackground = false

        // ── 输入区
        input.font = Self.bodyFont
        input.textColor = ClaudeChatPalette.value
        input.insertionPointColor = ClaudeChatPalette.value
        input.isRichText = false
        input.importsGraphics = false
        input.drawsBackground = false
        input.backgroundColor = .clear
        input.textContainerInset = NSSize(width: 0, height: 6)
        input.isVerticallyResizable = true
        input.isHorizontallyResizable = false
        input.autoresizingMask = [.width]
        input.textContainer?.widthTracksTextView = true
        // 智能引号会把发给 CLI 的 " 改坏，其余自动替换同理
        input.isAutomaticQuoteSubstitutionEnabled = false
        input.isAutomaticDashSubstitutionEnabled = false
        input.isAutomaticTextReplacementEnabled = false
        input.isAutomaticSpellingCorrectionEnabled = false
        input.isContinuousSpellCheckingEnabled = false
        input.isGrammarCheckingEnabled = false
        input.smartInsertDeleteEnabled = false
        input.allowsUndo = true
        input.onSend = { [weak self] in self?.handleSend() }
        input.delegate = self

        inputPlaceholder.font = Self.bodyFont
        inputPlaceholder.textColor = ClaudeChatPalette.placeholder
        inputPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inputPlaceholder)

        inputScroll.documentView = input
        inputScroll.hasVerticalScroller = true
        inputScroll.autohidesScrollers = true
        inputScroll.drawsBackground = false
        inputScroll.contentView.drawsBackground = false

        sendButton.isBordered = false
        sendButton.font = .systemFont(ofSize: 12, weight: .medium)
        sendButton.contentTintColor = ClaudeChatPalette.title
        sendButton.target = self
        sendButton.action = #selector(handleSendOrCancel)

        for view in [header, headerDivider, transcriptScroll, inputDivider, inputScroll, sendButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        header.addSubview(titleLabel)
        header.addSubview(statusLabel)
        for view in [titleLabel, statusLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }

        let inputHeight = ClaudeChatPanelLayout.inputHeight(
            for: "",
            width: ClaudeChatPanelLayout.defaultSize.width - 32 - 60,
            font: Self.bodyFont
        )
        let heightConstraint = inputScroll.heightAnchor.constraint(equalToConstant: inputHeight)
        inputHeightConstraint = heightConstraint

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 78),  // 避开红绿灯
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: sessionButton.leadingAnchor, constant: -8),

            pickExecutableButton.trailingAnchor.constraint(equalTo: newSessionButton.leadingAnchor, constant: -12),
            pickExecutableButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            newSessionButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            newSessionButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            sessionButton.trailingAnchor.constraint(equalTo: newSessionButton.leadingAnchor, constant: -12),
            sessionButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            headerDivider.topAnchor.constraint(equalTo: header.bottomAnchor),
            headerDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerDivider.heightAnchor.constraint(equalToConstant: 0.5),

            transcriptScroll.topAnchor.constraint(equalTo: headerDivider.bottomAnchor),
            transcriptScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            transcriptScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            transcriptScroll.bottomAnchor.constraint(equalTo: inputDivider.topAnchor, constant: -10),

            inputDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            inputDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            inputDivider.heightAnchor.constraint(equalToConstant: 0.5),
            inputDivider.bottomAnchor.constraint(equalTo: inputScroll.topAnchor, constant: -10),

            inputScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            inputScroll.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -10),
            inputScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            heightConstraint,

            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            sendButton.centerYAnchor.constraint(equalTo: inputScroll.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 44),

            inputPlaceholder.leadingAnchor.constraint(equalTo: inputScroll.leadingAnchor),
            inputPlaceholder.topAnchor.constraint(equalTo: inputScroll.topAnchor, constant: 6),
            inputPlaceholder.trailingAnchor.constraint(lessThanOrEqualTo: inputScroll.trailingAnchor),
        ])
    }

    private static func makeDivider() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = ClaudeChatPalette.divider.cgColor
        return view
    }

    // MARK: 动作

    @objc private func handleSendOrCancel() {
        if isSending {
            onCancel?()
        } else {
            handleSend()
        }
    }

    @objc private func handleNewSession() {
        onNewSession?()
    }

    @objc private func handleEditSession() {
        onEditSession?()
    }

    @objc private func handlePickExecutable() {
        onPickExecutable?()
    }

    private func handleSend() {
        guard !isSending else { return }
        let text = input.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        clearInput()
        onSend?(text)
    }

    /// 输入内容变化：占位符显隐 + 输入框高度
    fileprivate func inputDidChange() {
        inputPlaceholder.isHidden = !input.string.isEmpty
        updateInputHeight()
        needsLayout = true
    }

    private func updateInputHeight() {
        let available = inputScroll.contentSize.width > 0
            ? inputScroll.contentSize.width
            : ClaudeChatPanelLayout.defaultSize.width - 32 - 60
        inputHeightConstraint?.constant = ClaudeChatPanelLayout.inputHeight(
            for: input.string,
            width: available,
            font: Self.bodyFont
        )
    }

    override func layout() {
        super.layout()

        // 长行情草稿比 110pt 的输入框高，documentView 得能长高才能向上滚动审阅。
        if inputScroll.contentSize.width > 0 {
            let textHeight = (input.string as NSString).boundingRect(
                with: NSSize(width: inputScroll.contentSize.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: Self.bodyFont]
            ).height + input.textContainerInset.height * 2
            input.frame = NSRect(
                origin: .zero,
                size: NSSize(
                    width: inputScroll.contentSize.width,
                    height: max(inputScroll.contentSize.height, ceil(textHeight))
                )
            )
            input.textContainer?.containerSize = NSSize(
                width: inputScroll.contentSize.width,
                height: .greatestFiniteMagnitude
            )
        }

        updateInputHeight()
        transcript.textContainer?.containerSize = NSSize(
            width: transcriptScroll.contentSize.width,
            height: .greatestFiniteMagnitude
        )
    }

    // MARK: 滚动

    private func isScrolledToBottom() -> Bool {
        let visible = transcriptScroll.contentView.bounds
        return visible.maxY >= transcript.frame.maxY - 4
    }

    private func scrollTranscriptToBottom() {
        // 晚一个 runloop 再滚：此时布局已完成，否则 scrollRangeToVisible 会静默无效
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let end = (self.transcript.string as NSString).length
            self.transcript.scrollRangeToVisible(NSRange(location: end, length: 0))
        }
    }

    // MARK: 消息渲染

    /// 流式块：上面是思考（暗、斜体），下面是正文。两边都可能还没内容。
    static func attributedStream(thinking: String, text: String, tokens: Int?, date: Date) -> NSAttributedString {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let stamp = formatter.string(from: date)

        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = 10
        paragraph.lineSpacing = 3
        let result = NSMutableAttributedString()

        if !thinking.isEmpty {
            result.append(NSAttributedString(string: "思考  \(stamp)\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: ClaudeChatPalette.label,
                .paragraphStyle: paragraph,
            ]))
            result.append(NSAttributedString(string: thinking + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: ClaudeChatPalette.thinking,
                .obliqueness: 0.12,
                .paragraphStyle: paragraph,
            ]))
        }

        if !text.isEmpty {
            let header = "小丁助手  \(stamp)" + (ChatTokenFormat.text(tokens).map { "  ·  \($0)" } ?? "")
            result.append(NSAttributedString(string: header + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: ClaudeChatPalette.title,
                .paragraphStyle: paragraph,
            ]))
            result.append(NSAttributedString(string: text + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: ClaudeChatPalette.value,
                .paragraphStyle: paragraph,
            ]))
        }

        return result
    }

    static func attributed(for message: ChatMessage) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = 10
        paragraph.lineSpacing = 3

        let roleTitle: String
        let bodyColor: NSColor
        switch message.role {
        case .user:
            roleTitle = "你"
            bodyColor = ClaudeChatPalette.user
        case .assistant:
            roleTitle = "小丁助手"
            bodyColor = ClaudeChatPalette.value
        case .system:
            roleTitle = "提示"
            bodyColor = ClaudeChatPalette.label
        case .error:
            roleTitle = "错误"
            bodyColor = ClaudeChatPalette.error
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let header = "\(roleTitle)  \(formatter.string(from: message.date))" +
            (ChatTokenFormat.text(message.tokens).map { "  ·  \($0)" } ?? "")

        let text = NSMutableAttributedString(string: header + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: message.role == .error ? ClaudeChatPalette.error : ClaudeChatPalette.title,
            .paragraphStyle: paragraph,
        ])
        // 正文末尾补一个换行：否则下一条消息的「角色 + 时间」会接在同一行后面
        text.append(NSAttributedString(string: message.text + "\n", attributes: [
            .font: message.role == .system
                ? NSFont.systemFont(ofSize: 12)
                : NSFont.systemFont(ofSize: 13),
            .foregroundColor: bodyColor,
            .paragraphStyle: paragraph,
            .obliqueness: message.role == .system ? 0.12 : 0,
        ]))
        return text
    }
}

extension ClaudeChatView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        inputDidChange()
    }
}
