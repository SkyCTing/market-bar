import AppKit

/// 「8 杯水」的设置表单（作为 NSAlert 的 accessory view）。
///
/// 上面一行是「起止时间 + 杯数」，下面把**每一杯的时刻**都列出来单独可改。
/// 默认按起止时间均分填好，改过任何一个就进入「自定义」；「恢复均分」退回均分。
///
/// 手写 frame，和 `ReminderDialogView` / `MeetingSettingsView` 一个路子
@MainActor
final class WaterSettingsView: NSView {
    /// 每行放几个时间选择器
    private static let columns = 4
    private static let rowHeight: CGFloat = 28
    private static let pickerSize = NSSize(width: 88, height: 24)

    private let startPicker = NSDatePicker()
    private let endPicker = NSDatePicker()
    private let cupsField = NSTextField()
    private let cupsStepper = NSStepper()
    /// 每杯的时刻。数量跟着杯数重建
    private var cupPickers: [NSDatePicker] = []
    private let summaryLabel = NSTextField(labelWithString: "")
    private let customLabel = NSTextField(labelWithString: "")
    private let resetButton = NSButton(title: "恢复均分", target: nil, action: nil)
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

    /// 原样带过来，保存时只在上面改几项（尤其 `alertKey` 不能动，见 WaterPlan）
    private let original: WaterPlan

