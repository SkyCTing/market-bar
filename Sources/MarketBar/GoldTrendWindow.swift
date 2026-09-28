import AppKit

@MainActor
final class GoldTrendChart: NSView {
    var trend: GoldTrend? {
        didSet {
            hovered = nil
            cachedSegments = nil
            if let low = trend?.low, let high = trend?.high {
                extrema = (low, high)
            } else {
                extrema = nil
            }
            needsDisplay = true
        }
    }
    var onHover: ((GoldHistorySample?) -> Void)?
    private(set) var hovered: GoldHistorySample?
    private var cachedSegments: [[GoldHistorySample]]?
    private var cachedWidth: CGFloat = 0
    private var extrema: (low: GoldHistorySample, high: GoldHistorySample)?
    private let accent = NSColor(calibratedRed: 0.88, green: 0.63, blue: 0.29, alpha: 1)
    private let inset = NSEdgeInsets(top: 25, left: 66, bottom: 33, right: 22)

    override var isFlipped: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize.width != frame.width {
            cachedSegments = nil
        }
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    private var plot: NSRect {
        NSRect(
            x: inset.left, y: inset.bottom,
            width: max(1, bounds.width - inset.left - inset.right),
            height: max(1, bounds.height - inset.top - inset.bottom)
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let trend, plot.contains(point), !trend.samples.isEmpty else {
            if hovered != nil { hovered = nil; onHover?(nil); needsDisplay = true }
            return
        }
        let duration = trend.end.timeIntervalSince(trend.start)
        let date = trend.start.addingTimeInterval(duration * Double((point.x - plot.minX) / plot.width))
        let nearest = trend.nearest(to: date)
        let tolerance = min(15 * 60, max(90, duration / plot.width * 8))
        let sample = nearest.flatMap { abs($0.sampledAt.timeIntervalSince(date)) <= tolerance ? $0 : nil }
        if sample != hovered {
            hovered = sample
            onHover?(sample)
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil { hovered = nil; onHover?(nil); needsDisplay = true }
    }

    private func coordinates(_ sample: GoldHistorySample, range: ClosedRange<Double>, trend: GoldTrend) -> NSPoint {
        let duration = max(1, trend.end.timeIntervalSince(trend.start))
        let width = max(0.001, range.upperBound - range.lowerBound)
        return NSPoint(
            x: plot.minX + plot.width * CGFloat(sample.sampledAt.timeIntervalSince(trend.start) / duration),
            y: plot.minY + plot.height * CGFloat((sample.price - range.lowerBound) / width)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSBezierPath(rect: bounds).fill()
        guard let trend, let (low, high) = extrema else { return }
        let span = max(high.price - low.price, high.price * 0.002, 0.01)
        let range = (low.price - span * 0.12)...(high.price + span * 0.12)
        let grid = NSColor.white.withAlphaComponent(0.13)
        for tick in 0...4 {
            let y = plot.minY + plot.height * CGFloat(tick) / 4
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: y))
            line.line(to: NSPoint(x: plot.maxX, y: y))
            line.lineWidth = 0.5
            grid.setStroke()
            line.stroke()
            let price = range.lowerBound + (range.upperBound - range.lowerBound) * Double(tick) / 4
            let label = String(format: "%.2f", price)
            (label as NSString).draw(
                at: NSPoint(x: 10, y: y - 6),
                withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                 .foregroundColor: NSColor.secondaryLabelColor]
            )
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm"
        for (date, x) in [(trend.start, plot.minX), (trend.end, plot.maxX)] {
            let label = formatter.string(from: date) as NSString
            let width = label.size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width
            label.draw(
                at: NSPoint(x: x == plot.minX ? x : x - width, y: 8),
                withAttributes: [.font: NSFont.systemFont(ofSize: 10),
                                 .foregroundColor: NSColor.secondaryLabelColor]
            )
        }

        if cachedSegments == nil || cachedWidth != plot.width {
            cachedSegments = trend.drawingSegments(buckets: max(100, Int(plot.width)))
            cachedWidth = plot.width
        }
        let segments = cachedSegments ?? []
        for segment in segments {
            let path = NSBezierPath()
            for (index, sample) in segment.enumerated() {
                let point = coordinates(sample, range: range, trend: trend)
                if index == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            path.lineWidth = 1.8
            path.lineJoinStyle = .round
            accent.setStroke()
            path.stroke()
            if segment.count == 1 {
                let point = coordinates(segment[0], range: range, trend: trend)
                NSBezierPath(ovalIn: NSRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)).fill()
            }
        }
        for (sample, color) in [(low, NSColor.systemTeal), (high, NSColor.systemOrange)] {
            let point = coordinates(sample, range: range, trend: trend)
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
        }
        if let hovered {
            let point = coordinates(hovered, range: range, trend: trend)
            let marker = NSBezierPath()
            marker.move(to: NSPoint(x: point.x, y: plot.minY))
            marker.line(to: NSPoint(x: point.x, y: plot.maxY))
            marker.lineWidth = 1
            NSColor.white.withAlphaComponent(0.5).setStroke()
            marker.stroke()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)).fill()
        }
    }
}

