import AppKit

@MainActor
final class StockKlineWindowController: NSObject, NSWindowDelegate {
    typealias Load = (String, StockTrendRange, Bool) async throws -> StockTrend
    private static let modes: [StockTrendRange] = [.dailyCandles, .weeklyCandles, .monthlyCandles]

    private let load: Load
    private let window: NSWindow
    private let titleLabel = NSTextField(labelWithString: "")
    private let priceLabel = NSTextField(labelWithString: "")
    private let periodControl = NSSegmentedControl()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let plot = StockTrendPlot()
    private var currentQuote: StockQuote?
    private var market: StockMarket?
    private(set) var code: String?
    private var requestID = UUID()
    private var requestTask: Task<Void, Never>?
    private var refreshTimer: Timer?

    init(load: @escaping Load) {
        self.load = load
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 540),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "个股 K 线"
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 620, height: 420)
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        super.init()
        window.delegate = self
        buildView()
    }

    var isVisible: Bool { window.isVisible }

    func show(quote: StockQuote) throws {
        guard let market = StockMarket.forCode(quote.code),
              market != .unitedStates else { throw StockTrendError.unsupported }
        guard !quote.code.hasPrefix("bj") else { throw StockTrendError.unsupportedBeijing }
        if code != quote.code { periodControl.selectedSegment = 0 }
        code = quote.code
        self.market = market
        currentQuote = quote
        window.title = "\(quote.name) · K 线"
        titleLabel.stringValue = "\(quote.name) · \(quote.code)"
        titleLabel.toolTip = titleLabel.stringValue
        updateQuote(quote)
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        refresh(force: false)
        if refreshTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.window.isVisible else { return }
                    self.refresh(force: false)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            refreshTimer = timer
        }
    }

    func updateQuote(_ quote: StockQuote) {
        guard quote.code == code, let market else { return }
        currentQuote = quote
        priceLabel.stringValue = "最近价格 \(quote.price) \(market.currency)"
        priceLabel.toolTip = quote.quotedAt.map {
            "报价时间：\(market.formattedQuoteTime($0))（\(market.timeZoneName)）"
        } ?? "报价时间未知"
        let decimals = StockTrendPriceFormat.decimalPlaces(for: quote)
        if plot.decimalPlaces != decimals {
            plot.decimalPlaces = decimals
            if let trend = plot.trend { updateSummary(trend) }
        }
    }

    func close() { window.close() }

    func windowWillClose(_ notification: Notification) {
        requestID = UUID()
        requestTask?.cancel()
        requestTask = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func buildView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.15, alpha: 1).cgColor
        window.contentView = root
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.identifier = NSUserInterfaceItemIdentifier("klineWindowTitle")
        priceLabel.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        priceLabel.identifier = NSUserInterfaceItemIdentifier("klineWindowPrice")
        summaryLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        summaryLabel.identifier = NSUserInterfaceItemIdentifier("klineWindowSummary")
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.identifier = NSUserInterfaceItemIdentifier("klineWindowDetail")
        detailLabel.lineBreakMode = .byTruncatingTail
        periodControl.segmentCount = Self.modes.count
        for (index, mode) in Self.modes.enumerated() {
            periodControl.setLabel(mode.title, forSegment: index)
        }
        periodControl.selectedSegment = 0
        periodControl.target = self
        periodControl.action = #selector(changePeriod)
        let refreshButton = NSButton(title: "刷新", target: self, action: #selector(refreshManually))
        plot.onHover = { [weak self] point in self?.showDetail(point) }
        plot.wantsLayer = true
        plot.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        plot.layer?.cornerRadius = 8

        for view in [titleLabel, priceLabel, periodControl, summaryLabel, detailLabel, refreshButton, plot] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: periodControl.leadingAnchor, constant: -12),
            periodControl.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            periodControl.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -12),
            refreshButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            priceLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            priceLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            summaryLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -22),
            plot.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            plot.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            plot.topAnchor.constraint(equalTo: priceLabel.bottomAnchor, constant: 12),
            plot.bottomAnchor.constraint(equalTo: summaryLabel.topAnchor, constant: -10),
            summaryLabel.bottomAnchor.constraint(equalTo: detailLabel.topAnchor, constant: -9),
            detailLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            detailLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            detailLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -19),
        ])
    }

    @objc private func changePeriod() { refresh(force: false) }
    @objc private func refreshManually() { refresh(force: true) }

    private func refresh(force: Bool) {
        guard let code, Self.modes.indices.contains(periodControl.selectedSegment) else { return }
        let mode = Self.modes[periodControl.selectedSegment]
        requestID = UUID()
        let token = requestID
        requestTask?.cancel()
        plot.trend = nil
        summaryLabel.stringValue = "正在读取 \(mode.title)…"
        detailLabel.stringValue = "未复权 K 线 · 红涨绿跌 · 当前周期尚未结束时为暂值"
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let trend = try await load(code, mode, force)
                guard !Task.isCancelled, requestID == token, window.isVisible else { return }
                plot.trend = trend
                updateSummary(trend)
            } catch {
                guard !Task.isCancelled, requestID == token, window.isVisible else { return }
                summaryLabel.stringValue = "K 线暂不可用"
                detailLabel.stringValue = error.localizedDescription
                detailLabel.toolTip = error.localizedDescription
            }
            requestTask = nil
        }
    }

    private func updateSummary(_ trend: StockTrend) {
        guard let high = trend.highestCandle, let low = trend.lowestCandle,
              let latest = trend.candles.last else {
            summaryLabel.stringValue = "没有完整的开高低收记录"
            return
        }
        let decimals = plot.decimalPlaces
        summaryLabel.stringValue = String(
            format: "%@ · %ld 根 · 最高 %@ · 最低 %@ %@",
            trend.range.title, trend.candles.count,
            StockTrendPriceFormat.text(high.high, decimalPlaces: decimals),
            StockTrendPriceFormat.text(low.low, decimalPlaces: decimals), trend.market.currency
        )
        detailLabel.stringValue = "\(trend.market.timeZoneName) · 截至 \(trend.market.dateString(for: latest.date)) · 鼠标悬停蜡烛查看开高低收"
        detailLabel.toolTip = detailLabel.stringValue + "；未复权；当前周期尚未结束时为暂值"
    }

    private func showDetail(_ point: StockTrendPoint?) {
        guard let trend = plot.trend else { return }
        guard let point else { updateSummary(trend); return }
        guard let bar = trend.candles.first(where: { $0.date == point.date }) else { return }
        let digits = plot.decimalPlaces
        detailLabel.stringValue = String(
            format: "%@ · 开 %@  高 %@  低 %@  收 %@ %@",
            trend.market.dateString(for: bar.date),
            StockTrendPriceFormat.text(bar.open, decimalPlaces: digits),
            StockTrendPriceFormat.text(bar.high, decimalPlaces: digits),
            StockTrendPriceFormat.text(bar.low, decimalPlaces: digits),
            StockTrendPriceFormat.text(bar.close, decimalPlaces: digits), trend.market.currency
        )
        detailLabel.toolTip = detailLabel.stringValue + "（未复权；当前周期可能未完成）"
    }
}
