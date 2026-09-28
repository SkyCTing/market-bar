import AppKit

@MainActor
final class StockTrendPlot: NSView {
    var trend: StockTrend? {
        didSet {
            segments = trend?.segments ?? []
            hovered = nil
            needsDisplay = true
        }
    }
    var onHover: ((StockTrendPoint?) -> Void)?
    private var hovered: StockTrendPoint?
    private var segments: [[StockTrendPoint]] = []
    private let left: CGFloat = 52
    private let right: CGFloat = 10
    private let bottom: CGFloat = 21
    private let top: CGFloat = 10

    private var plot: NSRect {
        NSRect(x: left, y: bottom, width: max(1, bounds.width - left - right),
               height: max(1, bounds.height - bottom - top))
    }

    func updateHover(at point: NSPoint) {
        guard let trend, plot.contains(point), let first = trend.points.first,
              let last = trend.points.last else {
            setHovered(nil)
            return
        }
        let duration = max(1, last.date.timeIntervalSince(first.date))
        let time = first.date.addingTimeInterval(
            duration * Double((point.x - plot.minX) / plot.width)
        )
        let tolerance = trend.range.isDailyClose
            ? 14 * 3_600 : min(15 * 60, max(90, duration / plot.width * 7))
        let nearest = trend.nearest(at: time)
        setHovered(nearest.flatMap { abs($0.date.timeIntervalSince(time)) <= tolerance ? $0 : nil })
    }

    private func setHovered(_ point: StockTrendPoint?) {
        guard hovered != point else { return }
        hovered = point
        onHover?(point)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let trend, let high = trend.high, let low = trend.low,
              let first = trend.points.first, let last = trend.points.last else { return }
        let span = max(high.price - low.price, high.price * 0.002, 0.01)
        let minPrice = low.price - span * 0.1
        let priceRange = span * 1.2
        let duration = max(1, last.date.timeIntervalSince(first.date))
        func location(_ item: StockTrendPoint) -> NSPoint {
            NSPoint(
                x: plot.minX + plot.width * CGFloat(item.date.timeIntervalSince(first.date) / duration),
                y: plot.minY + plot.height * CGFloat((item.price - minPrice) / priceRange)
            )
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        for step in 0...2 {
            let y = plot.minY + plot.height * CGFloat(step) / 2
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: y))
            line.line(to: NSPoint(x: plot.maxX, y: y))
            line.lineWidth = 0.5
            NSColor.white.withAlphaComponent(0.12).setStroke()
            line.stroke()
            (String(format: "%.2f", minPrice + priceRange * Double(step) / 2) as NSString).draw(
                at: NSPoint(x: 1, y: y - 5),
                withAttributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
            )
        }
        let pathColor = NSColor(calibratedRed: 0.92, green: 0.7, blue: 0.34, alpha: 1)
        for segment in segments {
            let path = NSBezierPath()
            for (index, item) in segment.enumerated() {
                if index == 0 { path.move(to: location(item)) }
                else { path.line(to: location(item)) }
            }
            path.lineWidth = 1.5
            pathColor.setStroke()
            path.stroke()
            if segment.count == 1 {
                let p = location(segment[0])
                pathColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)).fill()
            }
        }
        let formatter = DateFormatter()
        formatter.timeZone = trend.market == .hongKong
            ? TimeZone(identifier: "Asia/Hong_Kong") : TradingSession.timeZone
        formatter.dateFormat = trend.range.isDailyClose ? "MM/dd" : "MM/dd HH:mm"
        for (date, x) in [(first.date, plot.minX), (last.date, plot.maxX)] {
            let label = formatter.string(from: date) as NSString
            let width = label.size(withAttributes: [.font: font]).width
            label.draw(at: NSPoint(x: x == plot.minX ? x : x - width, y: 2),
                       withAttributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        }
        if let hovered {
            let p = location(hovered)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill()
        }
    }
}

private final class StockTrendPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class StockTrendPopover {
    private let window: StockTrendPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let rangeControl = NSSegmentedControl()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let plot = StockTrendPlot()
    var onRangeChange: (() -> Void)?
    private(set) var code: String?
    var range: StockTrendRange { StockTrendRange(rawValue: rangeControl.selectedSegment) ?? .today }
    var frame: NSRect { window.frame }
    var isVisible: Bool { window.isVisible }

