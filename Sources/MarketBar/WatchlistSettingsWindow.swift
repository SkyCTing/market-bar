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
final class WatchlistSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    /// 校验通过、用户点了保存
    var onSave: ((WatchlistConfig) -> Void)?
    var onCancel: (() -> Void)?

    private var draft: WatchlistDraft

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let searchField = NSSearchField()
    private let resultsTable = NSTableView()
    private let resultsScroll = NSScrollView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let removeButton = NSButton(title: "删除", target: nil, action: nil)
    private let upButton = NSButton(title: "上移", target: nil, action: nil)
    private let downButton = NSButton(title: "下移", target: nil, action: nil)
    private let restoreButton = NSButton(title: "恢复默认值", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)

    /// 搜索候选项（只在内存里，点/回车才加入清单）
    private var searchResults: [StockSearchResult] = []
    private var searchTask: Task<Void, Never>?
    /// 结果列表里高亮的那条，-1 = 没选
    private var highlightedResult = -1
    private var resultsHeightConstraint: NSLayoutConstraint?
    /// 刚被 `refreshCell` 顶掉的那个 field：它随后的 endEditing 要丢掉
    private weak var suppressedField: NSTextField?

    private static let columnTitles = ["名称", "代码", "股数", "成本"]
    private static let columnIDs = ["name", "code", "shares", "cost"]
    private static let columnWidths: [CGFloat] = [150, 112, 112, 100]
    private static let resultColumnTitles = ["名称", "代码", "备注"]
    private static let resultColumnIDs = ["rname", "rcode", "rnote"]
    private static let resultColumnWidths: [CGFloat] = [232, 96, 130]
    private static let resultRowHeight: CGFloat = 22
    private static let maximumVisibleResults = 6
    private static let hint = "在上面搜代码 / 名称 / 拼音加入清单（这是唯一的加行方式）；"
        + "下面的表格能改名称、代码与股数 —— 只填 6 位数字会自动补前缀，股数留空 = 不持仓。"

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
        clearSearch()
        tableView.reloadData()
        refreshButtons()
    }

    // MARK: - 布局

    private func buildLayout() {
        translatesAutoresizingMaskIntoConstraints = false

        let hintLabel = NSTextField(labelWithString: Self.hint)
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.maximumNumberOfLines = 2
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.preferredMaxLayoutWidth = 548

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

        // ── 搜索框 + 结果列表
        searchField.placeholderString = "搜索代码 / 名称 / 拼音，回车或点一下加入清单"
        searchField.delegate = self
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = false

        for (index, identifier) in Self.resultColumnIDs.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = Self.resultColumnTitles[index]
            column.width = Self.resultColumnWidths[index]
            column.minWidth = 60
            resultsTable.addTableColumn(column)
        }
        resultsTable.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        resultsTable.dataSource = self
        resultsTable.delegate = self
        resultsTable.rowHeight = Self.resultRowHeight
        resultsTable.headerView = nil          // 就几行候选，表头只是占地方
        resultsTable.style = .inset
        resultsTable.allowsEmptySelection = true
        resultsTable.target = self
        resultsTable.action = #selector(resultClicked)

        resultsScroll.documentView = resultsTable
        resultsScroll.hasVerticalScroller = false
        resultsScroll.borderType = .bezelBorder
        resultsScroll.isHidden = true          // 没结果时整块收起（NSStackView 会跳过隐藏项）

        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byTruncatingTail

        for (button, action) in [
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

        let editButtons = NSStackView(views: [removeButton, upButton, downButton])
        editButtons.orientation = .horizontal
        editButtons.spacing = 8

        // 撑开用的空视图：压低抗拉伸/抗压缩，让多余空间都落在它身上，按钮被推到右边
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let bottomBar = NSStackView(views: [editButtons, restoreButton, spacer, cancelButton, saveButton])
        bottomBar.orientation = .horizontal
        bottomBar.spacing = 8

        let root = NSStackView(views: [hintLabel, searchField, resultsScroll, scrollView, messageLabel, bottomBar])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false

        addSubview(root)

        // 结果列表按条数长高，最多露出 6 行，再多就在框里滚
        let resultsHeight = resultsScroll.heightAnchor.constraint(
            equalToConstant: Self.resultRowHeight * CGFloat(Self.maximumVisibleResults)
        )
        resultsHeight.isActive = true
        resultsHeightConstraint = resultsHeight

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),

            hintLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            resultsScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            resultsScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
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
        tableView === resultsTable ? searchResults.count : draft.rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier.rawValue else { return nil }
        return tableView === resultsTable
            ? resultCell(identifier: identifier, row: row)
            : editCell(identifier: identifier, row: row)
    }

    /// 候选行：不可编辑的纯文本（黄色高亮表示已经加过了）
    private func resultCell(identifier: String, row: Int) -> NSView? {
        guard searchResults.indices.contains(row) else { return nil }
        let result = searchResults[row]
        let already = isAlreadyListed(result.code)

        let text: String
        switch identifier {
        case "rname": text = result.name
        case "rcode": text = result.code
        default: text = already ? "已在清单" : result.kind
        }

        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingTail
        field.alignment = identifier == "rcode" ? .right : .left
        field.textColor = already
            ? .tertiaryLabelColor
            : (identifier == "rnote" ? .secondaryLabelColor : .labelColor)
        return field
    }

    private func editCell(identifier: String, row: Int) -> NSView? {
        guard draft.rows.indices.contains(row) else { return nil }

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
        field.placeholderString = switch identifier {
        case "code": "sh600036"
        case "shares": "留空 = 不持仓"
        case "cost": "留空 = 未设置"
        default: ""
        }
        // 股数是数字，右对齐读起来更快；名称和代码左对齐
        field.alignment = (identifier == "shares" || identifier == "cost") ? .right : .left
        return field
    }

    private func text(for identifier: String, row: WatchlistRow) -> String {
        switch identifier {
        case "name": return row.name
        case "code": return row.code
        case "shares": return WatchlistDraft.sharesText(row.shares)
        case "cost": return WatchlistDraft.costText(row.cost)
        default: return ""
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView) !== resultsTable else { return }
        refreshButtons()
    }

    // MARK: - 编辑单元格 → 草稿

    /// 正在编辑的格子上打字时（搜索框走另一条路）
    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSSearchField) === searchField else { return }
        scheduleSearch()
    }

    /// 编辑结束（Tab / 回车 / 点别处）就把值收回草稿。
    ///
    /// 这里刻意**不** `reloadData()`：重建 cell 会打断 Tab 的焦点链，
    /// 所以只把当前 field 的内容改成规范化后的样子。
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field !== searchField
        else { return }

        let row = tableView.row(for: field)
        let identifier = field.identifier?.rawValue ?? ""
        // 刚被我们主动重画过的那一格，随后会补发一次 endEditing ——
        // 那时它已经是「没人编辑的空壳」，这一笔必须丢掉
        if let suppressed = suppressedField, field === suppressed {
            suppressedField = nil
            return
        }
        guard draft.rows.indices.contains(row) else { return }

        switch identifier {
        case "name":
            draft.rows[row].name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            field.stringValue = draft.rows[row].name
            if !draft.rows[row].name.isEmpty, draft.rows[row].code.isEmpty {
                autoFillCode(forName: draft.rows[row].name)
            }
        case "code":
            draft.rows[row].code = field.stringValue
            draft.normalizeCode(at: row)
            field.stringValue = draft.rows[row].code
            if WatchlistDraft.isValidCode(draft.rows[row].code), draft.rows[row].name.isEmpty {
                autoFillName(forCode: draft.rows[row].code)
            }
        case "shares":
            draft.rows[row].shares = WatchlistDraft.parseShares(field.stringValue)
            field.stringValue = WatchlistDraft.sharesText(draft.rows[row].shares)
        case "cost":
            draft.rows[row].cost = WatchlistDraft.parseCost(field.stringValue)
            field.stringValue = WatchlistDraft.costText(draft.rows[row].cost)
        default:
            return
        }

        messageLabel.stringValue = ""
        refreshButtons()
    }

    /// 搜索框里的特殊按键：↑↓ 选候选、回车加入、Esc 清空
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard (control as? NSSearchField) === searchField else { return false }

        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveHighlight(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveHighlight(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            addHighlightedResult()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            clearSearch()
            return true
        default:
            return false
        }
    }

    // MARK: - 搜索

    private func scheduleSearch() {
        searchTask?.cancel()
        let keyword = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard keyword.count >= StockSearch.minimumKeywordLength else {
            showResults([])
            return
        }

        searchTask = Task { [weak self] in
            // 防抖：边打字边搜会把接口打爆，也白白让结果闪
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }

            let outcome = await StockSearchService.searchWithFallback(keyword)
            guard !Task.isCancelled, let self else { return }
            // 网络回来时用户可能已经改了关键词，对不上就丢掉
            guard self.searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == keyword else {
                return
            }
            self.showResults(outcome.results, matched: outcome.keyword, requested: keyword)
        }
    }

    /// `matched` 是实际命中的关键词（可能比 `requested` 短，因为有前缀回退）；
    /// 两者不同时在提示行里说明，免得用户以为自己输错了。
    private func showResults(_ results: [StockSearchResult], matched: String? = nil, requested: String? = nil) {
        searchResults = results
        highlightedResult = results.isEmpty ? -1 : 0
        resultsTable.reloadData()
        resultsTable.selectRowIndexes(
            results.isEmpty ? IndexSet() : IndexSet(integer: 0),
            byExtendingSelection: false
        )

        if results.isEmpty {
            resultsScroll.isHidden = true
        } else {
            resultsScroll.isHidden = false
            let visible = min(CGFloat(results.count), CGFloat(Self.maximumVisibleResults))
            resultsHeightConstraint?.constant = Self.resultRowHeight * visible + 4
        }

        if results.isEmpty {
            // 只有「用户确实输了够长的词却没搜到」才提示，刚敲一两个字符时别吵
            if let requested, requested.count >= StockSearch.minimumKeywordLength {
                showMessage("没搜到「\(requested)」", isError: false)
            }
        } else if let matched, let requested, matched != requested {
            showMessage("没搜到「\(requested)」，下面是「\(matched)」的结果", isError: false)
        } else {
            messageLabel.stringValue = ""
        }
    }

    private func moveHighlight(by offset: Int) {
        guard !searchResults.isEmpty else { return }
        let next = min(max(0, highlightedResult + offset), searchResults.count - 1)
        highlightedResult = next
        resultsTable.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        resultsTable.scrollRowToVisible(next)
    }

    private func addHighlightedResult() {
        let index = highlightedResult >= 0 ? highlightedResult : 0
        guard searchResults.indices.contains(index) else { return }
        add(searchResults[index])
    }

    @objc private func resultClicked() {
        let row = resultsTable.clickedRow
        guard searchResults.indices.contains(row) else { return }
        add(searchResults[row])
    }

    private func add(_ result: StockSearchResult) {
        guard !isAlreadyListed(result.code) else {
            showMessage("\(result.name) 已经在清单里了", isError: false)
            return
        }

        draft.rows.append(WatchlistRow(code: result.code, name: result.name, shares: nil))
        tableView.reloadData()
        let row = draft.rows.count - 1
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        // 光标直接落到股数格：代码和名称已经填好了，下一步就是填持仓
        tableView.editColumn(2, row: row, with: nil, select: true)

        clearSearch()
        showMessage("已加入 \(result.name)（\(result.code)），点「保存」才生效", isError: false)
        refreshButtons()
    }

    private func clearSearch() {
        searchTask?.cancel()
        searchField.stringValue = ""
        showResults([])
    }

    private func isAlreadyListed(_ code: String) -> Bool {
        draft.rows.contains { $0.code == code }
    }

    // MARK: - 单元格自动补全

    /// 代码填完了，把名称补上。
    ///
    /// 只有行还在、名称还空着、而且用户没正在改这一格时才写 —— 异步回来时
    /// 这些前提都可能已经变了。
    private func autoFillName(forCode code: String) {
        Task { [weak self] in
            let results = await StockSearchService.search(code)
            guard let self,
                  // 只认精确命中的那条：搜索本身已经证明了这个代码存不存在，
                  // 退而取第一条等于替用户「猜」了一个，会把无关标的的名字填进来
                  // （比如把 sz600036 填成「招商银行」，而 sz600036 根本不存在）
                  let match = results.first(where: { $0.code == code }),
                  let row = self.draft.rows.firstIndex(where: { $0.code == code && $0.name.isEmpty }),
                  !self.isEditingWithContent(row: row, identifier: "name")
            else { return }

            self.draft.rows[row].name = match.name
            self.refreshCell(row: row, column: 0, identifier: "name")
        }
    }

    /// 名称填完了，试着把代码补上。
    ///
    /// 挑哪一条由 `StockSearch.bestMatch` 决定：只有一条候选、或者名字完全对得上
    /// 才敢写，其余宁可空着让用户自己去搜（重名的标的太多了）。
    private func autoFillCode(forName name: String) {
        Task { [weak self] in
            let results = await StockSearchService.search(name)
            guard let self,
                  let match = StockSearch.bestMatch(forName: name, in: results),
                  let row = self.draft.rows.firstIndex(where: { $0.name == name && $0.code.isEmpty }),
                  !self.isEditingWithContent(row: row, identifier: "code")
            else { return }

            self.draft.rows[row].code = match.code
            self.refreshCell(row: row, column: 1, identifier: "code")
        }
    }

    /// 这一格正在编辑**且已经打了字** —— 那就别去覆盖用户。
    ///
    /// 只看「有没有焦点」是不够的：从名称格 Tab 过来时光标正好落在空的代码格上，
    /// 那正是要补全的时机；只有格子里已经有内容了才该让路。
    private func isEditingWithContent(row: Int, identifier: String) -> Bool {
        guard isEditingCell(row: row, identifier: identifier),
              let field = (window?.firstResponder as? NSTextView)?.delegate as? NSTextField
        else { return false }
        return !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 焦点是不是在这一格上（不管里面有没有内容）
    private func isEditingCell(row: Int, identifier: String) -> Bool {
        guard let editor = window?.firstResponder as? NSTextView,
              let field = editor.delegate as? NSTextField
        else { return false }
        return tableView.row(for: field) == row && field.identifier?.rawValue == identifier
    }

    /// 重画一格。补全回来的值要看得见；如果光标本来就在这格上，
    /// 重建 cell 之后得把焦点还回去，否则用户打着字光标就没了。
    private func refreshCell(row: Int, column: Int, identifier: String) {
        let wasEditing = isEditingCell(row: row, identifier: identifier)
        // ⚠️ 重画正在编辑的那一格会先结束它的编辑，而 `controlTextDidEndEditing`
        // 会把那个（已经作废的）field 里的内容写回草稿 —— 正好把我们刚补上的值冲成空。
        // 所以先把这个 field 记下来，让它随后那一笔被丢掉。
        if wasEditing { suppressedField = currentEditingField() }

        tableView.reloadData(
            forRowIndexes: IndexSet(integer: row),
            columnIndexes: IndexSet(integer: column)
        )

        if wasEditing {
            tableView.editColumn(column, row: row, with: nil, select: true)
        }
    }

    private func currentEditingField() -> NSTextField? {
        (window?.firstResponder as? NSTextView)?.delegate as? NSTextField
    }

    // MARK: - 按钮

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
    /// 参数是校验通过的新配置；返回 false 表示没保存成功（窗口就不关，改动还在）
    var onSave: ((WatchlistConfig) -> Bool)?

    private var window: WatchlistSettingsWindow?
    private var view: WatchlistSettingsView?
    /// 打开窗口那一刻磁盘上的内容。保存前拿它和磁盘现状比对，
    /// 期间被外部改过就先问一句，别把人家的改动闷头覆盖掉
    private var baseline: WatchlistConfig?

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
            let config = WatchlistConfig.load()
            view.reload(config: config)
            baseline = config
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
        view.onSave = { [weak self] config in self?.handleSave(config) ?? false }
        view.onCancel = { [weak self] in self?.close() }
        self.view = view
        return view
    }

    /// 返回是否真的存下去了；存成功才关窗
    private func handleSave(_ config: WatchlistConfig) -> Bool {
        if let baseline, WatchlistConfig.load() != baseline {
            guard confirmOverwrite() else { return false }
        }
        guard onSave?(config) == true else { return false }
        close()
        return true
    }

    /// 窗口开着的时候配置文件被外部（编辑器 / 另一份 app）改过
    private func confirmOverwrite() -> Bool {
        let alert = NSAlert()
        alert.messageText = "配置文件在窗口打开期间被改过"
        alert.informativeText = "继续保存会覆盖掉外面的改动。要放弃你的修改，请点「取消」再重新打开窗口。"
        alert.addButton(withTitle: "仍然覆盖")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
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