    init(plan: WaterPlan) {
        original = plan
        // 高度按**最多**杯数留 —— NSAlert 不会因为里面换了个子视图就重新量尺寸，
        // 所以不能按当前杯数动态改高度
        let maxRows = Int(ceil(Double(WaterPlan.cupRange.upperBound) / Double(Self.columns)))
        let height = 210 + CGFloat(maxRows) * Self.rowHeight
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: height))
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
        // 和均分一模一样就存空的：这样以后改起止时间仍然会跟着变。
        // 只有真的动过某一杯，才把具体时刻记下来
        let picked = cupPickers.map { Self.minutes(from: $0.dateValue) }
        next.customTimes = (picked == evenMinutes) ? [] : picked
        return next
    }

    private var selectedMethods: Reminder.Methods {
        var methods: Reminder.Methods = []
        if bubbleCheckbox.state == .on { methods.insert(.bubble) }
        if alertCheckbox.state == .on { methods.insert(.alert) }
        // 两个都不勾就没法提醒了。界面上取消不掉（见 methodChanged），这里再兜一层
        return methods.isEmpty ? .bubble : methods
    }

    /// 头部三个控件算出来的均分结果 —— 用来给选择器填默认值、也用来判断「改过没有」
    private var evenMinutes: [Int] {
        var probe = original
        probe.startMinutes = Self.minutes(from: startPicker.dateValue)
        probe.endMinutes = Self.minutes(from: endPicker.dateValue)
        probe.cups = Int(cupsField.stringValue) ?? probe.cups
        probe.customTimes = []
        return probe.evenMinutes
    }

    // MARK: - 布局

    private func buildLayout() {
        let top = bounds.height

        func rowLabel(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat = 52) {
            let field = NSTextField(labelWithString: text)
            field.frame = NSRect(x: x, y: y + 4, width: width, height: 18)
            field.alignment = .right
            addSubview(field)
        }

        // ── 第 1 行：起止时间 + 杯数
        rowLabel("开始", x: 0, y: top - 38)
        configure(startPicker)
        startPicker.frame = NSRect(x: 56, y: top - 42, width: 84, height: 24)
        startPicker.target = self
        startPicker.action = #selector(headerChanged)
        addSubview(startPicker)

        rowLabel("结束", x: 148, y: top - 38)
        configure(endPicker)
        endPicker.frame = NSRect(x: 204, y: top - 42, width: 84, height: 24)
        endPicker.target = self
        endPicker.action = #selector(headerChanged)
        addSubview(endPicker)

        rowLabel("每天", x: 296, y: top - 38, width: 32)
        cupsField.frame = NSRect(x: 332, y: top - 42, width: 36, height: 24)
        cupsField.alignment = .right
        cupsField.delegate = self
        addSubview(cupsField)
        cupsStepper.frame = NSRect(x: 371, y: top - 42, width: 19, height: 24)
        cupsStepper.minValue = Double(WaterPlan.cupRange.lowerBound)
        cupsStepper.maxValue = Double(WaterPlan.cupRange.upperBound)
        cupsStepper.increment = 1
        cupsStepper.target = self
        cupsStepper.action = #selector(stepperChanged)
        addSubview(cupsStepper)

        // ── 第 2 行：均分摘要 / 是否已自定义 / 恢复均分
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.frame = NSRect(x: 0, y: top - 66, width: 200, height: 18)
        addSubview(summaryLabel)

        customLabel.font = .systemFont(ofSize: 11)
        customLabel.frame = NSRect(x: 200, y: top - 66, width: 120, height: 18)
        addSubview(customLabel)

        resetButton.frame = NSRect(x: 322, y: top - 70, width: 78, height: 22)
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.target = self
        resetButton.action = #selector(resetToEven)
        addSubview(resetButton)

        // ── 每杯的时刻们（从这一行往下铺，4 个一行）
        let gridTop = top - 100
        let totalWidth = CGFloat(Self.columns) * Self.pickerSize.width + CGFloat(Self.columns - 1) * 6
        let originX = (bounds.width - totalWidth) / 2
        for index in 0 ..< WaterPlan.cupRange.upperBound {
            let picker = NSDatePicker()
            configure(picker)
            picker.target = self
            picker.action = #selector(cupChanged)
            let column = index % Self.columns
            let row = index / Self.columns
            picker.frame = NSRect(
                x: originX + CGFloat(column) * (Self.pickerSize.width + 6),
                y: gridTop - CGFloat(row + 1) * Self.rowHeight + 4,
                width: Self.pickerSize.width,
                height: Self.pickerSize.height
            )
            picker.isHidden = true
            addSubview(picker)
            cupPickers.append(picker)
        }

        // ── 提醒方式
        rowLabel("提醒方式", x: 0, y: 76)
        bubbleCheckbox.frame = NSRect(x: 64, y: 78, width: 320, height: 18)
        alertCheckbox.frame = NSRect(x: 64, y: 56, width: 320, height: 18)
        for checkbox in [bubbleCheckbox, alertCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(methodChanged(_:))
            addSubview(checkbox)
        }

        let hint = NSTextField(wrappingLabelWithString:
            "默认在起止时间之间均分，每一杯都可以单独改。喝够当天就不再提醒；"
                + "app 没开着时错过的那些不补，免得一打开被一堆积压弹窗糊脸。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 0, y: 4, width: 400, height: 44)
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
        cupsField.stringValue = "\(plan.cups)"
        cupsStepper.integerValue = plan.cups

        let methods = plan.methods.isEmpty ? Reminder.Methods.bubble : plan.methods
        bubbleCheckbox.state = methods.contains(.bubble) ? .on : .off
        alertCheckbox.state = methods.contains(.alert) ? .on : .off

        fillCupPickers(plan.cupMinutes)
    }

    /// 把选择器按给定的时刻列表铺开，多余的藏起来
    private func fillCupPickers(_ minutes: [Int]) {
        for (index, picker) in cupPickers.enumerated() {
            guard index < minutes.count else {
                picker.isHidden = true
                continue
            }
            // 先设值再取消隐藏：设值不会触发 action（那时候还没变过），
            // 而且顺序反了会让隐藏中的控件先闪一下
            picker.dateValue = Self.date(fromMinutes: minutes[index])
            picker.isHidden = false
        }
        refreshSummary()
    }

    private func refreshSummary() {
        let chosen = cupPickers.filter { !$0.isHidden }
        guard !chosen.isEmpty else {
            summaryLabel.stringValue = ""
            customLabel.stringValue = ""
            resetButton.isEnabled = false
            return
        }

        let isCustom = chosen.map { Self.minutes(from: $0.dateValue) } != evenMinutes
        summaryLabel.stringValue = "共 \(chosen.count) 杯"
        customLabel.stringValue = isCustom ? "· 已自定义" : "· 按起止时间均分"
        customLabel.textColor = isCustom ? .controlAccentColor : .secondaryLabelColor
        resetButton.isEnabled = isCustom
    }

    // MARK: - 交互

    /// 改起止时间或杯数 → 重新均分。这三项是均分的参数，改了当然要重算
    @objc private func headerChanged() {
        fillCupPickers(evenMinutes)
    }

    @objc private func stepperChanged() {
        cupsField.stringValue = "\(cupsStepper.integerValue)"
        fillCupPickers(evenMinutes)
    }

    @objc private func cupChanged() {
        refreshSummary()
    }

    @objc private func resetToEven() {
        fillCupPickers(evenMinutes)
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
        // 手打杯数时不必每敲一个字符就重排选择器（输入到一半的数字没意义），
        // 但摘要要跟着动
        refreshSummary()
    }
}
