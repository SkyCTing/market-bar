import AppKit

/// 提醒的配置表单（作为 NSAlert 的 accessory view）。
///
/// 比一个塞满 39 项的「重复」下拉框人性化：重复只留「每天 / 每周 / 每月」，
/// 选「每周」才出现周几、选「每月」才出现几号。时间用 DatePicker，精确到秒。
@MainActor
final class ReminderDialogView: NSView {
    private let timePicker = NSDatePicker()
    private let repeatPopup = NSPopUpButton()
    private let weekdayPopup = NSPopUpButton()
    private let monthDayPopup = NSPopUpButton()
    private let weekdayLabel = NSTextField(labelWithString: "周几")
    private let monthDayLabel = NSTextField(labelWithString: "几号")
    private let dayIntervalLabel = NSTextField(labelWithString: "天数")
    private let dayIntervalField = NSTextField()
    private let skipHolidaysCheckbox = NSButton(
        checkboxWithTitle: "智能跳过节假日（调休上班日照常提醒）",
        target: nil,
        action: nil
    )
    private let bodyField = NSTextField()

    private static let repeatTitles = ["每天", "每周", "每月", "每 N 天"]

    init(reminder: Reminder?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 158))

        func label(_ text: String, y: CGFloat) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.frame = NSRect(x: 0, y: y + 3, width: 44, height: 18)
            field.alignment = .right
            addSubview(field)
            return field
        }

        // ── 时间（时/分/秒）
        _ = label("时间", y: 124)
        timePicker.datePickerStyle = .textFieldAndStepper
        timePicker.datePickerElements = [.hourMinuteSecond]
        timePicker.datePickerMode = .single
        timePicker.frame = NSRect(x: 52, y: 122, width: 120, height: 24)
        addSubview(timePicker)

        // ── 重复
        _ = label("重复", y: 90)
        repeatPopup.frame = NSRect(x: 52, y: 88, width: 100, height: 25)
        repeatPopup.addItems(withTitles: Self.repeatTitles)
        repeatPopup.target = self
        repeatPopup.action = #selector(repeatChanged)
        addSubview(repeatPopup)

        weekdayLabel.frame = NSRect(x: 160, y: 93, width: 32, height: 18)
        weekdayLabel.alignment = .right
        addSubview(weekdayLabel)
        weekdayPopup.frame = NSRect(x: 196, y: 88, width: 100, height: 25)
        weekdayPopup.addItems(withTitles: ["周日", "周一", "周二", "周三", "周四", "周五", "周六"])
        addSubview(weekdayPopup)

        monthDayLabel.frame = NSRect(x: 160, y: 93, width: 32, height: 18)
        monthDayLabel.alignment = .right
        addSubview(monthDayLabel)
        monthDayPopup.frame = NSRect(x: 196, y: 88, width: 100, height: 25)
        monthDayPopup.addItems(withTitles: (1...31).map { "\($0) 号" })
        addSubview(monthDayPopup)

        dayIntervalLabel.frame = NSRect(x: 160, y: 93, width: 32, height: 18)
        dayIntervalLabel.alignment = .right
        addSubview(dayIntervalLabel)
        dayIntervalField.frame = NSRect(x: 196, y: 88, width: 60, height: 24)
        dayIntervalField.placeholderString = "N"
        dayIntervalField.stringValue = "2"
        addSubview(dayIntervalField)

        // ── 节假日开关
        skipHolidaysCheckbox.frame = NSRect(x: 52, y: 58, width: 300, height: 20)
        addSubview(skipHolidaysCheckbox)

        // ── 提醒内容
        _ = label("内容", y: 22)
        bodyField.frame = NSRect(x: 52, y: 20, width: 300, height: 24)
        bodyField.placeholderString = "例如：还信用卡"
        addSubview(bodyField)

        apply(reminder)
        updateConditionalControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var firstResponderControl: NSView { bodyField }

    private func apply(_ reminder: Reminder?) {
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
        bodyField.stringValue = reminder?.body ?? ""
    }

    @objc private func repeatChanged() {
        updateConditionalControls()
    }

    private func updateConditionalControls() {
        let index = repeatPopup.indexOfSelectedItem
        let weekly = index == 1
        let monthly = index == 2
        let everyDays = index == 3
        weekdayLabel.isHidden = !weekly
        weekdayPopup.isHidden = !weekly
        monthDayLabel.isHidden = !monthly
        monthDayPopup.isHidden = !monthly
        dayIntervalLabel.isHidden = !everyDays
        dayIntervalField.isHidden = !everyDays
    }

    /// 组装成 Reminder；时间非法时返回 nil
    func makeReminder(basedOn reminder: Reminder?) -> Reminder? {
        let parts = TradingSession.calendar.dateComponents(
            [.hour, .minute, .second],
            from: timePicker.dateValue
        )
        guard let hour = parts.hour, let minute = parts.minute else { return nil }

        let repeatRule: Reminder.Repeat
        switch repeatPopup.indexOfSelectedItem {
        case 1: repeatRule = .weekly(weekday: weekdayPopup.indexOfSelectedItem + 1)
        case 2: repeatRule = .monthly(day: monthDayPopup.indexOfSelectedItem + 1)
        case 3: repeatRule = .everyDays(interval: max(1, Int(dayIntervalField.stringValue) ?? 2))
        default: repeatRule = .daily
        }

        let body = bodyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = reminder ?? Reminder(body: "", hour: hour, minute: minute)
        result.hour = hour
        result.minute = minute
        result.second = parts.second ?? 0
        result.repeatRule = repeatRule
        result.skipHolidays = skipHolidaysCheckbox.state == .on
        result.body = body.isEmpty ? "提醒" : body
        result.title = result.body
        // 「每 N 天」需要起算日：新建时写今天，编辑时保持原值
        if result.anchorDay.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TradingSession.timeZone
            result.anchorDay = formatter.string(from: Date())
        }
        return result
    }
}
