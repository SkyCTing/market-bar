import AppKit

/// 价格提醒的配置表单（作为 NSAlert 的 accessory view）。
///
/// 金价和股票共用一张表：目标下拉里第一项是「金价」，后面跟着自选清单里的标的。
@MainActor
final class PriceAlertDialogView: NSView {
    /// 目标下拉里的一项
    struct TargetOption {
        let title: String
        let target: PriceAlert.Target

        /// 金价 + 自选清单。清单里每一只带名字，选起来比记代码容易
        static func all(entries: [StockWatchlist.Entry]) -> [TargetOption] {
            [TargetOption(title: "金价", target: .gold)]
                + entries.map { TargetOption(title: "\($0.code) \($0.name)", target: .stock(code: $0.code)) }
        }
    }

    private let targetPopup = NSPopUpButton()
    private let directionPopup = NSPopUpButton()
    private let thresholdField = NSTextField()
    private let messageField = NSTextField()
    private let repeatsCheckbox = NSButton(
        checkboxWithTitle: "重复提醒（价格回落后再次穿过会再响一次）",
        target: nil,
        action: nil
    )
    private let bubbleCheckbox = NSButton(
        checkboxWithTitle: "宠物提示（冒气泡 + 响一声）",
        target: nil,
        action: nil
    )
    private let alertCheckbox = NSButton(
        checkboxWithTitle: "弹窗（置顶模态框）",
        target: nil,
        action: nil
    )

    private let options: [TargetOption]

    init(alert: PriceAlert?, targets: [TargetOption]) {
        options = targets
        super.init(frame: NSRect(x: 0, y: 0, width: 384, height: 204))
        buildLayout()
        apply(alert)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var firstResponderControl: NSView { thresholdField }

    private func buildLayout() {
        func rowLabel(_ text: String, y: CGFloat) {
            let field = NSTextField(labelWithString: text)
            field.frame = NSRect(x: 0, y: y + 3, width: 56, height: 18)
            field.alignment = .right
            addSubview(field)
        }

        rowLabel("目标", y: 166)
        targetPopup.frame = NSRect(x: 64, y: 164, width: 260, height: 25)
        targetPopup.addItems(withTitles: options.map(\.title))
        addSubview(targetPopup)

        rowLabel("方向", y: 132)
        directionPopup.frame = NSRect(x: 64, y: 130, width: 90, height: 25)
        directionPopup.addItems(withTitles: [PriceAlert.Direction.above.title, PriceAlert.Direction.below.title])
        addSubview(directionPopup)

        let thresholdLabel = NSTextField(labelWithString: "阈值")
        thresholdLabel.frame = NSRect(x: 164, y: 135, width: 32, height: 18)
        thresholdLabel.alignment = .right
        addSubview(thresholdLabel)
        thresholdField.frame = NSRect(x: 202, y: 130, width: 122, height: 24)
        thresholdField.placeholderString = "例如 45.00"
        addSubview(thresholdField)

        rowLabel("提示语", y: 96)
        messageField.frame = NSRect(x: 64, y: 94, width: 308, height: 24)
        messageField.placeholderString = "留空则用「代码: 价格」"
        addSubview(messageField)

        repeatsCheckbox.frame = NSRect(x: 64, y: 62, width: 308, height: 20)
        addSubview(repeatsCheckbox)

        rowLabel("提醒方式", y: 16)
        bubbleCheckbox.frame = NSRect(x: 64, y: 24, width: 308, height: 18)
        alertCheckbox.frame = NSRect(x: 64, y: 4, width: 308, height: 18)
        for checkbox in [bubbleCheckbox, alertCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(methodChanged(_:))
            addSubview(checkbox)
        }
    }

    private func apply(_ alert: PriceAlert?) {
        let target = alert?.target ?? .gold
        targetPopup.selectItem(at: options.firstIndex { $0.target == target } ?? 0)
        directionPopup.selectItem(at: alert?.direction == .below ? 1 : 0)
        if let threshold = alert?.threshold, threshold > 0 {
            thresholdField.stringValue = String(format: "%.2f", threshold)
        }
        messageField.stringValue = alert?.message ?? ""
        repeatsCheckbox.state = (alert?.repeats ?? true) ? .on : .off

        let methods = alert?.methods ?? .default
        bubbleCheckbox.state = methods.contains(.bubble) ? .on : .off
        alertCheckbox.state = methods.contains(.alert) ? .on : .off
    }

    /// 阈值非法时返回 nil（调用方 beep）
    func makeAlert(basedOn alert: PriceAlert?) -> PriceAlert? {
        let threshold = Double(thresholdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let threshold, threshold > 0, threshold.isFinite else { return nil }

        let direction: PriceAlert.Direction = directionPopup.indexOfSelectedItem == 1 ? .below : .above
        let target = options.indices.contains(targetPopup.indexOfSelectedItem)
            ? options[targetPopup.indexOfSelectedItem].target
            : .gold

        var result = alert ?? PriceAlert()
        // 条件（标的/方向/阈值）变了就把闩锁归零，否则新条件要等价格先回到内侧才会响。
        // 只改提示语或提醒方式时不动它，免得保存一下又立刻响一次
        if result.target != target || result.direction != direction || result.threshold != threshold {
            result.isTriggered = false
        }
        result.target = target
        result.direction = direction
        result.threshold = threshold
        result.message = messageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        result.repeats = repeatsCheckbox.state == .on
        result.methods = selectedMethods
        return result
    }

    private var selectedMethods: Reminder.Methods {
        var methods: Reminder.Methods = []
        if bubbleCheckbox.state == .on { methods.insert(.bubble) }
        if alertCheckbox.state == .on { methods.insert(.alert) }
        // 两个都不勾就没法提醒了。界面上本来就取消不掉（见 methodChanged），这里再兜一层
        return methods.isEmpty ? .bubble : methods
    }

    /// 两种提醒方式至少留一种：把刚被取消的那个弹回去
    @objc private func methodChanged(_ sender: NSButton) {
        if bubbleCheckbox.state == .off, alertCheckbox.state == .off {
            sender.state = .on
        }
    }
}
