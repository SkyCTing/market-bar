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
    private let window: StockTrendPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let latestPriceLabel = NSTextField(labelWithString: "")
    private let klineButton = NSButton(title: "K 线图…", target: nil, action: nil)
    private let rangeControl = NSSegmentedControl()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let plot = StockTrendPlot()
    private var decimalPlaces = 2
    var onRangeChange: (() -> Void)?
    var onOpenKline: ((StockQuote) -> Void)?
    private var latestQuote: StockQuote?
    private(set) var code: String?
    var range: StockTrendRange {
        let index = rangeControl.selectedSegment
        return Self.inlineRanges.indices.contains(index) ? Self.inlineRanges[index] : .today
    }
    var frame: NSRect { window.frame }
    var isVisible: Bool { window.isVisible }

    init() {
        window = StockTrendPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 245),
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
        content.heightAnchor.constraint(equalToConstant: 245).isActive = true

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.identifier = NSUserInterfaceItemIdentifier("stockTrendTitle")
        latestPriceLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        latestPriceLabel.identifier = NSUserInterfaceItemIdentifier("stockTrendLatestPrice")
        klineButton.isBordered = false
        klineButton.font = .systemFont(ofSize: 11, weight: .semibold)
        klineButton.contentTintColor = NSColor(calibratedRed: 0.94, green: 0.72, blue: 0.34, alpha: 1)
        klineButton.identifier = NSUserInterfaceItemIdentifier("openStockKline")
        klineButton.target = self
        klineButton.action = #selector(openKline)
        summaryLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        summaryLabel.identifier = NSUserInterfaceItemIdentifier("stockTrendSummary")
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.identifier = NSUserInterfaceItemIdentifier("stockTrendDetail")
        detailLabel.lineBreakMode = .byTruncatingTail
        rangeControl.segmentCount = Self.inlineRanges.count
        rangeControl.appearance = NSAppearance(named: .darkAqua)
        for (index, range) in Self.inlineRanges.enumerated() {
            rangeControl.setLabel(range.title, forSegment: index)
        }
        rangeControl.selectedSegment = StockTrendRange.today.rawValue
        rangeControl.controlSize = .small
        rangeControl.target = self
        rangeControl.action = #selector(changeRange)
        plot.onHover = { [weak self] point in self?.showDetail(point) }

        for view in [titleLabel, latestPriceLabel, klineButton, summaryLabel, detailLabel, rangeControl, plot] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: rangeControl.leadingAnchor, constant: -6),
            rangeControl.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            rangeControl.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            latestPriceLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
            latestPriceLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            latestPriceLabel.trailingAnchor.constraint(lessThanOrEqualTo: klineButton.leadingAnchor, constant: -8),
            klineButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            klineButton.centerYAnchor.constraint(equalTo: latestPriceLabel.centerYAnchor),
            summaryLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            plot.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            plot.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            plot.topAnchor.constraint(equalTo: latestPriceLabel.bottomAnchor, constant: 6),
            plot.bottomAnchor.constraint(equalTo: summaryLabel.topAnchor, constant: -5),
            summaryLabel.bottomAnchor.constraint(equalTo: detailLabel.topAnchor, constant: -6),
            detailLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            detailLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            detailLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    func show(code: String, name: String, market: StockMarket, quote: StockQuote,
              row: NSRect, alongside panel: NSRect) {
        if self.code != code { rangeControl.selectedSegment = StockTrendRange.today.rawValue }
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
        if let trend = plot.trend { show(trend) }
    }

    func showLoading() {
        plot.trend = nil
        summaryLabel.stringValue = "正在读取\(range.title)走势…"
        detailLabel.stringValue = "价格折线 · 休市时段已压缩；日线未复权"
    }

    func show(_ trend: StockTrend) {
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
        detailLabel.stringValue = "\(trend.market.timeZoneName) · 截至 \(timestamp) · \(trend.points.count) 点 · 交易时间折线"
        detailLabel.toolTip = detailLabel.stringValue
            + "；休市时段已压缩，不是蜡烛 K 线"
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
            format: "%@ %@ · %@ %@", trend.market.timeZoneName,
            trend.market.formattedQuoteTime(point.date),
            StockTrendPriceFormat.text(point.price, decimalPlaces: decimalPlaces), trend.market.currency
        )
        detailLabel.toolTip = detailLabel.stringValue
    }

    @objc private func changeRange() { onRangeChange?() }

    @objc private func openKline() {
        guard let latestQuote else { return }
        onOpenKline?(latestQuote)
    }

    func dismiss() {
        code = nil
        latestQuote = nil
        plot.trend = nil
        window.orderOut(nil)
    }
}
