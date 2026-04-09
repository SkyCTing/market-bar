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
    }
}

struct MinShengResponse: Decodable {
    let resultData: ResultData?

    struct ResultData: Decodable {
        let data: DataNode?
    }

    struct DataNode: Decodable {
        let minimumPriceValue: String?
    }
}

final class GoldPriceService: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchPrice(for provider: GoldProvider) async -> Double {
        var request = URLRequest(url: provider.url)
        request.timeoutInterval = 5

        do {
            let (data, _) = try await session.data(for: request)
            switch provider {
            case .zheShang:
                return try decodeZheShangPrice(from: data)
            case .minSheng:
                return try decodeMinShengPrice(from: data)
            }
        } catch {
            return 0
        }
    }

    private func decodeZheShangPrice(from data: Data) throws -> Double {
        let response = try JSONDecoder().decode(ZheShangResponse.self, from: data)
        return response.resultData?.data?.lastPrice ?? 0
    }

    private func decodeMinShengPrice(from data: Data) throws -> Double {
        let response = try JSONDecoder().decode(MinShengResponse.self, from: data)
        guard let value = response.resultData?.data?.minimumPriceValue else {
            return 0
        }
        return Double(value) ?? 0
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
    private var isFetching = false

    // Price alert state
    private var highPriceThreshold: Double?  // alert when price >= this
    private var lowPriceThreshold: Double?   // alert when price <= this
    private var highAlertTriggered = false
    private var lowAlertTriggered = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        loadSettings()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusTitle()
        rebuildMenu()
        restartTimer()
        Task {
            await self.refreshPrice()
        }
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

        let price = await service.fetchPrice(for: selectedProvider)
        currentPrice = price
        updateStatusTitle()
        checkPriceAlerts()
    }

    private func updateStatusTitle() {
        statusItem.button?.title = "\(selectedProvider.displayName) \(format(price: currentPrice))"
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

@main
struct GoldPriceBarApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
