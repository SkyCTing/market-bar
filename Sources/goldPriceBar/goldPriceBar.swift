import AppKit
import Foundation

enum GoldProvider: CaseIterable {
    case zheShang
    case minSheng

    var displayName: String {
        switch self {
        case .zheShang:
            return "浙商积存金"
        case .minSheng:
            return "民生积存金"
        }
    }

    var shortName: String {
        switch self {
        case .zheShang:
            return "浙商"
        case .minSheng:
            return "民生"
        }
    }

    var url: URL {
        switch self {
        case .zheShang:
            return URL(string: "https://api.jdjygold.com/gw2/generic/produTools/h5/m/getGoldPrice?goldCode=CZB-JCJ")!
        case .minSheng:
            return URL(string: "https://ms.jr.jd.com/gw2/generic/CreatorSer/newh5/m/getFirstRelatedProductInfo?reqData=%7B%22circleId%22%3A%2213245%22%2C%22invokeSource%22%3A5%2C%22productId%22%3A%2221001001000001%22%7D")!
        }
    }
}

enum RefreshIntervalOption: Double, CaseIterable {
    case one = 1
    case two = 2
    case five = 5
    case ten = 10

    var title: String {
        "\(Int(rawValue)) 秒"
    }
}

struct ZheShangResponse: Decodable {
    let resultData: ResultData?

    struct ResultData: Decodable {
        let data: DataNode?
    }

    struct DataNode: Decodable {
        let lastPrice: Double?
        let raise: Double?
        let raisePercent: Double?
    }
}

struct MinShengResponse: Decodable {
    let resultData: ResultData?

    struct ResultData: Decodable {
        let data: DataNode?
    }

    struct DataNode: Decodable {
        let minimumPriceValue: String?
        let rateValue: String?
        let dayFluctuateNum: String?
    }
}

struct PriceInfo {
    let price: Double
    let changeAmount: String   // e.g. "-4.22" or "+4.22"
    let changePercent: String  // e.g. "-0.44%" or "+0.44%"
    let isNegative: Bool?

    static let empty = PriceInfo(price: 0, changeAmount: "0.00", changePercent: "0.00%", isNegative: nil)
}

// MARK: - Market Quote API Response

struct MarketQuoteResponse: Decodable {
    let resultData: ResultData?

    struct ResultData: Decodable {
        let data: [QuoteItem]?
    }

    struct QuoteItem: Decodable {
        let uniqueCode: String?
        let name: String?
        let lastPrice: Double?
        let raise: Double?
        let raisePercent: Double?
    }
}

struct MarketData {
    let londonGold: QuoteRow       // XAUUSD
    let goldTD: QuoteRow           // Au(T+D)
    let usdCnh: QuoteRow           // USDCNH
    let dollarIndex: QuoteRow      // DXY
    let convertedPrice: Double     // 伦敦金换算价 (¥/g)
    let premium: Double            // 溢价金额 (¥/g)

    struct QuoteRow {
        let name: String
        let price: String
        let raise: Double
        let raisePercent: Double
    }

    static let empty = MarketData(
        londonGold: QuoteRow(name: "伦敦金", price: "--", raise: 0, raisePercent: 0),
        goldTD: QuoteRow(name: "黄金T+D", price: "--", raise: 0, raisePercent: 0),
        usdCnh: QuoteRow(name: "离岸人民币", price: "--", raise: 0, raisePercent: 0),
        dollarIndex: QuoteRow(name: "美元指数", price: "--", raise: 0, raisePercent: 0),
        convertedPrice: 0,
        premium: 0
    )
}

final class GoldPriceService: Sendable {
    private let session: URLSession

    private let marketQuoteURL = URL(string: "https://ms.jr.jd.com/gw2/generic/jdtwt/h5/m/getSimpleQuoteUseUniqueCodes?reqData=%7B%22ticket%22%3A%22gold-price-h5%22%2C%22uniqueCodes%22%3A%5B%22WG-XAUUSD%22%2C%22SGE-Au(T%2BD)%22%2C%22FX-USDCNH%22%2C%22FX-DXY%22%5D%7D")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchPriceInfo(for provider: GoldProvider) async -> PriceInfo {
        var request = URLRequest(url: provider.url)
        request.timeoutInterval = 5

        do {
            let (data, _) = try await session.data(for: request)
            switch provider {
            case .zheShang:
                return try decodeZheShang(from: data)
            case .minSheng:
                return try decodeMinSheng(from: data)
            }
        } catch {
            return .empty
        }
    }