@MainActor
final class GoldTrendWindowController: NSObject, NSWindowDelegate {
    typealias Load = (GoldProvider, Date, Date) async throws -> GoldTrend
    private let load: Load
    private let window: NSWindow
    private let providerPicker = NSPopUpButton()
    private let rangePicker = NSSegmentedControl()
    private let startPicker = NSDatePicker()
    private let endPicker = NSDatePicker()
    private let startLabel = NSTextField(labelWithString: "起")
    private let endLabel = NSTextField(labelWithString: "止")
    private let chart = GoldTrendChart()
    private let summary = NSTextField(labelWithString: "请选择银行与时间范围")
    private let detail = NSTextField(labelWithString: "鼠标移到折线上查看时间和价格")
    private var loadTask: Task<Void, Never>?
    private var refreshTimer: Timer?
    private var generation = UUID()

    init(load: @escaping Load) {
        self.load = load
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 510),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.title = "金价走势"
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 600, height: 400)
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self
        buildView()
    }

    var isVisible: Bool { window.isVisible }

    func show(provider: GoldProvider) {
        providerPicker.selectItem(at: GoldProvider.allCases.firstIndex(of: provider) ?? 0)
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        refresh()
        if refreshTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.window.isVisible else { return }
                    self.refresh()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            refreshTimer = timer
        }
    }

    func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        generation = UUID()
        loadTask?.cancel()
        loadTask = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func buildView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.15, alpha: 1).cgColor
        window.contentView = root
        if let (start, end) = try? GoldTrendRange.week.dates(now: Date()) {
            startPicker.dateValue = start
            endPicker.dateValue = end
        }

        providerPicker.addItems(withTitles: GoldProvider.allCases.map(\.displayName))
        providerPicker.target = self
        providerPicker.action = #selector(refresh)
        rangePicker.segmentCount = GoldTrendRange.allCases.count
        for (index, range) in GoldTrendRange.allCases.enumerated() {
            rangePicker.setLabel(range.title, forSegment: index)
        }
        rangePicker.selectedSegment = GoldTrendRange.week.rawValue
        rangePicker.target = self
        rangePicker.action = #selector(rangeChanged)
        for picker in [startPicker, endPicker] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = [.yearMonthDay, .hourMinute]
            picker.target = self
            picker.action = #selector(refresh)
            picker.isHidden = true
        }
        startLabel.isHidden = true
        endLabel.isHidden = true
        let refreshButton = NSButton(title: "刷新", target: self, action: #selector(refresh))
        summary.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        chart.wantsLayer = true
        chart.layer?.cornerRadius = 8
        chart.onHover = { [weak self] sample in self?.displayDetail(sample) }

        let controls = [providerPicker, rangePicker, startPicker, endPicker,
                        startLabel, endLabel, refreshButton, summary, detail, chart]
        for control in controls {
            control.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(control)
        }
        NSLayoutConstraint.activate([
            providerPicker.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            providerPicker.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            providerPicker.widthAnchor.constraint(equalToConstant: 160),
            rangePicker.leadingAnchor.constraint(equalTo: providerPicker.trailingAnchor, constant: 12),
            rangePicker.centerYAnchor.constraint(equalTo: providerPicker.centerYAnchor),
            rangePicker.trailingAnchor.constraint(lessThanOrEqualTo: refreshButton.leadingAnchor, constant: -10),
            refreshButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            refreshButton.centerYAnchor.constraint(equalTo: providerPicker.centerYAnchor),
            startLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            startLabel.topAnchor.constraint(equalTo: providerPicker.bottomAnchor, constant: 15),
            startPicker.leadingAnchor.constraint(equalTo: startLabel.trailingAnchor, constant: 5),
            startPicker.centerYAnchor.constraint(equalTo: startLabel.centerYAnchor),
            endLabel.leadingAnchor.constraint(equalTo: startPicker.trailingAnchor, constant: 14),
            endLabel.centerYAnchor.constraint(equalTo: startPicker.centerYAnchor),
            endPicker.leadingAnchor.constraint(equalTo: endLabel.trailingAnchor, constant: 5),
            endPicker.centerYAnchor.constraint(equalTo: endLabel.centerYAnchor),
            endPicker.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            summary.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            summary.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            summary.topAnchor.constraint(equalTo: startLabel.bottomAnchor, constant: 12),
            chart.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            chart.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            chart.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 12),
            chart.bottomAnchor.constraint(equalTo: detail.topAnchor, constant: -12),
            detail.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            detail.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            detail.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -17),
        ])
    }

    @objc private func rangeChanged() {
        let custom = rangePicker.selectedSegment == GoldTrendRange.custom.rawValue
        startLabel.isHidden = !custom
        endLabel.isHidden = !custom
        startPicker.isHidden = !custom
        endPicker.isHidden = !custom
        refresh()
    }

    @objc private func refresh() {
        generation = UUID()
        let token = generation
        loadTask?.cancel()
        guard let provider = GoldProvider.allCases[safe: providerPicker.indexOfSelectedItem],
              let range = GoldTrendRange(rawValue: rangePicker.selectedSegment) else { return }
        let dates: (Date, Date)
        do {
            dates = try range.dates(
                now: Date(), customStart: startPicker.dateValue, customEnd: endPicker.dateValue
            )
        } catch {
            chart.trend = nil
            summary.stringValue = error.localizedDescription
            detail.stringValue = "请检查起止时间（最长一年）"
            return
        }
        summary.stringValue = "正在读取 \(provider.displayName) 的本地记录…"
        detail.stringValue = "断档不补线；报价仅供参考"
        chart.trend = nil
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let trend = try await load(provider, dates.0, dates.1)
                guard !Task.isCancelled, generation == token else { return }
                chart.trend = trend
                updateSummary(trend)
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                summary.stringValue = "读取历史记录失败：\(error.localizedDescription)"
                detail.stringValue = "数据库文件未修改；请检查访问权限和磁盘状态"
            }
        }
    }

    private func updateSummary(_ trend: GoldTrend) {
        guard let high = trend.high, let low = trend.low else {
            summary.stringValue = "所选时间内暂无 \(trend.provider.displayName) 的记录"
            detail.stringValue = "记录从 1.0.19 安装后开始积累；未运行或接口失败的分钟不会补数据"
            return
        }
        summary.stringValue = String(
            format: "%@ · %ld 条 · 最高 ¥%.2f · 最低 ¥%.2f（元/克）",
            trend.provider.displayName, trend.samples.count, high.price, low.price
        )
        detail.stringValue = "鼠标移到折线上看采集时间；空白区表示尚未采集或间断，不代表价格不变"
    }

    private func displayDetail(_ sample: GoldHistorySample?) {
        guard let sample else {
            if let trend = chart.trend { updateSummary(trend) }
            return
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        detail.stringValue = String(format: "%@ · %@ · ¥%.2f / 克",
                                    sample.provider.displayName, formatter.string(from: sample.sampledAt), sample.price)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
