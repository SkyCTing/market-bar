import AppKit

/// 提醒的配置表单（作为 NSAlert 的 accessory view）。
///
/// 两种触发方式**共用同样的行位置**，切换时只是把对方那一组控件的 `isHidden` 翻过来 ——
/// 这样隐藏掉的那组不会在表单里留下一块空洞：
///
/// | 行 | 定时 | 倒计时 |
/// |---|---|---|
/// | 时间 / 时长 | `NSDatePicker`（时/分/秒） | 时 / 分 / 秒三个输入框 |
/// | 重复 / 循环 | 每天·每周·每月·每 N 天 | 「到点后自动重新计时」勾选 |
/// | 条件 | 「智能跳过节假日」勾选 | 「从现在重新计时」勾选（只编辑时出现） |
///
/// 底下是两种提醒方式（宠物提示 / 弹窗），可以只开一个，也可以两个都开。
@MainActor
final class ReminderDialogView: NSView {
    private let typeControl = NSSegmentedControl(
        labels: ["定时", "倒计时"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )

    // ── 定时
    private let timePicker = NSDatePicker()
    private let repeatPopup = NSPopUpButton()
    private let weekdayPopup = NSPopUpButton()
    private let monthDayPopup = NSPopUpButton()
    private let dayIntervalLabel = NSTextField(labelWithString: "天数")
    private let dayIntervalField = NSTextField()
    private let skipHolidaysCheckbox = NSButton(
        checkboxWithTitle: "智能跳过节假日（调休上班日照常提醒）",
        target: nil,
        action: nil
    )

    // ── 倒计时
    private let hoursField = NSTextField()
    private let minutesField = NSTextField()
    private let secondsField = NSTextField()
    private let hoursUnit = NSTextField(labelWithString: "时")
    private let minutesUnit = NSTextField(labelWithString: "分")
    private let secondsUnit = NSTextField(labelWithString: "秒")
    private let repeatCountdownCheckbox = NSButton(
        checkboxWithTitle: "到点后自动重新计时（番茄钟）",
        target: nil,
        action: nil
    )
    private let restartCheckbox = NSButton(checkboxWithTitle: "从现在重新计时", target: nil, action: nil)

    // ── 公共
    private let timeLabel = NSTextField(labelWithString: "时间")
    private let repeatLabel = NSTextField(labelWithString: "重复")
    private let bodyField = NSTextField()
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

    /// 正在编辑的那条本来就是倒计时 —— 「从现在重新计时」只在这种情况下出现
    private let editingCountdown: Bool

    private static let repeatTitles = ["每天", "每周", "每月", "每 N 天"]

    init(reminder: Reminder?) {
        editingCountdown = reminder?.kind == .countdown
        super.init(frame: NSRect(x: 0, y: 0, width: 384, height: 236))

        buildLayout()
        apply(reminder)
        updateVisibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var firstResponderControl: NSView { bodyField }

    // MARK: - 布局

    private func buildLayout() {
        func rowLabel(_ field: NSTextField, y: CGFloat) {
            field.frame = NSRect(x: 0, y: y + 3, width: 56, height: 18)
            field.alignment = .right
            addSubview(field)
        }

        rowLabel(NSTextField(labelWithString: "类型"), y: 196)
        typeControl.frame = NSRect(x: 64, y: 194, width: 160, height: 24)
        typeControl.target = self
        typeControl.action = #selector(typeChanged)
        addSubview(typeControl)

        // ── 第 2 行：时间 / 时长
        rowLabel(timeLabel, y: 158)
        timePicker.datePickerStyle = .textFieldAndStepper
        timePicker.datePickerElements = [.hourMinuteSecond]
        timePicker.datePickerMode = .single
        timePicker.frame = NSRect(x: 64, y: 156, width: 130, height: 24)
        addSubview(timePicker)

        let unitFields = [
            (hoursField, 64.0), (minutesField, 130.0), (secondsField, 196.0),
        ]
        for (field, x) in unitFields {
            field.frame = NSRect(x: x, y: 156, width: 44, height: 24)
            field.alignment = .right
            addSubview(field)
        }
        for (unit, x) in [(hoursUnit, 112.0), (minutesUnit, 178.0), (secondsUnit, 244.0)] {
            unit.frame = NSRect(x: x, y: 159, width: 14, height: 18)
            addSubview(unit)
        }

        // ── 第 3 行：重复 / 循环
        rowLabel(repeatLabel, y: 122)
        repeatPopup.frame = NSRect(x: 64, y: 120, width: 96, height: 25)
        repeatPopup.addItems(withTitles: Self.repeatTitles)
        repeatPopup.target = self
        repeatPopup.action = #selector(repeatChanged)
        addSubview(repeatPopup)

        // 值本身已经说明是周几/几号（「周日」「1 号」），不再加多余的标签
        weekdayPopup.frame = NSRect(x: 166, y: 120, width: 100, height: 25)
        weekdayPopup.addItems(withTitles: ["周日", "周一", "周二", "周三", "周四", "周五", "周六"])
        addSubview(weekdayPopup)

        monthDayPopup.frame = NSRect(x: 166, y: 120, width: 100, height: 25)
        monthDayPopup.addItems(withTitles: (1...31).map { "\($0) 号" })
        addSubview(monthDayPopup)

        dayIntervalLabel.frame = NSRect(x: 166, y: 125, width: 32, height: 18)
        dayIntervalLabel.alignment = .right
        addSubview(dayIntervalLabel)
        dayIntervalField.frame = NSRect(x: 202, y: 120, width: 60, height: 24)
        dayIntervalField.placeholderString = "N"
        dayIntervalField.stringValue = "2"
        addSubview(dayIntervalField)

        repeatCountdownCheckbox.frame = NSRect(x: 64, y: 122, width: 308, height: 20)
        addSubview(repeatCountdownCheckbox)

        // ── 第 4 行：条件
        skipHolidaysCheckbox.frame = NSRect(x: 64, y: 88, width: 308, height: 20)
        addSubview(skipHolidaysCheckbox)

        restartCheckbox.frame = NSRect(x: 64, y: 88, width: 308, height: 20)
        addSubview(restartCheckbox)

        // ── 第 5 行：内容
        rowLabel(NSTextField(labelWithString: "内容"), y: 52)
        bodyField.frame = NSRect(x: 64, y: 50, width: 308, height: 24)
        bodyField.placeholderString = "例如：还信用卡 / 该起来走走了"
        addSubview(bodyField)

        // ── 第 6 段：提醒方式
        rowLabel(NSTextField(labelWithString: "提醒方式"), y: 14)
        bubbleCheckbox.frame = NSRect(x: 64, y: 22, width: 308, height: 18)
        alertCheckbox.frame = NSRect(x: 64, y: 2, width: 308, height: 18)
        for checkbox in [bubbleCheckbox, alertCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(methodChanged(_:))
            addSubview(checkbox)
        }
    }

    // MARK: - 读写

    private func apply(_ reminder: Reminder?) {
        typeControl.selectedSegment = reminder?.kind == .countdown ? 1 : 0

        // 时间
        let calendar = TradingSession.calendar
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.hour = reminder?.hour ?? 9
        components.minute = reminder?.minute ?? 0
        components.second = reminder?.second ?? 0
        timePicker.dateValue = calendar.date(from: components) ?? Date()

        switch reminder?.repeatRule {
        case .weekly(let weekday):
            repeatPopup.selectItem(at: 1)
            weekdayPopup.selectItem(at: max(0, min(6, weekday - 1)))
        case .monthly(let day):
            repeatPopup.selectItem(at: 2)
            monthDayPopup.selectItem(at: max(0, min(30, day - 1)))
        case .everyDays(let interval):
            repeatPopup.selectItem(at: 3)
            dayIntervalField.stringValue = "\(max(1, interval))"
        default:
            repeatPopup.selectItem(at: 0)
        }
        skipHolidaysCheckbox.state = (reminder?.skipHolidays ?? false) ? .on : .off

        // 倒计时：把总秒数拆回时/分/秒。新建时默认 25 分钟
        let total = reminder?.kind == .countdown ? max(0, reminder?.countdownSeconds ?? 0) : 25 * 60
        hoursField.stringValue = "\(total / 3_600)"
        minutesField.stringValue = "\((total % 3_600) / 60)"
        secondsField.stringValue = "\(total % 60)"
        repeatCountdownCheckbox.state = (reminder?.repeatsCountdown ?? false) ? .on : .off
        restartCheckbox.state = .off

        // 提醒方式：新建默认两个都开（和升级前的行为一致）
        let methods = reminder?.methods ?? .default
        bubbleCheckbox.state = methods.contains(.bubble) ? .on : .off
        alertCheckbox.state = methods.contains(.alert) ? .on : .off

        bodyField.stringValue = reminder?.body ?? ""
    }

    /// 组装成 Reminder；时长为 0 这类非法输入返回 nil（调用方会 beep）
    func makeReminder(basedOn reminder: Reminder?) -> Reminder? {
        let body = bodyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = reminder ?? Reminder(body: "", hour: 9, minute: 0)
        result.body = body.isEmpty ? "提醒" : body
        result.title = result.body
        result.methods = selectedMethods

        guard typeControl.selectedSegment != 1 else {
            let seconds = intValue(hoursField) * 3_600 + intValue(minutesField) * 60 + intValue(secondsField)
            guard seconds > 0 else { return nil }

            result.kind = .countdown
            result.countdownSeconds = seconds
            result.repeatsCountdown = repeatCountdownCheckbox.state == .on
            // 新的一条、或者勾了「从现在重新计时」才重新起算；否则保留原本的进度
            if reminder?.kind != .countdown || restartCheckbox.state == .on {
                result.countdownStartedAt = Date()
            }
            return result
        }

        let parts = TradingSession.calendar.dateComponents(
            [.hour, .minute, .second],
            from: timePicker.dateValue
        )
        guard let hour = parts.hour, let minute = parts.minute else { return nil }

        result.kind = .scheduled
        result.hour = hour
        result.minute = minute
        result.second = parts.second ?? 0
        result.skipHolidays = skipHolidaysCheckbox.state == .on

        switch repeatPopup.indexOfSelectedItem {
        case 1: result.repeatRule = .weekly(weekday: weekdayPopup.indexOfSelectedItem + 1)
        case 2: result.repeatRule = .monthly(day: monthDayPopup.indexOfSelectedItem + 1)
        case 3: result.repeatRule = .everyDays(interval: max(1, Int(dayIntervalField.stringValue) ?? 2))
        default: result.repeatRule = .daily
        }

        // 「每 N 天」需要起算日：新建时写今天，编辑时保持原值
        if result.anchorDay.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TradingSession.timeZone
            result.anchorDay = formatter.string(from: Date())
        }
        // 由倒计时改回定时的，把计时状态清干净，免得留下「还在跑」的残影
        result.countdownStartedAt = nil
        return result
    }

    private var selectedMethods: Reminder.Methods {
        var methods: Reminder.Methods = []
        if bubbleCheckbox.state == .on { methods.insert(.bubble) }
        if alertCheckbox.state == .on { methods.insert(.alert) }
        // 两个都不勾就没法提醒了。界面上本来就取消不掉（见 methodChanged），
        // 这里再兜一层，保证存进去的提醒永远至少有一种提醒方式
        return methods.isEmpty ? .bubble : methods
    }

    private func intValue(_ field: NSTextField) -> Int {
        max(0, Int(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
    }

    // MARK: - 交互

    @objc private func typeChanged() {
        updateVisibility()
    }

    @objc private func repeatChanged() {
        updateVisibility()
    }

    /// 两种提醒方式至少留一种：把刚被取消的那个弹回去
    @objc private func methodChanged(_ sender: NSButton) {
        if bubbleCheckbox.state == .off, alertCheckbox.state == .off {
            sender.state = .on
        }
    }

    private func updateVisibility() {
        let isCountdown = typeControl.selectedSegment == 1

        timePicker.isHidden = isCountdown
        repeatPopup.isHidden = isCountdown
        let repeatIndex = repeatPopup.indexOfSelectedItem
        weekdayPopup.isHidden = isCountdown || repeatIndex != 1
        monthDayPopup.isHidden = isCountdown || repeatIndex != 2
        dayIntervalLabel.isHidden = isCountdown || repeatIndex != 3
        dayIntervalField.isHidden = isCountdown || repeatIndex != 3
        skipHolidaysCheckbox.isHidden = isCountdown

        for view in [hoursField, minutesField, secondsField, hoursUnit, minutesUnit, secondsUnit] as [NSView] {
            view.isHidden = !isCountdown
        }
        repeatCountdownCheckbox.isHidden = !isCountdown
        // 「从现在重新计时」只对已经在跑的倒计时才有意义
        restartCheckbox.isHidden = !(isCountdown && editingCountdown)

        // 同一个行位置换了含义，行标签也跟着换
        timeLabel.stringValue = isCountdown ? "时长" : "时间"
        repeatLabel.stringValue = isCountdown ? "" : "重复"
    }
}
