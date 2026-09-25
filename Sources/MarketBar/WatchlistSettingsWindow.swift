import AppKit

/// 「自选与持仓」配置窗口。
///
/// 必须能成为 key window 才能打字 —— 本 app 其它窗口都是 `.nonactivatingPanel`
/// 且 `canBecomeKey = false`，这一条是区别所在（和 `ClaudeChatPanel` 同理）。
@MainActor
final class WatchlistSettingsWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - 内容视图

/// 一张三列表格（名称 / 代码 / 股数）+ 增删排序按钮。
///
/// 保存前的所有改动都只落在 `draft` 里，点「保存」才回写配置文件 ——
/// 所以「取消」天然是安全的。
@MainActor
final class WatchlistSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    /// 校验通过、用户点了保存
    var onSave: ((WatchlistConfig) -> Void)?
    var onCancel: (() -> Void)?

    private var draft: WatchlistDraft

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let addButton = NSButton(title: "添加", target: nil, action: nil)
    private let removeButton = NSButton(title: "删除", target: nil, action: nil)
    private let upButton = NSButton(title: "上移", target: nil, action: nil)
    private let downButton = NSButton(title: "下移", target: nil, action: nil)
    private let restoreButton = NSButton(title: "恢复默认值", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)

    private static let columnTitles = ["名称", "代码", "股数"]
    private static let columnIDs = ["name", "code", "shares"]
    private static let columnWidths: [CGFloat] = [186, 112, 122]
    private static let hint = "代码填 sh/sz + 6 位数字；只填 6 位数字会自动补前缀。股数留空 = 不持仓。"

    init(draft: WatchlistDraft) {
        self.draft = draft
        super.init(frame: NSRect(x: 0, y: 0, width: 580, height: 470))
        buildLayout()
        refreshButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 用配置文件里的最新内容重铺表格（每次打开窗口时调用）
    func reload(config: WatchlistConfig) {
        draft = WatchlistDraft(config: config)
        messageLabel.stringValue = ""
        tableView.reloadData()
        refreshButtons()
    }

    // MARK: - 布局

    private func buildLayout() {
        translatesAutoresizingMaskIntoConstraints = false

        let hintLabel = NSTextField(labelWithString: Self.hint)
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor

        for (index, identifier) in Self.columnIDs.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = Self.columnTitles[index]
            column.width = Self.columnWidths[index]
            column.minWidth = 60
            tableView.addTableColumn(column)
        }
        // 拉伸名称列（第一列），代码和股数保持定宽 —— 窄窗口下也不会把数值列挤没
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 24
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.usesAutomaticRowHeights = false
        tableView.style = .inset

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byTruncatingTail

        for (button, action) in [
            (addButton, #selector(addRow)),
            (removeButton, #selector(removeRows)),
            (upButton, #selector(moveRowUp)),
            (downButton, #selector(moveRowDown)),
            (restoreButton, #selector(restoreDefaults)),
            (cancelButton, #selector(cancel)),
            (saveButton, #selector(save)),
        ] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            button.controlSize = .regular
        }
        // 刻意不给「保存 / 取消」设 ⌘Return、Esc 快捷键：表格里正在编辑时按回车是想换行/换格，
        // 而 Esc 是想撤销这一格 —— 都撞上「保存并关窗」「丢弃全部改动」就太伤了。点按钮最稳。

        let editButtons = NSStackView(views: [addButton, removeButton, upButton, downButton])
        editButtons.orientation = .horizontal
        editButtons.spacing = 8

        // 撑开用的空视图：压低抗拉伸/抗压缩，让多余空间都落在它身上，按钮被推到右边
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let bottomBar = NSStackView(views: [editButtons, restoreButton, spacer, cancelButton, saveButton])
        bottomBar.orientation = .horizontal
        bottomBar.spacing = 8

        let root = NSStackView(views: [hintLabel, scrollView, messageLabel, bottomBar])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false

        addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),

            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
    }

    private func refreshButtons() {
        let selected = tableView.selectedRowIndexes
        removeButton.isEnabled = !selected.isEmpty
        upButton.isEnabled = selected.count == 1 && selected.first! > 0
        downButton.isEnabled = selected.count == 1 && selected.first! < draft.rows.count - 1
    }

    private func showMessage(_ text: String, isError: Bool) {
        messageLabel.stringValue = text
        messageLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    // MARK: - 表格数据源

    func numberOfRows(in tableView: NSTableView) -> Int {
        draft.rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier.rawValue, draft.rows.indices.contains(row) else {
            return nil
        }

        let item = draft.rows[row]
        let field = NSTextField(string: text(for: identifier, row: item))
        field.identifier = NSUserInterfaceItemIdentifier(identifier)
        field.isEditable = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byTruncatingTail
        field.delegate = self
        field.placeholderString = identifier == "code" ? "sh600036" : (identifier == "shares" ? "留空 = 不持仓" : "")
        // 股数是数字，右对齐读起来更快；名称和代码左对齐
        field.alignment = identifier == "shares" ? .right : .left
        return field
    }

    private func text(for identifier: String, row: WatchlistRow) -> String {
        switch identifier {
        case "name": return row.name
        case "code": return row.code
        case "shares": return WatchlistDraft.sharesText(row.shares)
        default: return ""
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshButtons()
    }

    /// 编辑结束（Tab / 回车 / 点别处）就把值收回草稿。
    ///
    /// 这里刻意**不** `reloadData()`：重建 cell 会打断 Tab 的焦点链，
    /// 所以只把当前 field 的内容改成规范化后的样子。
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let row = tableView.row(for: field)
        let identifier = field.identifier?.rawValue ?? ""
        guard draft.rows.indices.contains(row) else { return }

        switch identifier {
        case "name":
            draft.rows[row].name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            field.stringValue = draft.rows[row].name
        case "code":
            draft.rows[row].code = field.stringValue
            draft.normalizeCode(at: row)
            field.stringValue = draft.rows[row].code
        case "shares":
            draft.rows[row].shares = WatchlistDraft.parseShares(field.stringValue)
            field.stringValue = WatchlistDraft.sharesText(draft.rows[row].shares)
        default:
            return
        }

        messageLabel.stringValue = ""
        refreshButtons()
    }

    // MARK: - 按钮

    @objc private func addRow() {
        draft.appendRow()
        tableView.reloadData()
        let row = draft.rows.count - 1
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        // 直接落到名称格开始打字，省一次点击
        tableView.editColumn(0, row: row, with: nil, select: true)
        refreshButtons()
    }

    @objc private func removeRows() {
        let selected = tableView.selectedRowIndexes
        guard !selected.isEmpty else { return }
        draft.remove(at: selected)
        tableView.reloadData()
        refreshButtons()
        showMessage("已删除 \(selected.count) 行，点「保存」才生效", isError: false)
    }

    @objc private func moveRowUp() {
        move(by: -1)
    }

    @objc private func moveRowDown() {
        move(by: 1)
    }

    private func move(by offset: Int) {
        let selected = tableView.selectedRow
        guard selected >= 0 else { return }
        let target = selected + offset
        guard draft.rows.indices.contains(target) else { return }

        draft.move(from: selected, to: target)
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        refreshButtons()
    }

    @objc private func restoreDefaults() {
        draft = WatchlistDraft(config: .default)
        tableView.reloadData()
        refreshButtons()
        showMessage("已恢复内置默认清单，点「保存」才生效", isError: false)
    }

    @objc private func cancel() {
        onCancel?()
    }

    @objc private func save() {
        let issues = draft.issues()
        guard let first = issues.first else {
            onSave?(draft.config())
            return
        }

        // 有错就不保存，把光标落到出问题的那一行
        let suffix = issues.count > 1 ? "（共 \(issues.count) 处问题）" : ""
        showMessage(first.message + suffix, isError: true)
        let row = first.row
        if draft.rows.indices.contains(row) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
    }
}

// MARK: - 控制器

/// 持有配置窗口（懒创建），把「保存」的结果转给 AppDelegate。
@MainActor
final class WatchlistSettingsController {
    /// 参数是校验通过的新配置
    var onSave: ((WatchlistConfig) -> Void)?

    private var window: WatchlistSettingsWindow?
    private var view: WatchlistSettingsView?

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        let view: WatchlistSettingsView
        if let existing = self.view {
            view = existing
        } else {
            view = makeView()
        }

        let window: WatchlistSettingsWindow
        if let existing = self.window {
            window = existing
        } else {
            window = makeWindow(contentView: view)
        }

        // 每次打开都按磁盘上的最新内容重铺；窗口已经开着就别动，免得把正在编的内容冲掉
        if !window.isVisible {
            view.reload(config: WatchlistConfig.load())
            window.center()
        }

        // 顺序和聊天窗一致：先定第一响应者，orderFront 之后再设一次
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
    }

    private func makeView() -> WatchlistSettingsView {
        let view = WatchlistSettingsView(draft: WatchlistDraft(config: WatchlistConfig.load()))
        view.onSave = { [weak self] config in
            self?.onSave?(config)
            self?.close()
        }
        view.onCancel = { [weak self] in self?.close() }
        self.view = view
        return view
    }

    private func makeWindow(contentView: NSView) -> WatchlistSettingsWindow {
        let window = WatchlistSettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 470),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "自选与持仓"
        window.contentView = contentView
        window.minSize = NSSize(width: 480, height: 320)
        // 关掉只是 orderOut，下次还能用同一个窗口（默认 true 会在关闭时释放，再开就崩）
        window.isReleasedWhenClosed = false
        self.window = window
        return window
    }
}