    func fetchMarketData(currentGoldPrice: Double) async -> MarketData {
        var request = URLRequest(url: marketQuoteURL)
        request.timeoutInterval = 5

        do {
            let (data, _) = try await session.data(for: request)
            let response = try JSONDecoder().decode(MarketQuoteResponse.self, from: data)
            guard let items = response.resultData?.data else { return .empty }

            var xauusd: MarketQuoteResponse.QuoteItem?
            var auTD: MarketQuoteResponse.QuoteItem?
            var usdcnh: MarketQuoteResponse.QuoteItem?
            var dxy: MarketQuoteResponse.QuoteItem?

            for item in items {
                switch item.uniqueCode {
                case "WG-XAUUSD": xauusd = item
                case "SGE-Au(T+D)": auTD = item
                case "FX-USDCNH": usdcnh = item
                case "FX-DXY": dxy = item
                default: break
                }
            }

            func makeRow(_ item: MarketQuoteResponse.QuoteItem?, decimals: Int = 2) -> MarketData.QuoteRow {
                guard let item else { return MarketData.QuoteRow(name: "--", price: "--", raise: 0, raisePercent: 0) }
                let priceStr = String(format: "%.\(decimals)f", item.lastPrice ?? 0)
                return MarketData.QuoteRow(
                    name: item.name ?? "--",
                    price: priceStr,
                    raise: item.raise ?? 0,
                    raisePercent: item.raisePercent ?? 0
                )
            }

            let londonGoldPrice = xauusd?.lastPrice ?? 0
            let exchangeRate = usdcnh?.lastPrice ?? 0

            // 伦敦金换算价 = XAUUSD / 31.1035 * USDCNH
            let converted = londonGoldPrice > 0 && exchangeRate > 0
                ? londonGoldPrice / 31.1035 * exchangeRate
                : 0

            // 溢价 = 黄金T+D - 换算价
            let auTDPrice = auTD?.lastPrice ?? 0
            let premium = converted > 0 && auTDPrice > 0
                ? auTDPrice - converted
                : 0

            return MarketData(
                londonGold: makeRow(xauusd, decimals: 2),
                goldTD: makeRow(auTD, decimals: 2),
                usdCnh: makeRow(usdcnh, decimals: 4),
                dollarIndex: makeRow(dxy, decimals: 3),
                convertedPrice: converted,
                premium: premium
            )
        } catch {
            return .empty
        }
    }

    private func decodeZheShang(from data: Data) throws -> PriceInfo {
        let response = try JSONDecoder().decode(ZheShangResponse.self, from: data)
        let node = response.resultData?.data
        let price = node?.lastPrice ?? 0
        let raise = node?.raise ?? 0
        let raisePercent = node?.raisePercent ?? 0

        // Truncate raisePercent * 100 to 2 decimal places (not round)
        let pctValue = raisePercent * 100
        let truncated = (pctValue * 100).rounded(.towardZero) / 100
        let percentStr = String(format: "%.2f%%", truncated)
        let amountStr = String(format: "%.2f", raise)
        let isNeg = raise < 0 ? true : (raise > 0 ? false : nil)

        return PriceInfo(price: price, changeAmount: amountStr, changePercent: percentStr, isNegative: isNeg)
    }

    private func decodeMinSheng(from data: Data) throws -> PriceInfo {
        let response = try JSONDecoder().decode(MinShengResponse.self, from: data)
        let node = response.resultData?.data
        let price: Double
        if let value = node?.minimumPriceValue {
            price = Double(value) ?? 0
        } else {
            price = 0
        }
        let percentStr = node?.rateValue ?? "0.00%"
        let amountStr = node?.dayFluctuateNum ?? "0.00"

        // Determine direction from the amount string
        let isNeg: Bool?
        if amountStr.hasPrefix("-") {
            isNeg = true
        } else if let val = Double(amountStr), val > 0 {
            isNeg = false
        } else {
            isNeg = nil
        }

        return PriceInfo(price: price, changeAmount: amountStr, changePercent: percentStr, isNegative: isNeg)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let service = GoldPriceService()

    private var selectedProvider: GoldProvider = .zheShang
    private var refreshInterval: RefreshIntervalOption = .one
    private var timer: Timer?
    private var currentPrice: Double = 0
    private var currentPriceInfo: PriceInfo = .empty
    private var currentMarketData: MarketData = .empty
    private var isFetching = false
    private var lastUpdateTime: Date?

    // Hover panel
    private var hoverPanel: HoverPanel?

    // Price alert state
    private var highPriceThreshold: Double?  // alert when price >= this
    private var lowPriceThreshold: Double?   // alert when price <= this
    private var highAlertTriggered = false
    private var lowAlertTriggered = false
    private var isMenuOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        loadSettings()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusTitle()
        rebuildMenu()
        restartTimer()
        setupHoverTracking()
        Task {
            await self.refreshPrice()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        hoverPanel?.dismiss()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval.rawValue, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshPrice()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func refreshPrice() async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        async let priceTask = service.fetchPriceInfo(for: selectedProvider)
        let info = await priceTask
        currentPriceInfo = info
        currentPrice = info.price
        lastUpdateTime = Date()
        updateStatusTitle()
        checkPriceAlerts()

        // Fetch market data in background and update hover panel if visible
        let marketData = await service.fetchMarketData(currentGoldPrice: currentPrice)
        currentMarketData = marketData
        if hoverPanel?.isVisible == true {
            updateHoverPanelContent()
        }
    }

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }

        let info = currentPriceInfo
        let priceStr = format(price: currentPrice)

        // e.g. "浙商 1049.59"
        let prefix = "\(selectedProvider.shortName) \(priceStr) "
        // e.g. "(-4.08 -0.38%)"
        let changePart = "(\(info.changeAmount) \(info.changePercent))"

        let fullStr = prefix + changePart
        let attributed = NSMutableAttributedString(string: fullStr)

        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)

        // Style entire string with default color
        attributed.addAttributes([
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ], range: NSRange(location: 0, length: fullStr.count))

        // Color the change part
        let changeColor: NSColor
        if let isNeg = info.isNegative {
            changeColor = isNeg
                ? NSColor(calibratedRed: 0.2, green: 0.78, blue: 0.35, alpha: 1)  // green
                : NSColor(calibratedRed: 0.95, green: 0.25, blue: 0.22, alpha: 1) // red
        } else {
            changeColor = .secondaryLabelColor
        }

        let changeRange = (fullStr as NSString).range(of: changePart)
        attributed.addAttribute(.foregroundColor, value: changeColor, range: changeRange)

        button.image = nil
        button.imagePosition = .noImage
        button.attributedTitle = attributed
    }

    private func format(price: Double) -> String {
        String(format: "%.2f", price)
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        for provider in GoldProvider.allCases {
            let item = NSMenuItem(
                title: provider.displayName,
                action: #selector(selectProvider(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = provider
            item.isEnabled = provider != selectedProvider
            menu.addItem(item)
        }

        let refreshMenuItem = NSMenuItem(title: "设置刷新频率", action: nil, keyEquivalent: "")
        let refreshSubmenu = NSMenu(title: "设置刷新频率")
        for option in RefreshIntervalOption.allCases {
            let item = NSMenuItem(
                title: option.title,
                action: #selector(selectRefreshInterval(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = option
            item.state = option == refreshInterval ? .on : .off
            refreshSubmenu.addItem(item)
        }
        menu.setSubmenu(refreshSubmenu, for: refreshMenuItem)
        menu.addItem(refreshMenuItem)

        // Price alert submenu
        let alertMenuItem = NSMenuItem(title: "价格提醒", action: nil, keyEquivalent: "")
        let alertSubmenu = NSMenu(title: "价格提醒")

        // High price alert
        if let high = highPriceThreshold {
            let item = NSMenuItem(
                title: "📈 高价提醒: ≥ \(format(price: high))  ✓",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            alertSubmenu.addItem(item)

            let modifyItem = NSMenuItem(
                title: "修改高价提醒",
                action: #selector(setHighPriceAlert),
                keyEquivalent: ""
            )
            modifyItem.target = self
            alertSubmenu.addItem(modifyItem)

            let clearItem = NSMenuItem(
                title: "清除高价提醒",
                action: #selector(clearHighPriceAlert),
                keyEquivalent: ""
            )
            clearItem.target = self
            alertSubmenu.addItem(clearItem)
        } else {
            let item = NSMenuItem(
                title: "设置高价提醒 (≥)",
                action: #selector(setHighPriceAlert),
                keyEquivalent: ""
            )
            item.target = self
            alertSubmenu.addItem(item)
        }

        alertSubmenu.addItem(.separator())

        // Low price alert
        if let low = lowPriceThreshold {
            let item = NSMenuItem(
                title: "📉 低价提醒: ≤ \(format(price: low))  ✓",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            alertSubmenu.addItem(item)

            let modifyItem = NSMenuItem(
                title: "修改低价提醒",
                action: #selector(setLowPriceAlert),
                keyEquivalent: ""
            )
            modifyItem.target = self
            alertSubmenu.addItem(modifyItem)

            let clearItem = NSMenuItem(
                title: "清除低价提醒",
                action: #selector(clearLowPriceAlert),
                keyEquivalent: ""
            )
            clearItem.target = self
            alertSubmenu.addItem(clearItem)
        } else {
            let item = NSMenuItem(
                title: "设置低价提醒 (≤)",
                action: #selector(setLowPriceAlert),
                keyEquivalent: ""
            )
            item.target = self
            alertSubmenu.addItem(item)
        }

        // Clear all
        if highPriceThreshold != nil || lowPriceThreshold != nil {
            alertSubmenu.addItem(.separator())
            let clearAllItem = NSMenuItem(
                title: "清除所有提醒",
                action: #selector(clearAllAlerts),
                keyEquivalent: ""
            )
            clearAllItem.target = self
            alertSubmenu.addItem(clearAllItem)
        }

        menu.setSubmenu(alertSubmenu, for: alertMenuItem)
        menu.addItem(alertMenuItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc
    private func selectProvider(_ sender: NSMenuItem) {
        guard let provider = sender.representedObject as? GoldProvider else { return }
        selectedProvider = provider
        currentPrice = 0
        updateStatusTitle()
        rebuildMenu()
        saveSettings()
        Task {
            await self.refreshPrice()
        }
    }

    @objc
    private func selectRefreshInterval(_ sender: NSMenuItem) {
        guard let option = sender.representedObject as? RefreshIntervalOption else { return }
        refreshInterval = option
        rebuildMenu()
        restartTimer()
        saveSettings()
    }

    @objc
    private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Price Alert

    private func checkPriceAlerts() {
        guard currentPrice > 0 else { return }

        if let high = highPriceThreshold {
            if currentPrice >= high && !highAlertTriggered {
                highAlertTriggered = true
                showToastNotification(
                    title: "📈 金价上涨提醒",
                    body: "\(selectedProvider.displayName) 当前价格 \(format(price: currentPrice))，已达到 ≥ \(format(price: high)) 的提醒条件"
                )
            } else if currentPrice < high {
                highAlertTriggered = false
            }
        }

        if let low = lowPriceThreshold {
            if currentPrice <= low && !lowAlertTriggered {
                lowAlertTriggered = true
                showToastNotification(
                    title: "📉 金价下跌提醒",
                    body: "\(selectedProvider.displayName) 当前价格 \(format(price: currentPrice))，已达到 ≤ \(format(price: low)) 的提醒条件"
                )
            } else if currentPrice > low {
                lowAlertTriggered = false
            }
        }
    }

    private func showToastNotification(title: String, body: String) {
        NSSound.beep()
        ToastWindow.show(title: title, body: body)
    }

    @objc
    private func setHighPriceAlert() {
        if let value = showPriceInputDialog(
            title: "设置高价提醒",
            message: "当金价 ≥ 输入值时发送通知提醒",
            defaultValue: highPriceThreshold
        ) {
            highPriceThreshold = value
            highAlertTriggered = false
            rebuildMenu()
            saveSettings()
        }
    }

    @objc
    private func setLowPriceAlert() {
        if let value = showPriceInputDialog(
            title: "设置低价提醒",
            message: "当金价 ≤ 输入值时发送通知提醒",
            defaultValue: lowPriceThreshold
        ) {
            lowPriceThreshold = value
            lowAlertTriggered = false
            rebuildMenu()
            saveSettings()
        }
    }

    @objc
    private func clearHighPriceAlert() {
        highPriceThreshold = nil
        highAlertTriggered = false
        rebuildMenu()
        saveSettings()
    }

    @objc
    private func clearLowPriceAlert() {
        lowPriceThreshold = nil
        lowAlertTriggered = false
        rebuildMenu()
        saveSettings()
    }

    @objc
    private func clearAllAlerts() {
        highPriceThreshold = nil
        lowPriceThreshold = nil
        highAlertTriggered = false
        lowAlertTriggered = false
        rebuildMenu()
        saveSettings()
    }

    private func showPriceInputDialog(title: String, message: String, defaultValue: Double?) -> Double? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.placeholderString = "请输入价格，例如 880.50"
        if let value = defaultValue {
            input.stringValue = format(price: value)
        }
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }

        let text = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard let price = Double(text), price > 0 else {
            let errorAlert = NSAlert()
            errorAlert.messageText = "输入无效"
            errorAlert.informativeText = "请输入有效的价格数字"
            errorAlert.alertStyle = .warning
            errorAlert.runModal()
            return nil
        }
        return price
    }

    // MARK: - Settings Persistence

    private enum SettingsKey {
        static let provider = "selectedProvider"
        static let refreshInterval = "refreshInterval"
        static let highThreshold = "highPriceThreshold"
        static let lowThreshold = "lowPriceThreshold"
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(selectedProvider == .zheShang ? "zheShang" : "minSheng", forKey: SettingsKey.provider)
        defaults.set(refreshInterval.rawValue, forKey: SettingsKey.refreshInterval)
        if let high = highPriceThreshold {
            defaults.set(high, forKey: SettingsKey.highThreshold)
        } else {
            defaults.removeObject(forKey: SettingsKey.highThreshold)
        }
        if let low = lowPriceThreshold {
            defaults.set(low, forKey: SettingsKey.lowThreshold)
        } else {
            defaults.removeObject(forKey: SettingsKey.lowThreshold)
        }
    }

    private func loadSettings() {
        let defaults = UserDefaults.standard
        if let providerStr = defaults.string(forKey: SettingsKey.provider) {
            selectedProvider = providerStr == "minSheng" ? .minSheng : .zheShang
        }
        if let intervalValue = defaults.object(forKey: SettingsKey.refreshInterval) as? Double,
           let interval = RefreshIntervalOption(rawValue: intervalValue) {
            refreshInterval = interval
        }
        if defaults.object(forKey: SettingsKey.highThreshold) != nil {
            highPriceThreshold = defaults.double(forKey: SettingsKey.highThreshold)
        }
        if defaults.object(forKey: SettingsKey.lowThreshold) != nil {
            lowPriceThreshold = defaults.double(forKey: SettingsKey.lowThreshold)
        }
    }

    // MARK: - Hover Panel

    private func setupHoverTracking() {
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Task { @MainActor in
                self?.handleMouseMove()
            }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Task { @MainActor in
                self?.handleMouseMove()
            }
            return event
        }
    }

    private func handleMouseMove() {
        guard !isMenuOpen,
              let button = statusItem.button,
              let buttonWindow = button.window else { return }

        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let mouseLocation = NSEvent.mouseLocation

        let isOverButton = buttonRect.contains(mouseLocation)

        let isOverPanel: Bool
        if let panel = hoverPanel, panel.isVisible {
            isOverPanel = panel.frame.contains(mouseLocation)
        } else {
            isOverPanel = false
        }

        if isOverButton && (hoverPanel == nil || !hoverPanel!.isVisible) {
            showHoverPanel(below: buttonRect)
        } else if !isOverButton && !isOverPanel {
            hoverPanel?.dismiss()
        }
    }

    private func buildHoverPanelData() -> HoverPanelData {
        let info = currentPriceInfo
        let timeStr: String
        if let time = lastUpdateTime {
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm:ss"
            timeStr = fmt.string(from: time)
        } else {
            timeStr = "--:--:--"
        }

        var alertParts: [String] = []
        if let high = highPriceThreshold {
            alertParts.append("≥ \(format(price: high))")
        }
        if let low = lowPriceThreshold {
            alertParts.append("≤ \(format(price: low))")
        }
        let alertInfo = alertParts.isEmpty ? "未设置" : alertParts.joined(separator: " | ")

        return HoverPanelData(
            provider: selectedProvider.displayName,
            price: format(price: currentPrice),
            changeAmount: info.changeAmount,
            changePercent: info.changePercent,
            isNegative: info.isNegative,
            updateTime: timeStr,
            refreshInterval: refreshInterval.title,
            alertInfo: alertInfo,
            market: currentMarketData
        )
    }

    private func showHoverPanel(below buttonRect: NSRect) {
        hoverPanel?.dismiss()

        let panel = HoverPanel()
        panel.show(below: buttonRect, data: buildHoverPanelData())
        hoverPanel = panel
    }

    private func updateHoverPanelContent() {
        hoverPanel?.updateContent(data: buildHoverPanelData())
    }
}

struct HoverPanelData {
    let provider: String
    let price: String
    let changeAmount: String
    let changePercent: String
    let isNegative: Bool?
    let updateTime: String
    let refreshInterval: String
    let alertInfo: String
    let market: MarketData
}

// MARK: - Toast Notification Window

@MainActor
final class ToastWindow {
    private static var currentWindow: NSWindow?
    private static var dismissTimer: Timer?

    static func show(title: String, body: String, duration: TimeInterval = 30) {
        // Dismiss previous toast
        dismiss()

        guard let screen = NSScreen.main else { return }

        let padding: CGFloat = 20
        let windowWidth: CGFloat = 380
        let accentWidth: CGFloat = 5
        let closeButtonSize: CGFloat = 20

        // --- Outer container (holds accent bar + content) ---
        let containerView = NSView()
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.96).cgColor
        containerView.layer?.cornerRadius = 14
        containerView.layer?.borderColor = NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.0, alpha: 0.5).cgColor
        containerView.layer?.borderWidth = 1

        // --- Gold accent bar on the left ---
        let accentBar = NSView()
        accentBar.wantsLayer = true
        accentBar.layer?.backgroundColor = NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.0, alpha: 1).cgColor
        accentBar.layer?.cornerRadius = 2
        accentBar.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(accentBar)

        // --- Close button (✕) ---
        let closeButton = NSButton(frame: .zero)
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.title = "✕"
        closeButton.font = .systemFont(ofSize: 14, weight: .medium)
        closeButton.contentTintColor = NSColor(white: 0.6, alpha: 1)
        closeButton.target = self
        closeButton.action = #selector(handleClose)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(closeButton)

        // --- Title ---
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 16, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(titleLabel)

        // --- Body ---
        let bodyLabel = NSTextField(wrappingLabelWithString: body)
        bodyLabel.font = .systemFont(ofSize: 13, weight: .regular)
        bodyLabel.textColor = NSColor(white: 0.88, alpha: 1)
        bodyLabel.maximumNumberOfLines = 5
        bodyLabel.preferredMaxLayoutWidth = windowWidth - padding * 2 - accentWidth - 12
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(bodyLabel)

        let contentLeading = padding + accentWidth + 10

        NSLayoutConstraint.activate([
            // Accent bar
            accentBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            accentBar.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 14),
            accentBar.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -14),
            accentBar.widthAnchor.constraint(equalToConstant: accentWidth),

            // Close button
            closeButton.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 10),
            closeButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -10),
            closeButton.widthAnchor.constraint(equalToConstant: closeButtonSize),
            closeButton.heightAnchor.constraint(equalToConstant: closeButtonSize),

            // Title
            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: padding),
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: contentLeading),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),

            // Body
            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            bodyLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: contentLeading),
            bodyLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -padding),
            bodyLabel.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -padding),
        ])

        // Calculate content height
        let fittingSize = containerView.fittingSize
        let windowHeight = max(fittingSize.height, 80)

        let screenRect = screen.visibleFrame
        let windowRect = NSRect(
            x: screenRect.maxX - windowWidth - 20,
            y: screenRect.maxY - windowHeight - 20,
            width: windowWidth,
            height: windowHeight
        )

        let window = NSPanel(
            contentRect: windowRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hasShadow = true
        window.contentView = containerView
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        // Fade in
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            window.animator().alphaValue = 1
        }

        currentWindow = window

        // Auto dismiss after duration
        dismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
            Task { @MainActor in
                dismiss()
            }
        }
    }

    @objc static func handleClose() {
        dismiss()
    }

    static func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil

        guard let window = currentWindow else { return }
        currentWindow = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            window.animator().alphaValue = 0
        }, completionHandler: {
            DispatchQueue.main.async {
                window.orderOut(nil)
            }
        })
    }
}

