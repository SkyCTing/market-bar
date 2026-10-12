import AppKit

/// 「8 杯水」的设置表单（作为 NSAlert 的 accessory view）。
///
/// 手写 frame，和 `ReminderDialogView` / `MeetingSettingsView` 一个路子
@MainActor
final class WaterSettingsView: NSView {
    private let startPicker = NSDatePicker()
    private let endPicker = NSDatePicker()
    private let cupsField = NSTextField()
    private let cupsStepper = NSStepper()
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
    private let summaryLabel = NSTextField(labelWithString: "")

    /// 原样带过来，保存时只在上面改这几项（尤其 `alertKey` 不能动，见 WaterPlan）
    private let original: WaterPlan

    init(plan: WaterPlan) {
        original = plan
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 190))
        buildLayout()
        apply(plan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var firstResponderControl: NSView { cupsField }

    // MARK: - 读表单

    /// 表单当前值。非法输入就地夹到合法范围，不返回 nil ——
    /// 这个表单没有「填错了」的路径，只有「填成什么样都能用」
    var plan: WaterPlan {
        var next = original
        next.startMinutes = Self.minutes(from: startPicker.dateValue)
        next.endMinutes = Self.minutes(from: endPicker.dateValue)
        next.cups = Int(cupsField.stringValue) ?? next.cups
        next.methods = selectedMethods
        return next
    }

    private var selectedMethods: Reminder.Methods {
        var methods: Reminder.Methods = []
        if bubbleCheckbox.state == .on { methods.insert(.bubble) }
        if alertCheckbox.state == .on { methods.insert(.alert) }
        // 两个都不勾就没法提醒了。界面上取消不掉（见 methodChanged），这里再兜一层
        return methods.isEmpty ? .bubble : methods
    }

    // MARK: - 布局

    private func buildLayout() {
        func rowLabel(_ text: String, y: CGFloat) {
            let field = NSTextField(labelWithString: text)
            field.frame = NSRect(x: 0, y: y + 4, width: 80, height: 18)
            field.alignment = .right
            addSubview(field)
        }

        rowLabel("开始时间", y: 156)
        configure(startPicker)
        startPicker.frame = NSRect(x: 88, y: 152, width: 110, height: 24)
        addSubview(startPicker)

        // 「结束时间」的标签要挨着它自己那个 picker —— `rowLabel` 固定从 x=0 起，
        // 直接用会和「开始时间」叠在一起
        let endLabel = NSTextField(labelWithString: "结束时间")
        endLabel.frame = NSRect(x: 176, y: 156, width: 52, height: 18)
        endLabel.alignment = .right
        addSubview(endLabel)
        endPicker.frame = NSRect(x: 232, y: 152, width: 110, height: 24)
        configure(endPicker)
        addSubview(endPicker)

        rowLabel("每天几杯", y: 122)
        cupsField.frame = NSRect(x: 88, y: 118, width: 60, height: 24)
        cupsField.alignment = .right
        cupsField.delegate = self
        addSubview(cupsField)
        cupsStepper.frame = NSRect(x: 152, y: 118, width: 19, height: 24)
        cupsStepper.minValue = Double(WaterPlan.cupRange.lowerBound)
        cupsStepper.maxValue = Double(WaterPlan.cupRange.upperBound)
        cupsStepper.increment = 1
        cupsStepper.target = self
        cupsStepper.action = #selector(stepperChanged)
        addSubview(cupsStepper)

        // 实时算出「每杯间隔多久」，省得用户自己算
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.frame = NSRect(x: 184, y: 122, width: 216, height: 18)
        addSubview(summaryLabel)

        rowLabel("提醒方式", y: 82)
        bubbleCheckbox.frame = NSRect(x: 88, y: 84, width: 300, height: 18)
        alertCheckbox.frame = NSRect(x: 88, y: 62, width: 300, height: 18)
        for checkbox in [bubbleCheckbox, alertCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(methodChanged(_:))
            addSubview(checkbox)
        }

        let hint = NSTextField(wrappingLabelWithString:
            "在起止时间之间均分这几杯，第一杯从开始时间算起。喝够当天就不再提醒；"
                + "app 没开着时错过的那些不补，免得一打开被一堆积压弹窗糊脸。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 0, y: 6, width: 400, height: 46)
        addSubview(hint)
    }

    private func configure(_ picker: NSDatePicker) {
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.hourMinute]
        picker.datePickerMode = .single
    }

    private func apply(_ plan: WaterPlan) {
        startPicker.dateValue = Self.date(fromMinutes: plan.startMinutes)
        endPicker.dateValue = Self.date(fromMinutes: plan.endMinutes)
        cupsField.stringValue = "\(plan.effectiveCups)"
        cupsStepper.integerValue = plan.effectiveCups

        let methods = plan.methods.isEmpty ? Reminder.Methods.bubble : plan.methods
        bubbleCheckbox.state = methods.contains(.bubble) ? .on : .off
        alertCheckbox.state = methods.contains(.alert) ? .on : .off

        refreshSummary()
    }

    private func refreshSummary() {
        let plan = self.plan
        let window = plan.effectiveWindow
        let minutes = window.end - window.start
        let cups = plan.effectiveCups
        guard minutes > 0, cups > 0 else {
            summaryLabel.stringValue = ""
            return
        }
        let step = minutes / cups
        summaryLabel.stringValue = "每 \(step / 60) 小时 \(step % 60) 分一次"
    }

    @objc private func stepperChanged() {
        cupsField.stringValue = "\(cupsStepper.integerValue)"
        refreshSummary()
    }

    @objc private func methodChanged(_ sender: NSButton) {
        // 两个都不勾就没法提醒了：把刚被取消的那个弹回去
        if bubbleCheckbox.state == .off, alertCheckbox.state == .off {
            sender.state = .on
        }
    }

    // MARK: - 分钟 ↔ Date

    /// 只借一个固定日期当时基，真正存的是「从 0 点算起的分钟数」
    private static func date(fromMinutes minutes: Int) -> Date {
        let clamped = min(max(minutes, 0), 24 * 60 - 1)
        var components = DateComponents()
        components.year = 2000
        components.month = 1
        components.day = 1
        components.hour = clamped / 60
        components.minute = clamped % 60
        return TradingSession.calendar.date(from: components) ?? Date()
    }

    private static func minutes(from date: Date) -> Int {
        let parts = TradingSession.calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

extension WaterSettingsView: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        refreshSummary()
    }
}