    init() {
        window = StockTrendPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 215),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.level = .popUpMenu
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.acceptsMouseMovedEvents = true
        let content = NSView()
        content.appearance = NSAppearance(named: .darkAqua)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 0.98).cgColor
        content.layer?.cornerRadius = 10
        content.layer?.masksToBounds = true
        content.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        content.layer?.borderWidth = 0.5
        window.contentView = content
        content.widthAnchor.constraint(equalToConstant: 360).isActive = true
        content.heightAnchor.constraint(equalToConstant: 215).isActive = true

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.identifier = NSUserInterfaceItemIdentifier("stockTrendTitle")
        summaryLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        summaryLabel.identifier = NSUserInterfaceItemIdentifier("stockTrendSummary")
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.identifier = NSUserInterfaceItemIdentifier("stockTrendDetail")
        detailLabel.lineBreakMode = .byTruncatingTail
        rangeControl.segmentCount = StockTrendRange.allCases.count
        rangeControl.appearance = NSAppearance(named: .darkAqua)
        for range in StockTrendRange.allCases { rangeControl.setLabel(range.title, forSegment: range.rawValue) }
        rangeControl.selectedSegment = StockTrendRange.today.rawValue
        rangeControl.controlSize = .small
        rangeControl.target = self
        rangeControl.action = #selector(changeRange)
        plot.onHover = { [weak self] point in self?.showDetail(point) }

        for view in [titleLabel, summaryLabel, detailLabel, rangeControl, plot] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: rangeControl.leadingAnchor, constant: -6),
            rangeControl.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            rangeControl.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            summaryLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            plot.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            plot.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            plot.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 7),
            plot.bottomAnchor.constraint(equalTo: detailLabel.topAnchor, constant: -5),
            detailLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            detailLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            detailLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    func show(code: String, name: String, market: StockMarket, row: NSRect, alongside panel: NSRect) {
        if self.code != code { rangeControl.selectedSegment = StockTrendRange.today.rawValue }
        self.code = code
        titleLabel.stringValue = "\(name) · \(market == .hongKong ? "HK" : "A")"
        titleLabel.toolTip = "\(name) (\(code))"
        let size = window.frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(panel) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let gap: CGFloat = 5
        let x: CGFloat
        if panel.maxX + gap + size.width <= visible.maxX {
            x = panel.maxX + gap
        } else if panel.minX - gap - size.width >= visible.minX {
            x = panel.minX - gap - size.width
        } else {
            x = max(visible.minX, min(panel.maxX - size.width - 8, visible.maxX - size.width))
        }
        let y = max(visible.minY, min(row.midY - size.height / 2, visible.maxY - size.height))
        window.setFrameOrigin(NSPoint(x: x, y: y))
        window.orderFrontRegardless()
    }

    func showLoading() {
        plot.trend = nil
        summaryLabel.stringValue = "正在读取\(range.title)走势…"
        detailLabel.stringValue = "分时只画交易时段；日线未复权，今日可能尚未收盘"
    }

    func show(_ trend: StockTrend) {
        plot.trend = trend
        guard let high = trend.high, let low = trend.low, let latest = trend.latest else {
            summaryLabel.stringValue = "没有可用价格点"
            return
        }
        let type = trend.range.isDailyClose ? "日线" : "价格"
        summaryLabel.stringValue = String(format: "最高%@ %.2f · 最低%@ %.2f %@", type, high.price, type, low.price, trend.market.currency)
        let timestamp = trend.market.formattedQuoteTime(latest.date)
        detailLabel.stringValue = "\(trend.market.timeZoneName) · 截至 \(timestamp) · \(trend.points.count) 点"
        detailLabel.toolTip = detailLabel.stringValue
            + (trend.range.isDailyClose ? "；当日日线尚未收盘时是盘中暂值" : "")
    }

    func showError(_ error: Error) {
        plot.trend = nil
        summaryLabel.stringValue = "走势暂不可用"
        detailLabel.stringValue = error.localizedDescription
        detailLabel.toolTip = error.localizedDescription
    }

    func updateHover(at screenPoint: NSPoint) {
        let inWindow = window.convertFromScreen(NSRect(origin: screenPoint, size: .zero)).origin
        let point = plot.convert(inWindow, from: nil)
        plot.updateHover(at: point)
    }

    private func showDetail(_ point: StockTrendPoint?) {
        guard let trend = plot.trend else { return }
        guard let point else { show(trend); return }
        detailLabel.stringValue = String(
            format: "%@ %@ · %.2f %@", trend.market.timeZoneName,
            trend.market.formattedQuoteTime(point.date), point.price, trend.market.currency
        )
        detailLabel.toolTip = detailLabel.stringValue
    }

    @objc private func changeRange() { onRangeChange?() }

    func dismiss() {
        code = nil
        plot.trend = nil
        window.orderOut(nil)
    }
}