// MARK: - Hover Detail Panel

@MainActor
final class HoverPanel {
    private var window: NSPanel?
    private var buttonRect: NSRect = .zero

    // Mutable labels for live updates
    private var priceLabel: NSTextField?
    private var changeLabel: NSTextField?
    private var infoValueLabels: [String: NSTextField] = [:]
    private var marketValueLabels: [String: NSTextField] = [:]

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    var frame: NSRect {
        window?.frame ?? .zero
    }

    func show(below buttonRect: NSRect, data: HoverPanelData) {
        self.buttonRect = buttonRect

        let panelWidth: CGFloat = 300
        let padding: CGFloat = 16
        let labelColor = NSColor(white: 0.5, alpha: 1)
        let valueColor = NSColor(white: 0.85, alpha: 1)
        let sectionTitleColor = NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.0, alpha: 1)

        // Container
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.14, alpha: 0.96).cgColor
        container.layer?.cornerRadius = 12
        container.layer?.borderColor = NSColor(white: 0.3, alpha: 0.5).cgColor
        container.layer?.borderWidth = 0.5

        // --- Top section: Provider + Price + Change ---
        let providerLabel = NSTextField(labelWithString: data.provider)
        providerLabel.font = .systemFont(ofSize: 12, weight: .medium)
        providerLabel.textColor = labelColor
        providerLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(providerLabel)

        let pLabel = NSTextField(labelWithString: "\u{00A5} " + data.price)
        pLabel.font = .monospacedDigitSystemFont(ofSize: 26, weight: .bold)
        pLabel.textColor = .white
        pLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pLabel)
        self.priceLabel = pLabel

        let cLabel = NSTextField(labelWithString: "\(data.changeAmount)  \(data.changePercent)")
        cLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        cLabel.textColor = changeColor(for: data.isNegative)
        cLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(cLabel)
        self.changeLabel = cLabel

        // --- Divider 1 ---
        let divider1 = makeDivider()
        container.addSubview(divider1)

        // --- Market data section ---
        let marketTitle = NSTextField(labelWithString: "行情数据")
        marketTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        marketTitle.textColor = sectionTitleColor
        marketTitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(marketTitle)

        let m = data.market
        let marketRows: [(key: String, title: String, value: String, raise: Double)] = [
            ("londonGold", "伦敦金", formatValueWithPercent(price: m.londonGold.price, raisePercent: m.londonGold.raisePercent), m.londonGold.raise),
            ("goldTD", "黄金T+D", formatValueWithPercent(price: m.goldTD.price, raisePercent: m.goldTD.raisePercent), m.goldTD.raise),
            ("converted", "伦敦金换算 (¥/g)", m.convertedPrice > 0 ? String(format: "%.2f", m.convertedPrice) : "--", 0),
            ("premium", "溢价 (¥/g)", m.convertedPrice > 0 ? String(format: "%+.2f", m.premium) : "--", m.premium),
            ("usdcnh", "离岸人民币", formatValueWithPercent(price: m.usdCnh.price, raisePercent: m.usdCnh.raisePercent), m.usdCnh.raise),
            ("dxy", "美元指数", formatValueWithPercent(price: m.dollarIndex.price, raisePercent: m.dollarIndex.raisePercent), m.dollarIndex.raise),
        ]

        var marketLabelPairs: [(NSTextField, NSTextField)] = []
        for row in marketRows {
            let tl = NSTextField(labelWithString: row.title)
            tl.font = .systemFont(ofSize: 11, weight: .regular)
            tl.textColor = labelColor
            tl.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(tl)

            let vl = NSTextField(labelWithString: row.value)
            vl.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            vl.alignment = .right
            vl.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(vl)

            if row.key == "converted" {
                vl.textColor = valueColor
            } else {
                vl.textColor = raisedColor(row.raise, fallback: valueColor)
            }

            marketLabelPairs.append((tl, vl))
            marketValueLabels[row.key] = vl
        }

        // --- Divider 2 ---
        let divider2 = makeDivider()
        container.addSubview(divider2)

        // --- Info section ---
        let infoRows: [(key: String, title: String, value: String)] = [
            ("updateTime", "更新时间", data.updateTime),
            ("refreshInterval", "刷新频率", data.refreshInterval),
            ("alert", "价格提醒", data.alertInfo),
        ]

        var infoLabelPairs: [(NSTextField, NSTextField)] = []
        for row in infoRows {
            let tl = NSTextField(labelWithString: row.title)
            tl.font = .systemFont(ofSize: 11, weight: .regular)
            tl.textColor = labelColor
            tl.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(tl)

            let vl = NSTextField(labelWithString: row.value)
            vl.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            vl.textColor = valueColor
            vl.alignment = .right
            vl.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(vl)

            infoLabelPairs.append((tl, vl))
            infoValueLabels[row.key] = vl
        }

        // --- Layout ---
        var constraints: [NSLayoutConstraint] = [
            providerLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            providerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),

            pLabel.topAnchor.constraint(equalTo: providerLabel.bottomAnchor, constant: 4),
            pLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),

            cLabel.topAnchor.constraint(equalTo: pLabel.bottomAnchor, constant: 2),
            cLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),

            divider1.topAnchor.constraint(equalTo: cLabel.bottomAnchor, constant: 12),
            divider1.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            divider1.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            divider1.heightAnchor.constraint(equalToConstant: 0.5),

            marketTitle.topAnchor.constraint(equalTo: divider1.bottomAnchor, constant: 10),
            marketTitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
        ]

        var prev = marketTitle.bottomAnchor
        for (i, (tl, vl)) in marketLabelPairs.enumerated() {
            let top: CGFloat = i == 0 ? 8 : 5
            constraints.append(contentsOf: [
                tl.topAnchor.constraint(equalTo: prev, constant: top),
                tl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
                vl.centerYAnchor.constraint(equalTo: tl.centerYAnchor),
                vl.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
                vl.leadingAnchor.constraint(greaterThanOrEqualTo: tl.trailingAnchor, constant: 8),
            ])
            prev = tl.bottomAnchor
        }

        constraints.append(contentsOf: [
            divider2.topAnchor.constraint(equalTo: prev, constant: 10),
            divider2.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            divider2.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            divider2.heightAnchor.constraint(equalToConstant: 0.5),
        ])

        prev = divider2.bottomAnchor
        for (i, (tl, vl)) in infoLabelPairs.enumerated() {
            let top: CGFloat = i == 0 ? 8 : 5
            constraints.append(contentsOf: [
                tl.topAnchor.constraint(equalTo: prev, constant: top),
                tl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
                vl.centerYAnchor.constraint(equalTo: tl.centerYAnchor),
                vl.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
                vl.leadingAnchor.constraint(greaterThanOrEqualTo: tl.trailingAnchor, constant: 8),
            ])
            prev = tl.bottomAnchor
        }

        constraints.append(prev.constraint(equalTo: container.bottomAnchor, constant: -padding))
        NSLayoutConstraint.activate(constraints)

        // Size and position — force a layout pass first so fittingSize is accurate
        container.translatesAutoresizingMaskIntoConstraints = false
        // Give container a temporary width constraint so it can resolve height
        let tempWidthConstraint = container.widthAnchor.constraint(equalToConstant: panelWidth)
        tempWidthConstraint.isActive = true
        container.layoutSubtreeIfNeeded()
        tempWidthConstraint.isActive = false

        let fittingSize = container.fittingSize
        // Guard against zero/negative dimensions which cause the WindowServer error
        let panelHeight = max(fittingSize.height, 100)
        let panelX = buttonRect.midX - panelWidth / 2
        let panelY = buttonRect.minY - panelHeight - 4

        // Clamp to screen bounds
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let clampedX = max(screenFrame.minX, min(panelX, screenFrame.maxX - panelWidth))
        let clampedY = max(screenFrame.minY, min(panelY, screenFrame.maxY - panelHeight))

        let panel = NSPanel(
            contentRect: NSRect(x: clampedX, y: clampedY, width: panelWidth, height: panelHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.contentView = container
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }

        self.window = panel
    }

    func updateContent(data: HoverPanelData) {
        priceLabel?.stringValue = "\u{00A5} " + data.price
        changeLabel?.stringValue = "\(data.changeAmount)  \(data.changePercent)"
        changeLabel?.textColor = changeColor(for: data.isNegative)

        infoValueLabels["updateTime"]?.stringValue = data.updateTime
        infoValueLabels["refreshInterval"]?.stringValue = data.refreshInterval
        infoValueLabels["alert"]?.stringValue = data.alertInfo

        let m = data.market
        let fallback = NSColor(white: 0.85, alpha: 1)

        marketValueLabels["londonGold"]?.stringValue = formatValueWithPercent(price: m.londonGold.price, raisePercent: m.londonGold.raisePercent)
        marketValueLabels["londonGold"]?.textColor = raisedColor(m.londonGold.raise, fallback: fallback)

        marketValueLabels["goldTD"]?.stringValue = formatValueWithPercent(price: m.goldTD.price, raisePercent: m.goldTD.raisePercent)
        marketValueLabels["goldTD"]?.textColor = raisedColor(m.goldTD.raise, fallback: fallback)

        marketValueLabels["converted"]?.stringValue = m.convertedPrice > 0 ? String(format: "%.2f", m.convertedPrice) : "--"

        marketValueLabels["premium"]?.stringValue = m.convertedPrice > 0 ? String(format: "%+.2f", m.premium) : "--"
        marketValueLabels["premium"]?.textColor = raisedColor(m.premium, fallback: fallback)

        marketValueLabels["usdcnh"]?.stringValue = formatValueWithPercent(price: m.usdCnh.price, raisePercent: m.usdCnh.raisePercent)
        marketValueLabels["usdcnh"]?.textColor = raisedColor(m.usdCnh.raise, fallback: fallback)

        marketValueLabels["dxy"]?.stringValue = formatValueWithPercent(price: m.dollarIndex.price, raisePercent: m.dollarIndex.raisePercent)
        marketValueLabels["dxy"]?.textColor = raisedColor(m.dollarIndex.raise, fallback: fallback)
    }

    func dismiss() {
        guard let window = self.window else { return }
        self.window = nil
        priceLabel = nil
        changeLabel = nil
        infoValueLabels.removeAll()
        marketValueLabels.removeAll()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            window.animator().alphaValue = 0
        }, completionHandler: {
            DispatchQueue.main.async {
                window.orderOut(nil)
            }
        })
    }

    // MARK: - Helpers

    private func changeColor(for isNegative: Bool?) -> NSColor {
        guard let isNeg = isNegative else { return .secondaryLabelColor }
        return isNeg
            ? NSColor(calibratedRed: 0.2, green: 0.78, blue: 0.35, alpha: 1)
            : NSColor(calibratedRed: 0.95, green: 0.25, blue: 0.22, alpha: 1)
    }

    private func raisedColor(_ raise: Double, fallback: NSColor) -> NSColor {
        if raise < 0 { return NSColor(calibratedRed: 0.2, green: 0.78, blue: 0.35, alpha: 1) }
        if raise > 0 { return NSColor(calibratedRed: 0.95, green: 0.25, blue: 0.22, alpha: 1) }
        return fallback
    }

    private func formatValueWithPercent(price: String, raisePercent: Double) -> String {
        guard price != "--" else { return price }
        let pctValue = raisePercent * 100
        let truncated = (pctValue * 100).rounded(.towardZero) / 100
        let sign = truncated > 0 ? "+" : ""
        return String(format: "%@  %@%.2f%%", price, sign, truncated)
    }

    private func makeDivider() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 0.3, alpha: 0.5).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }
}

@main
struct GoldPriceBarApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

