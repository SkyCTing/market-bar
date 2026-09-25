import AppKit

/// 「提醒管理」窗口：定时提醒、倒计时、价格提醒都收在一张表里。
///
/// 做这个是因为菜单里条目一多就拉得老长；菜单现在只列前几条，全在这里管。
@MainActor
final class ReminderListWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 表里的一行：要么是一条提醒，要么是一条价格提醒
enum ReminderListEntry: Equatable {
    case reminder(Reminder)
    case priceAlert(PriceAlert)

    var id: UUID {
        switch self {
        case .reminder(let reminder): return reminder.id
        case .priceAlert(let alert): return alert.id
        }
    }
}

@MainActor
final class ReminderListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    /// 提醒（定时/倒计时在表单里切）与价格提醒各一个入口
    var onAddReminder: (() -> Void)?
    var onAddPriceAlert: (() -> Void)?
    /// 双击某一行 / 点「编辑」
    var onEdit: ((ReminderListEntry) -> Void)?
    /// 点「删除」（多选）
    var onDelete: (([ReminderListEntry]) -> Void)?
    /// 点「测试提醒」—— 当场按当前提醒方式弹一条，不用等
    var onTest: (() -> Void)?

    private(set) var entries: [ReminderListEntry] = []
    /// 价格提醒每一行显示什么名字，由外面注入（要查自选清单）
    var displayName: ((PriceAlert.Target) -> String)?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let editButton = NSButton(title: "编辑", target: nil, action: nil)
    private let deleteButton = NSButton(title: "删除", target: nil, action: nil)

    private static let columns: [(id: String, title: String, width: CGFloat)] = [
        ("kind", "类型", 76),
        ("content", "内容", 210),
        ("rule", "规则", 190),
        ("methods", "提醒方式", 120),
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 重新铺表
    func reload(reminders: [Reminder], priceAlerts: [PriceAlert]) {
        // 提醒在前、价格提醒在后；各自保持原有顺序（提醒的顺序有意义：倒计时按到点先后看）
        entries = reminders.map(ReminderListEntry.reminder) + priceAlerts.map(ReminderListEntry.priceAlert)
        messageLabel.stringValue = entries.isEmpty ? "还没有提醒。用下面的按钮加一条。" : ""
        tableView.reloadData()
        refreshButtons()
    }

    private func buildLayout() {
        for column in Self.columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 60
            tableView.addTableColumn(tableColumn)
        }
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 24
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.target = self
        tableView.doubleAction = #selector(editSelected)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .secondaryLabelColor

        let addReminder = NSButton(title: "添加提醒…", target: self, action: #selector(addReminder))
        let addAlert = NSButton(title: "添加价格提醒…", target: self, action: #selector(addPriceAlert))
        let testButton = NSButton(title: "测试提醒", target: self, action: #selector(testReminder))
        for button in [addReminder, addAlert, testButton, editButton, deleteButton] {
            button.bezelStyle = .rounded
        }
        // ⚠️ 这两个按钮建的时候都是 target: nil —— 必须逐个接上，
        // 漏一个的表现就是「点了完全没反应」，而且不报错、不崩
        editButton.target = self
        editButton.action = #selector(editSelected)
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected)

        let leftButtons = NSStackView(views: [addReminder, addAlert, testButton])
        leftButtons.spacing = 8
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let bottomBar = NSStackView(views: [leftButtons, spacer, editButton, deleteButton])
        bottomBar.spacing = 8

        let root = NSStackView(views: [scrollView, messageLabel, bottomBar])
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
            bottomBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
    }

    private func refreshButtons() {
        let selected = tableView.selectedRowIndexes
        editButton.isEnabled = selected.count == 1
        deleteButton.isEnabled = !selected.isEmpty
    }

    // MARK: - 表格

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier.rawValue, entries.indices.contains(row) else { return nil }

        let field = NSTextField(labelWithString: text(for: identifier, entry: entries[row]))
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingTail
        field.textColor = identifier == "kind" ? .secondaryLabelColor : .labelColor
        return field
    }

    private func text(for identifier: String, entry: ReminderListEntry) -> String {
        switch entry {
        case .reminder(let reminder):
            switch identifier {
            case "kind": return reminder.kind == .countdown ? "倒计时" : "定时"
            case "content": return reminder.body
            case "rule":
                return reminder.kind == .countdown
                    ? "\(CountdownFormat.duration(reminder.countdownSeconds))·\(reminder.repeatsCountdown ? "循环" : "一次")"
                    : "\(reminder.timeText) \(reminder.repeatRule.title)"
            case "methods": return reminder.methods.title
            default: return ""
            }
        case .priceAlert(let alert):
            switch identifier {
            case "kind": return "价格"
            case "content": return alert.message.isEmpty ? "（默认提示语）" : alert.message
            case "rule": return "\(displayName?(alert.target) ?? "") \(alert.direction.symbol) \(String(format: "%.2f", alert.threshold))"
            case "methods": return alert.methods.title
            default: return ""
            }
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshButtons()
    }

    // MARK: - 按钮

    @objc private func addReminder() { onAddReminder?() }
    @objc private func testReminder() { onTest?() }
    @objc private func addPriceAlert() { onAddPriceAlert?() }

    @objc private func editSelected() {
        let selected = tableView.selectedRowIndexes
        guard selected.count == 1, let row = selected.first, entries.indices.contains(row) else { return }
        onEdit?(entries[row])
    }

    @objc private func deleteSelected() {
        let selected = tableView.selectedRowIndexes
        guard !selected.isEmpty else { return }
        onDelete?(selected.compactMap { entries.indices.contains($0) ? entries[$0] : nil })
    }
}

/// 持有窗口（懒创建），转发用户操作给 AppDelegate
@MainActor
final class ReminderListController {
    var onAddReminder: (() -> Void)?
    var onAddPriceAlert: (() -> Void)?
    var onEdit: ((ReminderListEntry) -> Void)?
    var onDelete: (([ReminderListEntry]) -> Void)?
    var onTest: (() -> Void)?
    var displayName: ((PriceAlert.Target) -> String)?

    private var window: ReminderListWindow?
    private var view: ReminderListView?

    var isVisible: Bool { window?.isVisible ?? false }

    func show(reminders: [Reminder], priceAlerts: [PriceAlert]) {
        let view: ReminderListView
        if let existing = self.view {
            view = existing
        } else {
            let created = ReminderListView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
            created.onAddReminder = { [weak self] in self?.onAddReminder?() }
            created.onAddPriceAlert = { [weak self] in self?.onAddPriceAlert?() }
            created.onEdit = { [weak self] entry in self?.onEdit?(entry) }
            created.onDelete = { [weak self] entries in self?.onDelete?(entries) }
            created.onTest = { [weak self] in self?.onTest?() }
            view = created
            self.view = created
        }

        view.displayName = displayName
        view.reload(reminders: reminders, priceAlerts: priceAlerts)

        let window: ReminderListWindow
        if let existing = self.window {
            window = existing
        } else {
            let created = ReminderListWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            created.title = "提醒管理"
            created.contentView = view
            created.minSize = NSSize(width: 520, height: 280)
            // 关掉只是 orderOut，下次还能用同一个窗口
            created.isReleasedWhenClosed = false
            window = created
            self.window = created
        }

        if !window.isVisible { window.center() }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// 内容变了（增删改之后）就地刷新，窗口没开也不花代价
    func refresh(reminders: [Reminder], priceAlerts: [PriceAlert]) {
        guard let view, window?.isVisible == true else { return }
        view.displayName = displayName
        view.reload(reminders: reminders, priceAlerts: priceAlerts)
    }

    func close() {
        window?.orderOut(nil)
    }
}
