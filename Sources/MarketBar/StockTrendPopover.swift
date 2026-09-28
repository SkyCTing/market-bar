import AppKit

@MainActor
final class StockTrendPlot: NSView {
    var decimalPlaces = 2 { didSet { needsDisplay = true } }
    var trend: StockTrend? {
        didSet {
            segments = trend?.segments ?? []
            positions = trend?.plotFractions ?? []
            positionsByDate = [:]
            if let trend, positions.count == trend.points.count {
                for (point, position) in zip(trend.points, positions) {
                    positionsByDate[point.date] = position
                }
            }
            hovered = nil
            needsDisplay = true
        }
    }
    var onHover: ((StockTrendPoint?) -> Void)?
    private var hovered: StockTrendPoint?
    private var segments: [[StockTrendPoint]] = []
    private var positions: [Double] = []
    private var positionsByDate: [Date: Double] = [:]
    private let left: CGFloat = 52
    private let right: CGFloat = 10
    private let bottom: CGFloat = 21
    private let top: CGFloat = 10

    private var plot: NSRect {
        NSRect(x: left, y: bottom, width: max(1, bounds.width - left - right),
               height: max(1, bounds.height - bottom - top))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        updateHover(at: NSPoint(x: -1, y: -1))
    }

    func updateHover(at point: NSPoint) {
        guard let trend, plot.contains(point), positions.count == trend.points.count,
              !positions.isEmpty else {
            setHovered(nil)
            return
        }
        let fraction = Double((point.x - plot.minX) / plot.width)
        var low = 0
        var high = positions.count
        while low < high {
            let middle = (low + high) / 2
            if positions[middle] < fraction { low = middle + 1 }
            else { high = middle }
        }
        let index: Int
        if low == 0 { index = 0 }
        else if low == positions.count { index = low - 1 }
        else { index = fraction - positions[low - 1] <= positions[low] - fraction ? low - 1 : low }
        let distance = abs(positions[index] - fraction) * Double(plot.width)
        setHovered(distance <= 8 ? trend.points[index] : nil)
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
              let first = trend.points.first, let last = trend.points.last,
              positions.count == trend.points.count else { return }
        let upper = trend.range.isCandlestick ? trend.highestCandle?.high ?? high.price : high.price
        let lower = trend.range.isCandlestick ? trend.lowestCandle?.low ?? low.price : low.price
        let span = max(upper - lower, upper * 0.002, pow(10, -Double(decimalPlaces)))
        let minPrice = lower - span * 0.1
        let priceRange = span * 1.2
        func y(_ price: Double) -> CGFloat {
            plot.minY + plot.height * CGFloat((price - minPrice) / priceRange)
        }
        func location(_ item: StockTrendPoint) -> NSPoint? {
            guard let fraction = positionsByDate[item.date] else {
                NSLog("MarketBar: stock chart point missing from trading-time axis")
                return nil
            }
            return NSPoint(
                x: plot.minX + plot.width * CGFloat(fraction),
                y: y(item.price)
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
            (StockTrendPriceFormat.text(minPrice + priceRange * Double(step) / 2,
                                        decimalPlaces: decimalPlaces) as NSString).draw(
                at: NSPoint(x: 1, y: y - 5),
                withAttributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
            )
        }
        if trend.range.isCandlestick {
            guard trend.candles.count == trend.points.count else { return }
            let width = min(14, max(3, plot.width / CGFloat(trend.candles.count) * 0.65))
            for bar in trend.candles {
                guard let fraction = positionsByDate[bar.date] else { return }
                let x = plot.minX + plot.width * CGFloat(fraction)
                let color = bar.close > bar.open ? NSColor.systemRed
                    : bar.close < bar.open ? NSColor.systemGreen : NSColor.systemGray
                color.setStroke()
                let wick = NSBezierPath()
                wick.move(to: NSPoint(x: x, y: y(bar.low)))
                wick.line(to: NSPoint(x: x, y: y(bar.high)))
                wick.lineWidth = 1
                wick.stroke()
                color.setFill()
                let height = abs(y(bar.close) - y(bar.open))
                NSBezierPath(rect: NSRect(
                    x: x - width / 2, y: min(y(bar.open), y(bar.close)),
                    width: width, height: max(1.5, height)
                )).fill()
            }
        } else {
            let pathColor = NSColor(calibratedRed: 0.92, green: 0.7, blue: 0.34, alpha: 1)
            for segment in segments {
                let path = NSBezierPath()
                for (index, item) in segment.enumerated() {
                    guard let position = location(item) else { return }
                    if index == 0 { path.move(to: position) }
                    else { path.line(to: position) }
                }
                path.lineWidth = 1.5
                pathColor.setStroke()
                path.stroke()
                if segment.count == 1 {
                    guard let p = location(segment[0]) else { return }
                    pathColor.setFill()
                    NSBezierPath(ovalIn: NSRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)).fill()
                }
            }
        }
        let formatter = DateFormatter()
        formatter.timeZone = trend.market == .hongKong
            ? TimeZone(identifier: "Asia/Hong_Kong") : TradingSession.timeZone
        formatter.dateFormat = trend.range.usesPeriodBars ? "MM/dd" : "MM/dd HH:mm"
        for (date, x) in [(first.date, plot.minX), (last.date, plot.maxX)] {
            let label = formatter.string(from: date) as NSString
            let width = label.size(withAttributes: [.font: font]).width
            label.draw(at: NSPoint(x: x == plot.minX ? x : x - width, y: 2),
                       withAttributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        }
        if let hovered {
            guard let p = location(hovered) else { return }
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
    private static let inlineRanges: [StockTrendRange] = [.today, .fiveDays, .month]
    private static let kRanges: [StockTrendRange] = [.dailyCandles, .weeklyCandles, .monthlyCandles]
    private let window: StockTrendPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let latestPriceLabel = NSTextField(labelWithString: "")
    private let klineButton = NSButton(title: "放大", target: nil, action: nil)
    private let lineTitle = NSTextField(labelWithString: "价格折线")
    private let kTitle = NSTextField(labelWithString: "蜡烛 K 线")
    private let separator = NSView()
    private let rangeControl = NSSegmentedControl()
    private let kRangeControl = NSSegmentedControl()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let kSummaryLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "上方看价格折线 · 下方看开高低收蜡烛")
    private let plot = StockTrendPlot()
    private let kPlot = StockTrendPlot()
    private var decimalPlaces = 2
    var onRangeChange: (() -> Void)?
    var onKRangeChange: (() -> Void)?
    var onOpenKline: ((StockQuote) -> Void)?
    private var latestQuote: StockQuote?
    private(set) var code: String?
    var range: StockTrendRange {
        let index = rangeControl.selectedSegment
        return Self.inlineRanges.indices.contains(index) ? Self.inlineRanges[index] : .today
    }
    var kRange: StockTrendRange {
        let index = kRangeControl.selectedSegment
        return Self.kRanges.indices.contains(index) ? Self.kRanges[index] : .dailyCandles
    }
    var frame: NSRect { window.frame }
    var isVisible: Bool { window.isVisible }

    init() {
        window = StockTrendPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
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
        content.heightAnchor.constraint(equalToConstant: 420).isActive = true

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.identifier = NSUserInterfaceItemIdentifier("stockTrendTitle")
        latestPriceLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        latestPriceLabel.identifier = NSUserInterfaceItemIdentifier("stockTrendLatestPrice")
        klineButton.isBordered = false
        klineButton.font = .systemFont(ofSize: 11, weight: .semibold)
        klineButton.contentTintColor = .secondaryLabelColor
        klineButton.toolTip = "可选：在独立窗口放大 K 线"
        klineButton.identifier = NSUserInterfaceItemIdentifier("openStockKline")
        klineButton.target = self
        klineButton.action = #selector(openKline)
        for label in [lineTitle, kTitle] {
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = NSColor(calibratedRed: 0.94, green: 0.72, blue: 0.34, alpha: 1)
        }
        summaryLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        summaryLabel.identifier = NSUserInterfaceItemIdentifier("stockTrendSummary")
        kSummaryLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        kSummaryLabel.identifier = NSUserInterfaceItemIdentifier("stockKlineSummary")
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.identifier = NSUserInterfaceItemIdentifier("stockTrendDetail")
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.toolTip = "休市时间已压缩；未收盘的 K 线为暂值"
        rangeControl.segmentCount = Self.inlineRanges.count
        rangeControl.identifier = NSUserInterfaceItemIdentifier("stockLineRange")
        rangeControl.appearance = NSAppearance(named: .darkAqua)
        for (index, range) in Self.inlineRanges.enumerated() {
            rangeControl.setLabel(range.title, forSegment: index)
        }
        rangeControl.selectedSegment = StockTrendRange.today.rawValue
        rangeControl.controlSize = .small
        rangeControl.target = self
        rangeControl.action = #selector(changeRange)
        kRangeControl.segmentCount = Self.kRanges.count
        kRangeControl.identifier = NSUserInterfaceItemIdentifier("stockKRange")
        kRangeControl.appearance = NSAppearance(named: .darkAqua)
        for (index, range) in Self.kRanges.enumerated() {
            kRangeControl.setLabel(range.title, forSegment: index)
        }
        kRangeControl.selectedSegment = 0
        kRangeControl.controlSize = .small
        kRangeControl.target = self
        kRangeControl.action = #selector(changeKRange)
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.17).cgColor
        plot.identifier = NSUserInterfaceItemIdentifier("stockLinePlot")
        kPlot.identifier = NSUserInterfaceItemIdentifier("stockKPlot")
        plot.onHover = { [weak self] point in self?.showLineDetail(point) }
        kPlot.onHover = { [weak self] point in self?.showKDetail(point) }

        for view in [titleLabel, latestPriceLabel, klineButton, lineTitle, rangeControl, plot,
                     summaryLabel, separator, kTitle, kRangeControl, kPlot, kSummaryLabel, detailLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            latestPriceLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
            latestPriceLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            latestPriceLabel.trailingAnchor.constraint(lessThanOrEqualTo: klineButton.leadingAnchor, constant: -8),
            klineButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            klineButton.centerYAnchor.constraint(equalTo: latestPriceLabel.centerYAnchor),
            lineTitle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            lineTitle.topAnchor.constraint(equalTo: latestPriceLabel.bottomAnchor, constant: 9),
            rangeControl.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            rangeControl.centerYAnchor.constraint(equalTo: lineTitle.centerYAnchor),
            summaryLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            plot.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            plot.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            plot.topAnchor.constraint(equalTo: lineTitle.bottomAnchor, constant: 5),
            plot.bottomAnchor.constraint(equalTo: summaryLabel.topAnchor, constant: -5),
            separator.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 9),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
            kTitle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            kTitle.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 9),
            kRangeControl.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            kRangeControl.centerYAnchor.constraint(equalTo: kTitle.centerYAnchor),
            kPlot.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            kPlot.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            kPlot.topAnchor.constraint(equalTo: kTitle.bottomAnchor, constant: 5),
            kPlot.bottomAnchor.constraint(equalTo: kSummaryLabel.topAnchor, constant: -5),
            kSummaryLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            kSummaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            kSummaryLabel.bottomAnchor.constraint(equalTo: detailLabel.topAnchor, constant: -8),
            detailLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            detailLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            detailLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            plot.heightAnchor.constraint(equalTo: kPlot.heightAnchor),
            plot.heightAnchor.constraint(greaterThanOrEqualToConstant: 85),
        ])
    }

    func show(code: String, name: String, market: StockMarket, quote: StockQuote,
              row: NSRect, alongside panel: NSRect) {
        if self.code != code {
            rangeControl.selectedSegment = 0
            kRangeControl.selectedSegment = 0
        }
        self.code = code
        titleLabel.stringValue = "\(name) · \(market == .hongKong ? "HK" : "A")"
        titleLabel.toolTip = "\(name) (\(code))"
        klineButton.isHidden = code.hasPrefix("bj")
        updateQuote(quote, market: market)
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

    func updateQuote(_ quote: StockQuote, market: StockMarket) {
        latestQuote = quote
        latestPriceLabel.stringValue = "最近价格 \(quote.price) \(market.currency)"
        latestPriceLabel.toolTip = quote.quotedAt.map {
            "报价时间：\(market.formattedQuoteTime($0))（\(market.timeZoneName)）"
        } ?? "报价时间未知"
        let precision = StockTrendPriceFormat.decimalPlaces(for: quote)
        guard decimalPlaces != precision else { return }
        decimalPlaces = precision
        plot.decimalPlaces = precision
        kPlot.decimalPlaces = precision
        if let trend = plot.trend { showLine(trend) }
        if let trend = kPlot.trend { showK(trend) }
    }

    func showLineLoading() {
        plot.trend = nil
        summaryLabel.stringValue = "正在读取\(range.title)走势…"
        showDefaultDetail()
    }

    func showKLoading() {
        kPlot.trend = nil
        kSummaryLabel.stringValue = "正在读取\(kRange.title)…"
        showDefaultDetail()
    }

    func showLine(_ trend: StockTrend) {
        plot.trend = trend
        guard let high = trend.high, let low = trend.low, let latest = trend.latest else {
            summaryLabel.stringValue = "没有可用价格点"
            return
        }
        let type = trend.range.isDailyClose ? "日线" : "价格"
        summaryLabel.stringValue = String(
            format: "最高%@ %@ · 最低%@ %@ %@", type,
            StockTrendPriceFormat.text(high.price, decimalPlaces: decimalPlaces), type,
            StockTrendPriceFormat.text(low.price, decimalPlaces: decimalPlaces), trend.market.currency
        )
        let timestamp = trend.market.formattedQuoteTime(latest.date)
        summaryLabel.toolTip = "\(trend.market.timeZoneName) · 截至 \(timestamp) · \(trend.points.count) 点 · 休市时段已压缩"
    }

    func showK(_ trend: StockTrend) {
        guard trend.range.isCandlestick, let high = trend.highestCandle, let low = trend.lowestCandle,
              let latest = trend.candles.last else {
            showKError(StockTrendError.unavailable("没有完整的开高低收数据"))
            return
        }
        kPlot.trend = trend
        kSummaryLabel.stringValue = String(
            format: "最高 %@ · 最低 %@ %@", StockTrendPriceFormat.text(high.high, decimalPlaces: decimalPlaces),
            StockTrendPriceFormat.text(low.low, decimalPlaces: decimalPlaces), trend.market.currency
        )
        kSummaryLabel.toolTip = "\(trend.range.title) · \(trend.candles.count) 根 · 截至 \(trend.market.dateString(for: latest.date)) · 未复权；当前周期未结束时为暂值"
    }

    func showLineError(_ error: Error) {
        plot.trend = nil
        summaryLabel.stringValue = "折线暂不可用（查看提示）"
        summaryLabel.toolTip = error.localizedDescription
    }

    func showKError(_ error: Error) {
        kPlot.trend = nil
        kSummaryLabel.stringValue = "K 线暂不可用（查看提示）"
        kSummaryLabel.toolTip = error.localizedDescription
    }

    func updateHover(at screenPoint: NSPoint) {
        let inWindow = window.convertFromScreen(NSRect(origin: screenPoint, size: .zero)).origin
        let linePoint = plot.convert(inWindow, from: nil)
        let kPoint = kPlot.convert(inWindow, from: nil)
        let outside = NSPoint(x: -1, y: -1)
        if plot.bounds.contains(linePoint) {
            kPlot.updateHover(at: outside)
            plot.updateHover(at: linePoint)
        } else if kPlot.bounds.contains(kPoint) {
            plot.updateHover(at: outside)
            kPlot.updateHover(at: kPoint)
        } else {
            plot.updateHover(at: outside)
            kPlot.updateHover(at: outside)
            showDefaultDetail()
        }
    }

    private func showLineDetail(_ point: StockTrendPoint?) {
        guard let trend = plot.trend else { return }
        guard let point else { showDefaultDetail(); return }
        detailLabel.stringValue = String(
            format: "%@ %@ · %@ %@", trend.market.timeZoneName,
            trend.market.formattedQuoteTime(point.date),
            StockTrendPriceFormat.text(point.price, decimalPlaces: decimalPlaces), trend.market.currency
        )
        detailLabel.toolTip = detailLabel.stringValue
    }

    private func showKDetail(_ point: StockTrendPoint?) {
        guard let trend = kPlot.trend else { return }
        guard let point else { showDefaultDetail(); return }
        guard let bar = trend.candles.first(where: { $0.date == point.date }) else { return }
        detailLabel.stringValue = String(
            format: "%@ 开%@ 高%@ 低%@ 收%@",
            trend.market.dateString(for: bar.date),
            StockTrendPriceFormat.text(bar.open, decimalPlaces: decimalPlaces),
            StockTrendPriceFormat.text(bar.high, decimalPlaces: decimalPlaces),
            StockTrendPriceFormat.text(bar.low, decimalPlaces: decimalPlaces),
            StockTrendPriceFormat.text(bar.close, decimalPlaces: decimalPlaces)
        )
        detailLabel.toolTip = detailLabel.stringValue + " \(trend.market.currency) · \(trend.range.title) 未复权"
    }

    private func showDefaultDetail() {
        detailLabel.stringValue = "上方看价格折线 · 下方看开高低收蜡烛"
        detailLabel.toolTip = "休市时间已压缩；未收盘的 K 线为暂值"
    }

    @objc private func changeRange() { onRangeChange?() }
    @objc private func changeKRange() { onKRangeChange?() }

    @objc private func openKline() {
        guard let latestQuote else { return }
        onOpenKline?(latestQuote)
    }

    func dismiss() {
        code = nil
        latestQuote = nil
        plot.trend = nil
        kPlot.trend = nil
        window.orderOut(nil)
    }
}
