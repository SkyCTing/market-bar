import AppKit
import CoreGraphics
import QuartzCore

enum FloatingCharacterEmotion: Equatable {
    case happy
    case sad

    init(isNegative: Bool?) {
        self = isNegative == true ? .sad : .happy
    }
}

enum FloatingCharacterPriceTrend: Equatable {
    case up
    case down
    case flat

    init(isNegative: Bool?) {
        switch isNegative {
        case true: self = .down
        case false: self = .up
        case nil: self = .flat
        }
    }

    var color: NSColor {
        switch self {
        case .up:
            return NSColor(calibratedRed: 0.95, green: 0.25, blue: 0.22, alpha: 1)
        case .down:
            return NSColor(calibratedRed: 0.2, green: 0.78, blue: 0.35, alpha: 1)
        case .flat:
            return .secondaryLabelColor
        }
    }
}

enum FloatingCharacterSizeOption: Double, CaseIterable {
    case small = 220
    case standard = 240
    case large = 260

    static let defaultOption: FloatingCharacterSizeOption = .standard

    var size: NSSize {
        NSSize(width: rawValue, height: rawValue)
    }

    var dockedSize: NSSize {
        switch self {
        case .small: return NSSize(width: 165, height: 103)
        case .standard: return NSSize(width: 180, height: 112)
        case .large: return NSSize(width: 195, height: 122)
        }
    }

    var title: String {
        switch self {
        case .small: return "最小（220×220）"
        case .standard: return "默认（240×240）"
        case .large: return "最大（260×260）"
        }
    }
}

enum FloatingCharacterDockEdge: String, Equatable {
    case left
    case right
}

enum FloatingCharacterPresentationMode: Equatable {
    case full
    case docked(FloatingCharacterDockEdge)
}

struct FloatingCharacterDockLayout {
    static let snapDistance: CGFloat = 36
    static let restoreDistance: CGFloat = 48

    static func edge(for pointer: NSPoint, in visibleFrame: NSRect) -> FloatingCharacterDockEdge? {
        guard pointer.y >= visibleFrame.minY, pointer.y <= visibleFrame.maxY else { return nil }
        if abs(pointer.x - visibleFrame.minX) <= snapDistance {
            return .left
        }
        if abs(pointer.x - visibleFrame.maxX) <= snapDistance {
            return .right
        }
        return nil
    }

    static func shouldRestore(horizontalDrag: CGFloat, from edge: FloatingCharacterDockEdge) -> Bool {
        switch edge {
        case .left:
            return horizontalDrag >= restoreDistance
        case .right:
            return horizontalDrag <= -restoreDistance
        }
    }

    static func dockedOrigin(
        edge: FloatingCharacterDockEdge,
        proposedY: CGFloat,
        size: NSSize,
        visibleFrame: NSRect
    ) -> NSPoint {
        let x = edge == .left ? visibleFrame.minX : visibleFrame.maxX - size.width
        let y = max(visibleFrame.minY, min(proposedY, visibleFrame.maxY - size.height))
        return NSPoint(x: x, y: y)
    }
}

struct FloatingCharacterActionTiming {
    static let ambientDelayRange: ClosedRange<TimeInterval> = 10...15
    static let actionDuration: TimeInterval = 3
    static let transitionDuration: TimeInterval = 0.2
}

struct FloatingCharacterDockedTiming {
    static let ambientBlinkDelayRange: ClosedRange<TimeInterval> = 4.5...5.5
    static let closedFrameDuration: TimeInterval = 0.12
    static let betweenBlinksDuration: TimeInterval = 0.14
}

enum FloatingCharacterClickReaction: Equatable {
    case pendingSingle
    case doubleClick
    case impatient
    case hide
    case ignoredDuringCooldown
}

struct FloatingCharacterClickSequence {
    static let burstInterval: TimeInterval = 3
    static let terminalCooldown: TimeInterval = 8
    static let hideDuration: TimeInterval = 4

    private(set) var clickCount = 0
    private(set) var burstStartDate: Date?
    private(set) var lastClickDate: Date?
    private(set) var cooldownUntil: Date?

    mutating func register(
        at date: Date,
        doubleClickInterval: TimeInterval
    ) -> FloatingCharacterClickReaction {
        if let cooldownUntil, date < cooldownUntil {
            return .ignoredDuringCooldown
        }

        let interval = lastClickDate.map { date.timeIntervalSince($0) }
        let burstAge = burstStartDate.map { date.timeIntervalSince($0) }
        if let burstAge, burstAge >= 0, burstAge <= Self.burstInterval {
            clickCount += 1
        } else {
            clickCount = 1
            burstStartDate = date
        }
        lastClickDate = date

        switch clickCount {
        case 1:
            return .pendingSingle
        case 2 where (interval ?? .infinity) <= doubleClickInterval:
            return .doubleClick
        case 2:
            return .pendingSingle
        case 3:
            return .impatient
        default:
            cooldownUntil = date.addingTimeInterval(Self.terminalCooldown)
            clickCount = 0
            burstStartDate = nil
            lastClickDate = nil
            return .hide
        }
    }

    mutating func resetBurst() {
        clickCount = 0
        burstStartDate = nil
        lastClickDate = nil
    }
}

struct FloatingCharacterDragPhysics {
    static let sampleWindow: TimeInterval = 0.12
    static let speedThreshold: CGFloat = 650
    static let projectionFactor: CGFloat = 0.12
    static let maximumDisplacement: CGFloat = 120
    static let inertiaDuration: TimeInterval = 0.45
    static let landingDuration: TimeInterval = 0.45
    static let dockingDuration: TimeInterval = 0.25

    static func speed(of velocity: NSPoint) -> CGFloat {
        hypot(velocity.x, velocity.y)
    }

    static func projectedDisplacement(for velocity: NSPoint) -> NSPoint {
        guard speed(of: velocity) >= speedThreshold else { return .zero }
        var displacement = NSPoint(
            x: velocity.x * projectionFactor,
            y: velocity.y * projectionFactor
        )
        let magnitude = speed(of: displacement)
        if magnitude > maximumDisplacement {
            let scale = maximumDisplacement / magnitude
            displacement.x *= scale
            displacement.y *= scale
        }
        return displacement
    }
}

struct FloatingCharacterDragVelocityTracker {
    private struct Sample {
        let point: NSPoint
        let timestamp: TimeInterval
    }

    private var samples: [Sample] = []

    mutating func reset(point: NSPoint, timestamp: TimeInterval) {
        samples = [Sample(point: point, timestamp: timestamp)]
    }

    mutating func record(point: NSPoint, timestamp: TimeInterval) {
        if let last = samples.last, timestamp < last.timestamp {
            reset(point: point, timestamp: timestamp)
            return
        }
        samples.append(Sample(point: point, timestamp: timestamp))
        samples.removeAll {
            timestamp - $0.timestamp > FloatingCharacterDragPhysics.sampleWindow
        }
        if samples.count > 8 {
            samples.removeFirst(samples.count - 8)
        }
    }

    func velocity() -> NSPoint {
        guard let first = samples.first,
              let last = samples.last else { return .zero }
        let duration = last.timestamp - first.timestamp
        guard duration > 0 else { return .zero }
        return NSPoint(
            x: (last.point.x - first.point.x) / duration,
            y: (last.point.y - first.point.y) / duration
        )
    }
}

enum FloatingCharacterMarketReaction: Equatable {
    case rapidRise(delta: Double)
    case rapidFall(delta: Double)
}

struct FloatingCharacterMarketReactionDetector {
    static let priceDeltaThreshold = 1.0
    static let cooldown: TimeInterval = 45

    private(set) var lastValidPrice: Double?
    private(set) var lastReactionDate: Date?

    mutating func process(price: Double, at date: Date) -> FloatingCharacterMarketReaction? {
        guard price.isFinite, price > 0 else { return nil }
        defer { lastValidPrice = price }
        guard let previousPrice = lastValidPrice else { return nil }

        let delta = price - previousPrice
        guard abs(delta) >= Self.priceDeltaThreshold else { return nil }
        if let lastReactionDate,
           date.timeIntervalSince(lastReactionDate) < Self.cooldown {
            return nil
        }

        lastReactionDate = date
        return delta > 0 ? .rapidRise(delta: delta) : .rapidFall(delta: delta)
    }

    mutating func reset() {
        lastValidPrice = nil
        lastReactionDate = nil
    }
}

enum FloatingCharacterSpeechTrigger: Equatable {
    case ambient
    case click
    case doubleClick
    case impatient
    case hide
    case rapidRise(delta: Double)
    case rapidFall(delta: Double)
    case sleeping
    case wake
}

struct FloatingCharacterSpeechCatalog {
    static let ambientDelayRange: ClosedRange<TimeInterval> = 45...90
    static let displayDuration: TimeInterval = 3.5

    private static let happyAmbient = [
        "今天也在认真盯盘～",
        "金价会往哪边走呢？",
        "别忘了偶尔休息一下！",
        "我会一直帮你看着的～",
    ]
    private static let sadAmbient = [
        "先别慌，再观察一下……",
        "跌一点也要保持冷静。",
        "我会继续认真盯盘的！",
        "希望下一次刷新能涨回来。",
    ]
    private static let happyClick = ["收到！继续盯盘～", "嘿嘿，被发现啦！", "今天也要好运！"]
    private static let sadClick = ["我没事，再看看吧……", "再点一下也不会涨啦。", "陪我等它涨回来吧。"]

    static func text(for trigger: FloatingCharacterSpeechTrigger, emotion: FloatingCharacterEmotion) -> String {
        switch trigger {
        case .ambient:
            return (emotion == .sad ? sadAmbient : happyAmbient).randomElement() ?? "继续盯盘～"
        case .click:
            return (emotion == .sad ? sadClick : happyClick).randomElement() ?? "你好呀！"
        case .doubleClick:
            return emotion == .sad ? "哼！看我生气给你看！" : "双击收到，庆祝一下！"
        case .impatient:
            return "别再点啦，我要不耐烦了！"
        case .hide:
            return "哼，我先躲到牌子后面！"
        case let .rapidRise(delta):
            return String(format: "哇！刚刚一下涨了 %.2f 元！", delta)
        case let .rapidFall(delta):
            return String(format: "呜……刚刚一下跌了 %.2f 元。", abs(delta))
        case .sleeping:
            return "Zzz…"
        case .wake:
            return "醒啦，继续盯盘！"
        }
    }
}

struct FloatingCharacterSpeechBubbleLayout {
    static let size = NSSize(width: 196, height: 68)
    static let spacing: CGFloat = 6

    static func frame(anchor: NSRect, visibleFrame: NSRect) -> (frame: NSRect, pointsDown: Bool) {
        var origin = NSPoint(
            x: anchor.midX - size.width / 2,
            y: anchor.maxY + spacing
        )
        var pointsDown = true
        if origin.y + size.height > visibleFrame.maxY {
            origin.y = anchor.minY - size.height - spacing
            pointsDown = false
        }
        origin.x = max(visibleFrame.minX, min(origin.x, visibleFrame.maxX - size.width))
        origin.y = max(visibleFrame.minY, min(origin.y, visibleFrame.maxY - size.height))
        return (NSRect(origin: origin, size: size), pointsDown)
    }
}

struct FloatingCharacterAmbientMotion {
    static let scaleFrom: CGFloat = 0.985
    static let scaleTo: CGFloat = 1.020
    static let scaleCycleDuration: TimeInterval = 2.6

    static let floatFrom: CGFloat = -3
    static let floatTo: CGFloat = 5
    static let floatCycleDuration: TimeInterval = 3.2

    static let swayAngle: CGFloat = 0.8 * .pi / 180
    static let swayCycleDuration: TimeInterval = 4.4
}

enum FloatingCharacterAnimation: Equatable {
    case bounce
    case shake
    case sway
    case nod
    case hop
    case tilt
    case clap
    case dance
    case pop
    case sigh
    case tremble
    case shiver
}

enum FloatingCharacterPose: CaseIterable {
    case happy
    case happyCheer
    case happyHeart
    case happySleepy
    case happyWave
    case happyWink
    case happyClap
    case happyDance
    case happyThumbsUp
    case sad
    case sadStomp
    case sadTear
    case sadTurn
    case sadPout
    case sadHide
    case sadSigh
    case sadFacepalm
    case sadShiver

    var resourceName: String {
        switch self {
        case .happy: return "character-happy"
        case .happyCheer: return "character-happy-cheer"
        case .happyHeart: return "character-happy-heart"
        case .happySleepy: return "character-happy-sleepy"
        case .happyWave: return "character-happy-wave"
        case .happyWink: return "character-happy-wink"
        case .happyClap: return "character-happy-clap"
        case .happyDance: return "character-happy-dance"
        case .happyThumbsUp: return "character-happy-thumbs-up"
        case .sad: return "character-sad"
        case .sadStomp: return "character-sad-stomp"
        case .sadTear: return "character-sad-tear"
        case .sadTurn: return "character-sad-turn"
        case .sadPout: return "character-sad-pout"
        case .sadHide: return "character-sad-hide"
        case .sadSigh: return "character-sad-sigh"
        case .sadFacepalm: return "character-sad-facepalm"
        case .sadShiver: return "character-sad-shiver"
        }
    }

    /// The empty area of the sign in image coordinates, with an origin at the top-left.
    var normalizedSignRect: NSRect {
        switch self {
        case .happy:
            return NSRect(x: 0.235, y: 0.470, width: 0.395, height: 0.145)
        case .happyCheer:
            return NSRect(x: 0.235, y: 0.450, width: 0.422, height: 0.190)
        case .happyHeart:
            return NSRect(x: 0.251, y: 0.474, width: 0.450, height: 0.179)
        case .happySleepy:
            return NSRect(x: 0.255, y: 0.478, width: 0.447, height: 0.175)
        case .happyWave:
            return NSRect(x: 0.245, y: 0.465, width: 0.405, height: 0.150)
        case .happyWink:
            return NSRect(x: 0.275, y: 0.485, width: 0.410, height: 0.145)
        case .happyClap:
            return NSRect(x: 0.303, y: 0.498, width: 0.355, height: 0.162)
        case .happyDance:
            return NSRect(x: 0.283, y: 0.439, width: 0.332, height: 0.141)
        case .happyThumbsUp:
            return NSRect(x: 0.279, y: 0.479, width: 0.408, height: 0.174)
        case .sad:
            return NSRect(x: 0.225, y: 0.485, width: 0.425, height: 0.155)
        case .sadStomp:
            return NSRect(x: 0.215, y: 0.478, width: 0.443, height: 0.183)
        case .sadTear:
            return NSRect(x: 0.199, y: 0.470, width: 0.462, height: 0.207)
        case .sadTurn:
            return NSRect(x: 0.203, y: 0.526, width: 0.498, height: 0.191)
        case .sadPout:
            return NSRect(x: 0.210, y: 0.485, width: 0.430, height: 0.160)
        case .sadHide:
            return NSRect(x: 0.260, y: 0.455, width: 0.455, height: 0.155)
        case .sadSigh:
            return NSRect(x: 0.281, y: 0.475, width: 0.400, height: 0.189)
        case .sadFacepalm:
            return NSRect(x: 0.266, y: 0.447, width: 0.416, height: 0.191)
        case .sadShiver:
            return NSRect(x: 0.303, y: 0.473, width: 0.348, height: 0.166)
        }
    }

    var emotion: FloatingCharacterEmotion {
        switch self {
        case .happy, .happyCheer, .happyHeart, .happySleepy, .happyWave, .happyWink,
             .happyClap, .happyDance, .happyThumbsUp:
            return .happy
        case .sad, .sadStomp, .sadTear, .sadTurn, .sadPout, .sadHide,
             .sadSigh, .sadFacepalm, .sadShiver:
            return .sad
        }
    }

    var animation: FloatingCharacterAnimation {
        switch self {
        case .happy, .sad: return .sway
        case .happyCheer, .happyWink: return .bounce
        case .happyHeart, .happyWave, .sadTear: return .sway
        case .happySleepy: return .nod
        case .sadStomp: return .hop
        case .sadTurn: return .tilt
        case .sadPout, .sadHide: return .shake
        case .happyClap: return .clap
        case .happyDance: return .dance
        case .happyThumbsUp: return .pop
        case .sadSigh: return .sigh
        case .sadFacepalm: return .tremble
        case .sadShiver: return .shiver
        }
    }

    static func basePose(for emotion: FloatingCharacterEmotion) -> FloatingCharacterPose {
        emotion == .sad ? .sad : .happy
    }

    static func actions(for emotion: FloatingCharacterEmotion) -> [FloatingCharacterPose] {
        emotion == .sad
            ? [.sadPout, .sadHide, .sadStomp, .sadTear, .sadTurn, .sadSigh, .sadFacepalm, .sadShiver]
            : [.happyWave, .happyWink, .happyCheer, .happyHeart, .happySleepy,
               .happyClap, .happyDance, .happyThumbsUp]
    }
}

enum FloatingCharacterMotionState: Equatable {
    case hidden
    case paused
    case ambient
    case action
    case sleeping
}

struct FloatingCharacterMotionPolicy {
    static let idleThreshold: TimeInterval = 5 * 60
    static let activityCheckInterval: TimeInterval = 30
    static let sleepingActivityCheckInterval: TimeInterval = 5

    static func allowsAmbientMotion(
        isVisible: Bool,
        isScreenAwake: Bool,
        isSessionActive: Bool,
        isLowPowerModeEnabled: Bool,
        idleDuration: TimeInterval
    ) -> Bool {
        isVisible
            && isScreenAwake
            && isSessionActive
            && !isLowPowerModeEnabled
            && idleDuration < idleThreshold
    }
}

@MainActor
final class FloatingCharacterController: NSObject {
    static let defaultSize = FloatingCharacterSizeOption.defaultOption.size

    private enum PreferenceKey {
        static let originX = "floatingCharacterOriginX"
        static let originY = "floatingCharacterOriginY"
        static let screenNumber = "floatingCharacterScreenNumber"
        static let presentationMode = "floatingCharacterPresentationMode"
        static let dockEdge = "floatingCharacterDockEdge"
    }

    private let defaults: UserDefaults
    private let idleTimeProvider: () -> TimeInterval
    private let nowProvider: () -> Date
    private let panel: FloatingCharacterPanel
    private let characterView: FloatingCharacterView
    private let speechBubbleController: FloatingCharacterSpeechBubbleController
    private var marketReactionDetector = FloatingCharacterMarketReactionDetector()
    private var clickSequence = FloatingCharacterClickSequence()
    private var emotion: FloatingCharacterEmotion = .happy
    private var isVisible = false
    private var isScreenAwake = true
    private var isSessionActive = true
    private var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var lastActionPose: FloatingCharacterPose?
    private var pendingDockEdge: FloatingCharacterDockEdge?
    private weak var pendingDockScreen: NSScreen?
    private var remainingDockedBlinks = 0
    private var isDockedClickSequence = false
    private var currentActivityCheckInterval: TimeInterval?
    private var interactionAnimationGeneration = 0
    private(set) var motionState: FloatingCharacterMotionState = .hidden
    private(set) var sizeOption: FloatingCharacterSizeOption = .defaultOption
    private(set) var presentationMode: FloatingCharacterPresentationMode = .full
    var panelSize: NSSize { panel.frame.size }

    nonisolated(unsafe) private var actionTimer: Timer?
    nonisolated(unsafe) private var ambientActionTimer: Timer?
    nonisolated(unsafe) private var dockedBlinkScheduleTimer: Timer?
    nonisolated(unsafe) private var dockedBlinkFrameTimer: Timer?
    nonisolated(unsafe) private var ambientSpeechTimer: Timer?
    nonisolated(unsafe) private var activityTimer: Timer?
    nonisolated(unsafe) private var pendingSingleClickTimer: Timer?
    nonisolated(unsafe) private var dragSettleTimer: Timer?
    nonisolated(unsafe) private var defaultCenterObservers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var workspaceObservers: [NSObjectProtocol] = []

    init(
        defaults: UserDefaults = .standard,
        idleTimeProvider: @escaping () -> TimeInterval = {
            CGEventSource.secondsSinceLastEventType(
                .combinedSessionState,
                eventType: CGEventType(rawValue: UInt32.max)!
            )
        },
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.idleTimeProvider = idleTimeProvider
        self.nowProvider = nowProvider
        self.characterView = FloatingCharacterView(frame: NSRect(origin: .zero, size: Self.defaultSize))
        self.speechBubbleController = FloatingCharacterSpeechBubbleController()
        self.panel = FloatingCharacterPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = characterView

        characterView.onPointerDown = { [weak self] in
            self?.preparePointerInteraction()
        }
        characterView.onClick = { [weak self] in
            self?.handleClick()
        }
        characterView.onDragBegan = { [weak self] in
            self?.beginDragInteraction()
        }
        characterView.onDrag = { [weak self] origin, pointer, delta in
            self?.handleDrag(to: origin, pointer: pointer, delta: delta)
        }
        characterView.onDragEnded = { [weak self] pointer, velocity in
            self?.finishDrag(at: pointer, velocity: velocity)
        }

        restorePosition()
        installSystemObservers()
    }

    deinit {
        actionTimer?.invalidate()
        ambientActionTimer?.invalidate()
        dockedBlinkScheduleTimer?.invalidate()
        dockedBlinkFrameTimer?.invalidate()
        ambientSpeechTimer?.invalidate()
        activityTimer?.invalidate()
        pendingSingleClickTimer?.invalidate()
        dragSettleTimer?.invalidate()
        for observer in defaultCenterObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func installSystemObservers() {
        let screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.keepPanelOnScreen()
            }
        }
        defaultCenterObservers.append(screenObserver)

        let powerObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
                self.evaluateMotionPolicy()
            }
        }
        defaultCenterObservers.append(powerObserver)

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isScreenAwake = false
                self?.pauseAllMotion()
            }
        })
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isScreenAwake = true
                self?.evaluateMotionPolicy()
            }
        })
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isSessionActive = false
                self?.pauseAllMotion()
            }
        })
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isSessionActive = true
                self?.evaluateMotionPolicy()
            }
        })
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        if visible {
            characterView.resumeRendering()
            keepPanelOnScreen()
            panel.orderFrontRegardless()
            startActivityMonitoring()
            evaluateMotionPolicy()
        } else {
            stopAllTimers()
            clickSequence = FloatingCharacterClickSequence()
            motionState = .hidden
            characterView.stopAllAnimations()
            characterView.releaseRenderedAssets()
            speechBubbleController.dismiss()
            panel.orderOut(nil)
        }
    }

    func update(price: String, numericPrice: Double, isNegative: Bool?) {
        let nextEmotion = FloatingCharacterEmotion(isNegative: isNegative)
        characterView.price = price
        characterView.priceTrend = FloatingCharacterPriceTrend(isNegative: isNegative)

        if nextEmotion != emotion {
            emotion = nextEmotion
            lastActionPose = nil
            if motionState != .sleeping {
                stopActionTimers()
                characterView.stopAllAnimations()
                characterView.pose = .basePose(for: emotion)
                evaluateMotionPolicy()
            }
        } else if motionState != .action, motionState != .sleeping {
            characterView.pose = .basePose(for: emotion)
        }

        if let reaction = marketReactionDetector.process(price: numericPrice, at: nowProvider()) {
            handleMarketReaction(reaction)
        }
    }

    func resetQuoteHistory() {
        marketReactionDetector.reset()
    }

    func setSize(_ option: FloatingCharacterSizeOption) {
        let targetSize: NSSize
        switch presentationMode {
        case .full:
            targetSize = option.size
        case .docked:
            targetSize = option.dockedSize
        }
        guard option != sizeOption || panel.frame.size != targetSize else { return }
        sizeOption = option

        let oldFrame = panel.frame
        let newSize = targetSize
        let resizedFrame = NSRect(
            x: oldFrame.midX - newSize.width / 2,
            y: oldFrame.midY - newSize.height / 2,
            width: newSize.width,
            height: newSize.height
        )
        panel.setFrame(resizedFrame, display: panel.isVisible)
        keepPanelOnScreen()
    }

    private func handleClick() {
        guard isVisible, isScreenAwake, isSessionActive else { return }
        if motionState == .sleeping {
            clickSequence.resetBurst()
            wakeFromSleep(showSpeech: true)
            evaluateMotionPolicy()
            return
        }
        guard !isLowPowerModeEnabled else { return }

        let reaction = clickSequence.register(
            at: nowProvider(),
            doubleClickInterval: NSEvent.doubleClickInterval
        )
        switch reaction {
        case .pendingSingle:
            schedulePendingSingleClick()
        case .doubleClick:
            cancelPendingSingleClick()
            performClickReaction(.doubleClick)
        case .impatient:
            cancelPendingSingleClick()
            performClickReaction(.impatient)
        case .hide:
            cancelPendingSingleClick()
            performClickReaction(.hide)
        case .ignoredDuringCooldown:
            cancelPendingSingleClick()
            if motionState != .action {
                characterView.stopAllAnimations()
                motionState = .paused
                evaluateMotionPolicy()
            }
        }
    }

    private func schedulePendingSingleClick() {
        pendingSingleClickTimer?.invalidate()
        pendingSingleClickTimer = makeTimer(
            interval: NSEvent.doubleClickInterval,
            repeats: false
        ) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pendingSingleClickTimer = nil
                self.performClickReaction(.pendingSingle)
            }
        }
    }

    private func cancelPendingSingleClick() {
        pendingSingleClickTimer?.invalidate()
        pendingSingleClickTimer = nil
    }

    private func performClickReaction(_ reaction: FloatingCharacterClickReaction) {
        let pose: FloatingCharacterPose?
        let speech: FloatingCharacterSpeechTrigger
        let duration: TimeInterval
        let dockedBlinkCount: Int

        switch reaction {
        case .pendingSingle:
            pose = nil
            speech = .click
            duration = FloatingCharacterActionTiming.actionDuration
            dockedBlinkCount = 2
        case .doubleClick:
            pose = emotion == .sad
                ? .sadStomp
                : ([.happyDance, .happyCheer].randomElement() ?? .happyDance)
            speech = .doubleClick
            duration = FloatingCharacterActionTiming.actionDuration
            dockedBlinkCount = 4
        case .impatient:
            pose = [.sadPout, .sadFacepalm].randomElement() ?? .sadPout
            speech = .impatient
            duration = FloatingCharacterActionTiming.actionDuration
            dockedBlinkCount = 5
        case .hide:
            pose = .sadHide
            speech = .hide
            duration = FloatingCharacterClickSequence.hideDuration
            dockedBlinkCount = 6
        case .ignoredDuringCooldown:
            return
        }

        switch presentationMode {
        case .full:
            playAction(pose: pose, duration: duration)
        case let .docked(edge):
            playDockedBlinkSequence(count: dockedBlinkCount, isClick: true)
            if reaction == .impatient || reaction == .hide {
                characterView.playDockPeekAnimation(edge: edge, emphasized: true)
            }
        }
        showSpeech(trigger: speech)
    }

    private func handleMarketReaction(_ reaction: FloatingCharacterMarketReaction) {
        guard isVisible, isScreenAwake, isSessionActive else { return }
        cancelDragSettlement()
        cancelPendingSingleClick()
        clickSequence.resetBurst()
        if motionState == .sleeping {
            wakeFromSleep(showSpeech: false)
        }

        let pose: FloatingCharacterPose
        let speechTrigger: FloatingCharacterSpeechTrigger
        switch reaction {
        case let .rapidRise(delta):
            pose = [.happyCheer, .happyDance, .happyThumbsUp].randomElement() ?? .happyCheer
            speechTrigger = .rapidRise(delta: delta)
        case let .rapidFall(delta):
            pose = [.sadFacepalm, .sadHide, .sadShiver].randomElement() ?? .sadFacepalm
            speechTrigger = .rapidFall(delta: delta)
        }

        switch presentationMode {
        case .full:
            playAction(pose: pose)
        case .docked:
            playDockedBlinkSequence(count: 3, isClick: true)
        }
        showSpeech(trigger: speechTrigger)
    }

    private func showSpeech(
        trigger: FloatingCharacterSpeechTrigger,
        duration: TimeInterval? = FloatingCharacterSpeechCatalog.displayDuration
    ) {
        guard isVisible,
              let targetScreen = panel.screen ?? screen(containing: panel.frame) ?? NSScreen.main else { return }
        speechBubbleController.show(
            text: FloatingCharacterSpeechCatalog.text(for: trigger, emotion: emotion),
            anchor: panel.frame,
            visibleFrame: targetScreen.visibleFrame,
            duration: duration
        )
    }

    private func repositionSpeechBubble() {
        guard let targetScreen = panel.screen ?? screen(containing: panel.frame) ?? NSScreen.main else { return }
        speechBubbleController.reposition(
            anchor: panel.frame,
            visibleFrame: targetScreen.visibleFrame
        )
    }

    private func playAction(
        pose requestedPose: FloatingCharacterPose? = nil,
        duration: TimeInterval = FloatingCharacterActionTiming.actionDuration
    ) {
        ambientActionTimer?.invalidate()
        ambientActionTimer = nil
        ambientSpeechTimer?.invalidate()
        ambientSpeechTimer = nil
        actionTimer?.invalidate()

        let pose: FloatingCharacterPose
        if let requestedPose {
            pose = requestedPose
        } else {
            var candidates = FloatingCharacterPose.actions(for: emotion)
            if candidates.count > 1, let lastActionPose {
                candidates.removeAll { $0 == lastActionPose }
            }
            pose = candidates.randomElement() ?? .basePose(for: emotion)
        }
        lastActionPose = pose
        motionState = .action
        characterView.stopAllAnimations()
        characterView.pose = pose
        characterView.play(animation: pose.animation)

        actionTimer = makeTimer(
            interval: duration,
            repeats: false
        ) { [weak self] in
            Task { @MainActor in
                self?.finishAction()
            }
        }
    }

    private func finishAction() {
        actionTimer?.invalidate()
        actionTimer = nil
        characterView.stopAllAnimations()
        characterView.pose = .basePose(for: emotion)
        // Leave the action state before re-evaluating. Otherwise the policy's
        // action guard treats the completed action as still active and never
        // restarts the ambient breathing/float/sway animations.
        motionState = .paused
        evaluateMotionPolicy()
    }

    #if DEBUG
    func triggerActionForTesting() {
        playAction()
    }

    func finishActionForTesting() {
        finishAction()
    }

    func evaluateMotionPolicyForTesting() {
        evaluateMotionPolicy()
    }
    #endif

    private func startActivityMonitoring(
        interval: TimeInterval = FloatingCharacterMotionPolicy.activityCheckInterval
    ) {
        guard activityTimer == nil || currentActivityCheckInterval != interval else { return }
        activityTimer?.invalidate()
        activityTimer = nil
        currentActivityCheckInterval = interval
        activityTimer = makeTimer(
            interval: interval,
            repeats: true
        ) { [weak self] in
            Task { @MainActor in
                self?.evaluateMotionPolicy()
            }
        }
    }

    private func evaluateMotionPolicy() {
        guard isVisible else {
            motionState = .hidden
            return
        }

        let idleDuration = idleTimeProvider()
        guard isScreenAwake, isSessionActive else {
            pauseAllMotion()
            speechBubbleController.dismiss()
            return
        }
        if idleDuration >= FloatingCharacterMotionPolicy.idleThreshold {
            enterSleepMode()
            return
        }
        if motionState == .sleeping {
            wakeFromSleep(showSpeech: true)
        }

        let ambientAllowed = FloatingCharacterMotionPolicy.allowsAmbientMotion(
            isVisible: isVisible,
            isScreenAwake: isScreenAwake,
            isSessionActive: isSessionActive,
            isLowPowerModeEnabled: isLowPowerModeEnabled,
            idleDuration: idleDuration
        )

        if ambientAllowed {
            guard motionState != .action else { return }
            beginAmbientMotion()
        } else if motionState != .action {
            pauseAmbientMotion()
        }
    }

    private func beginAmbientMotion() {
        motionState = .ambient
        startActivityMonitoring()
        switch presentationMode {
        case .full:
            characterView.startAmbientAnimation()
            scheduleAmbientActionIfNeeded()
        case .docked:
            characterView.stopAllAnimations()
            scheduleDockedBlinkIfNeeded()
        }
        scheduleAmbientSpeechIfNeeded()
    }

    private func scheduleAmbientActionIfNeeded() {
        guard ambientActionTimer == nil, motionState == .ambient else { return }
        ambientActionTimer = makeTimer(
            interval: .random(in: FloatingCharacterActionTiming.ambientDelayRange),
            repeats: false
        ) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.ambientActionTimer = nil
                guard self.motionState == .ambient else { return }
                self.playAction()
            }
        }
    }

    private func scheduleAmbientSpeechIfNeeded() {
        guard ambientSpeechTimer == nil,
              motionState == .ambient,
              !isLowPowerModeEnabled else { return }
        ambientSpeechTimer = makeTimer(
            interval: .random(in: FloatingCharacterSpeechCatalog.ambientDelayRange),
            repeats: false
        ) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.ambientSpeechTimer = nil
                guard self.motionState == .ambient else { return }
                self.showSpeech(trigger: .ambient)
                self.scheduleAmbientSpeechIfNeeded()
            }
        }
    }

    private func enterSleepMode() {
        guard motionState != .sleeping else { return }
        cancelDragSettlement()
        cancelPendingSingleClick()
        clickSequence.resetBurst()
        stopActionTimers()
        characterView.stopAllAnimations()
        characterView.isDockedBlinking = false
        if case .full = presentationMode {
            characterView.pose = .happySleepy
        }
        motionState = .sleeping
        showSpeech(trigger: .sleeping, duration: nil)
        startActivityMonitoring(interval: FloatingCharacterMotionPolicy.sleepingActivityCheckInterval)
    }

    private func wakeFromSleep(showSpeech: Bool) {
        guard motionState == .sleeping else { return }
        speechBubbleController.dismiss()
        characterView.stopAllAnimations()
        characterView.pose = .basePose(for: emotion)
        motionState = .paused
        startActivityMonitoring()
        if showSpeech {
            self.showSpeech(trigger: .wake)
        }
    }

    private func scheduleDockedBlinkIfNeeded() {
        guard dockedBlinkScheduleTimer == nil,
              motionState == .ambient,
              case .docked = presentationMode else { return }
        dockedBlinkScheduleTimer = makeTimer(
            interval: .random(in: FloatingCharacterDockedTiming.ambientBlinkDelayRange),
            repeats: false
        ) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.dockedBlinkScheduleTimer = nil
                guard self.motionState == .ambient else { return }
                self.playDockedBlinkSequence(count: 1, isClick: false)
            }
        }
    }

    private func playDockedBlinkSequence(count: Int, isClick: Bool) {
        guard count > 0, case .docked = presentationMode else { return }
        dockedBlinkScheduleTimer?.invalidate()
        dockedBlinkScheduleTimer = nil
        dockedBlinkFrameTimer?.invalidate()
        dockedBlinkFrameTimer = nil
        remainingDockedBlinks = count
        isDockedClickSequence = isClick
        if isClick {
            motionState = .action
        }
        beginNextDockedBlink()
    }

    private func beginNextDockedBlink() {
        guard remainingDockedBlinks > 0, case .docked = presentationMode else {
            finishDockedBlinkSequence()
            return
        }
        characterView.isDockedBlinking = true
        dockedBlinkFrameTimer = makeTimer(
            interval: FloatingCharacterDockedTiming.closedFrameDuration,
            repeats: false
        ) { [weak self] in
            Task { @MainActor in
                self?.finishCurrentDockedBlink()
            }
        }
    }

    private func finishCurrentDockedBlink() {
        dockedBlinkFrameTimer?.invalidate()
        dockedBlinkFrameTimer = nil
        characterView.isDockedBlinking = false
        remainingDockedBlinks -= 1
        guard remainingDockedBlinks > 0 else {
            finishDockedBlinkSequence()
            return
        }
        dockedBlinkFrameTimer = makeTimer(
            interval: FloatingCharacterDockedTiming.betweenBlinksDuration,
            repeats: false
        ) { [weak self] in
            Task { @MainActor in
                self?.beginNextDockedBlink()
            }
        }
    }

    private func finishDockedBlinkSequence() {
        dockedBlinkFrameTimer?.invalidate()
        dockedBlinkFrameTimer = nil
        characterView.isDockedBlinking = false
        remainingDockedBlinks = 0
        let wasClickSequence = isDockedClickSequence
        isDockedClickSequence = false
        if wasClickSequence {
            motionState = .paused
            evaluateMotionPolicy()
        } else if motionState == .ambient {
            scheduleDockedBlinkIfNeeded()
        }
    }

    private func cancelDockedBlinkTimers() {
        dockedBlinkScheduleTimer?.invalidate()
        dockedBlinkScheduleTimer = nil
        dockedBlinkFrameTimer?.invalidate()
        dockedBlinkFrameTimer = nil
        remainingDockedBlinks = 0
        isDockedClickSequence = false
        characterView.isDockedBlinking = false
    }

    private func pauseAmbientMotion() {
        ambientActionTimer?.invalidate()
        ambientActionTimer = nil
        ambientSpeechTimer?.invalidate()
        ambientSpeechTimer = nil
        cancelDockedBlinkTimers()
        motionState = .paused
        characterView.stopAllAnimations()
        characterView.pose = .basePose(for: emotion)
    }

    private func pauseAllMotion() {
        guard isVisible else {
            motionState = .hidden
            return
        }
        cancelDragSettlement()
        cancelPendingSingleClick()
        clickSequence.resetBurst()
        stopActionTimers()
        pauseAmbientMotion()
        speechBubbleController.dismiss()
    }

    private func stopActionTimers() {
        actionTimer?.invalidate()
        actionTimer = nil
        ambientActionTimer?.invalidate()
        ambientActionTimer = nil
        ambientSpeechTimer?.invalidate()
        ambientSpeechTimer = nil
        cancelDockedBlinkTimers()
    }

    private func stopAllTimers() {
        stopActionTimers()
        cancelPendingSingleClick()
        dragSettleTimer?.invalidate()
        dragSettleTimer = nil
        interactionAnimationGeneration += 1
        activityTimer?.invalidate()
        activityTimer = nil
        currentActivityCheckInterval = nil
    }

    private func makeTimer(
        interval: TimeInterval,
        repeats: Bool,
        handler: @escaping @Sendable () -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats) { _ in
            handler()
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func beginDragInteraction() {
        if motionState == .sleeping {
            wakeFromSleep(showSpeech: false)
        }
        cancelPendingSingleClick()
        clickSequence.resetBurst()
        cancelDragSettlement()
        stopActionTimers()
        characterView.stopAllAnimations()
        speechBubbleController.dismiss()
        motionState = .paused
    }

    private func preparePointerInteraction() {
        cancelDragSettlement()
    }

    private func cancelDragSettlement() {
        interactionAnimationGeneration += 1
        dragSettleTimer?.invalidate()
        dragSettleTimer = nil
    }

    private func handleDrag(to requestedOrigin: NSPoint, pointer: NSPoint, delta: NSPoint) {
        if motionState == .sleeping {
            wakeFromSleep(showSpeech: true)
            evaluateMotionPolicy()
        }
        switch presentationMode {
        case .full:
            let targetScreen = screen(containing: pointer)
                ?? screen(containing: NSRect(origin: requestedOrigin, size: panel.frame.size))
                ?? panel.screen
                ?? NSScreen.main
            panel.setFrameOrigin(clampedOrigin(requestedOrigin, in: targetScreen?.visibleFrame))
            repositionSpeechBubble()
            updateDockCandidate(at: pointer, screen: targetScreen)

        case let .docked(edge):
            guard !FloatingCharacterDockLayout.shouldRestore(
                horizontalDrag: delta.x,
                from: edge
            ) else {
                restoreFullCharacter(from: edge, at: pointer)
                return
            }
            let targetScreen = panel.screen
                ?? screen(containing: pointer)
                ?? NSScreen.main
            guard let visibleFrame = targetScreen?.visibleFrame else { return }
            panel.setFrameOrigin(FloatingCharacterDockLayout.dockedOrigin(
                edge: edge,
                proposedY: requestedOrigin.y,
                size: panel.frame.size,
                visibleFrame: visibleFrame
            ))
            repositionSpeechBubble()
        }
    }

    private func updateDockCandidate(at pointer: NSPoint, screen: NSScreen?) {
        guard let screen,
              let edge = FloatingCharacterDockLayout.edge(
                for: pointer,
                in: screen.visibleFrame
              ) else {
            pendingDockEdge = nil
            pendingDockScreen = nil
            panel.alphaValue = 1
            return
        }
        pendingDockEdge = edge
        pendingDockScreen = screen
        panel.alphaValue = 0.82
    }

    private func finishDrag(at pointer: NSPoint, velocity: NSPoint) {
        panel.alphaValue = 1
        if case .full = presentationMode {
            let targetScreen = screen(containing: pointer) ?? pendingDockScreen
            let edge = targetScreen.flatMap {
                FloatingCharacterDockLayout.edge(for: pointer, in: $0.visibleFrame)
            }
            if let edge, let targetScreen {
                enterDockedMode(edge: edge, screen: targetScreen)
                pendingDockEdge = nil
                pendingDockScreen = nil
                return
            }
        }
        pendingDockEdge = nil
        pendingDockScreen = nil
        switch presentationMode {
        case .full:
            animateReleaseInertia(velocity: velocity, pointer: pointer)
        case let .docked(edge):
            characterView.playDockPeekAnimation(edge: edge, emphasized: false)
            finishDragSettlement(after: FloatingCharacterDragPhysics.landingDuration)
        }
    }

    private var shouldReduceInteractiveMotion: Bool {
        isLowPowerModeEnabled || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func animateReleaseInertia(velocity: NSPoint, pointer: NSPoint) {
        let targetScreen = screen(containing: pointer) ?? panel.screen ?? NSScreen.main
        let displacement = shouldReduceInteractiveMotion
            ? NSPoint.zero
            : FloatingCharacterDragPhysics.projectedDisplacement(for: velocity)
        let requestedOrigin = NSPoint(
            x: panel.frame.origin.x + displacement.x,
            y: panel.frame.origin.y + displacement.y
        )
        let targetOrigin = clampedOrigin(requestedOrigin, in: targetScreen?.visibleFrame)

        guard displacement != .zero, targetOrigin != panel.frame.origin else {
            if !shouldReduceInteractiveMotion {
                characterView.playDragLandingAnimation(horizontalVelocity: velocity.x)
                finishDragSettlement(after: FloatingCharacterDragPhysics.landingDuration)
            } else {
                finishDragSettlement(after: 0)
            }
            return
        }

        interactionAnimationGeneration += 1
        let generation = interactionAnimationGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = FloatingCharacterDragPhysics.inertiaDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrameOrigin(targetOrigin)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.interactionAnimationGeneration == generation else { return }
                self.repositionSpeechBubble()
                self.characterView.playDragLandingAnimation(horizontalVelocity: velocity.x)
                self.finishDragSettlement(after: FloatingCharacterDragPhysics.landingDuration)
            }
        }
    }

    private func finishDragSettlement(after delay: TimeInterval) {
        dragSettleTimer?.invalidate()
        guard delay > 0 else {
            persistPosition()
            motionState = .paused
            evaluateMotionPolicy()
            return
        }
        dragSettleTimer = makeTimer(interval: delay, repeats: false) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.dragSettleTimer = nil
                self.persistPosition()
                self.motionState = .paused
                self.evaluateMotionPolicy()
            }
        }
    }

    private func enterDockedMode(edge: FloatingCharacterDockEdge, screen: NSScreen) {
        stopActionTimers()
        characterView.stopAllAnimations()
        speechBubbleController.dismiss()
        let previousMidY = panel.frame.midY
        presentationMode = .docked(edge)
        characterView.presentationMode = presentationMode
        let size = sizeOption.dockedSize
        let origin = FloatingCharacterDockLayout.dockedOrigin(
            edge: edge,
            proposedY: previousMidY - size.height / 2,
            size: size,
            visibleFrame: screen.visibleFrame
        )
        motionState = .paused
        let targetFrame = NSRect(origin: origin, size: size)
        guard !shouldReduceInteractiveMotion else {
            panel.setFrame(targetFrame, display: panel.isVisible)
            persistPosition()
            evaluateMotionPolicy()
            return
        }

        interactionAnimationGeneration += 1
        let generation = interactionAnimationGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = FloatingCharacterDragPhysics.dockingDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(targetFrame, display: panel.isVisible)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.interactionAnimationGeneration == generation else { return }
                self.characterView.playDockPeekAnimation(edge: edge, emphasized: false)
                self.finishDragSettlement(after: FloatingCharacterDragPhysics.landingDuration)
            }
        }
    }

    private func restoreFullCharacter(from edge: FloatingCharacterDockEdge, at pointer: NSPoint) {
        stopActionTimers()
        characterView.stopAllAnimations()
        let compactFrame = panel.frame
        let targetScreen = screen(containing: pointer) ?? panel.screen ?? NSScreen.main
        let size = sizeOption.size
        let anchorX: CGFloat = edge == .left ? 0.2 : 0.8
        let anchorY = max(0.12, min(
            (pointer.y - compactFrame.minY) / max(compactFrame.height, 1),
            0.88
        ))
        let requestedOrigin = NSPoint(
            x: pointer.x - size.width * anchorX,
            y: pointer.y - size.height * anchorY
        )
        presentationMode = .full
        characterView.presentationMode = .full
        let origin = clampedOrigin(requestedOrigin, size: size, in: targetScreen?.visibleFrame)
        panel.setFrame(NSRect(origin: origin, size: size), display: panel.isVisible)
        repositionSpeechBubble()
        characterView.rebaseDrag(panelOrigin: origin, mouseLocation: pointer)
        motionState = .paused
    }

    private func persistPosition() {
        let origin = panel.frame.origin
        defaults.set(origin.x, forKey: PreferenceKey.originX)
        defaults.set(origin.y, forKey: PreferenceKey.originY)
        switch presentationMode {
        case .full:
            defaults.set("full", forKey: PreferenceKey.presentationMode)
            defaults.removeObject(forKey: PreferenceKey.dockEdge)
        case let .docked(edge):
            defaults.set("docked", forKey: PreferenceKey.presentationMode)
            defaults.set(edge.rawValue, forKey: PreferenceKey.dockEdge)
        }
        if let number = panel.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            defaults.set(number.intValue, forKey: PreferenceKey.screenNumber)
        }
    }

    private func restorePosition() {
        let hasSavedPosition = defaults.object(forKey: PreferenceKey.originX) != nil
            && defaults.object(forKey: PreferenceKey.originY) != nil

        let savedScreenNumber = defaults.integer(forKey: PreferenceKey.screenNumber)
        let savedScreen = NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number?.intValue == savedScreenNumber
        }

        if defaults.string(forKey: PreferenceKey.presentationMode) == "docked",
           let edgeValue = defaults.string(forKey: PreferenceKey.dockEdge),
           let edge = FloatingCharacterDockEdge(rawValue: edgeValue),
           defaults.object(forKey: PreferenceKey.originY) != nil,
           let targetScreen = savedScreen ?? NSScreen.main {
            presentationMode = .docked(edge)
            characterView.presentationMode = presentationMode
            let size = sizeOption.dockedSize
            let origin = FloatingCharacterDockLayout.dockedOrigin(
                edge: edge,
                proposedY: defaults.double(forKey: PreferenceKey.originY),
                size: size,
                visibleFrame: targetScreen.visibleFrame
            )
            panel.setFrame(NSRect(origin: origin, size: size), display: false)
            return
        }

        guard hasSavedPosition else {
            let visibleFrame = NSScreen.main?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            panel.setFrameOrigin(NSPoint(
                x: visibleFrame.maxX - panel.frame.width - 20,
                y: visibleFrame.minY + 20
            ))
            return
        }

        let savedOrigin = NSPoint(
            x: defaults.double(forKey: PreferenceKey.originX),
            y: defaults.double(forKey: PreferenceKey.originY)
        )
        let targetScreen = savedScreen
            ?? screen(containing: NSRect(origin: savedOrigin, size: panel.frame.size))
            ?? NSScreen.main
        panel.setFrameOrigin(clampedOrigin(savedOrigin, in: targetScreen?.visibleFrame))
    }

    private func keepPanelOnScreen() {
        let targetScreen = panel.screen
            ?? screen(containing: panel.frame)
            ?? NSScreen.main
        switch presentationMode {
        case .full:
            panel.setFrameOrigin(clampedOrigin(panel.frame.origin, in: targetScreen?.visibleFrame))
        case let .docked(edge):
            if let visibleFrame = targetScreen?.visibleFrame {
                panel.setFrameOrigin(FloatingCharacterDockLayout.dockedOrigin(
                    edge: edge,
                    proposedY: panel.frame.origin.y,
                    size: panel.frame.size,
                    visibleFrame: visibleFrame
                ))
            }
        }
        if panel.isVisible {
            persistPosition()
        }
        repositionSpeechBubble()
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    private func screen(containing frame: NSRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            lhs.visibleFrame.intersection(frame).width * lhs.visibleFrame.intersection(frame).height
                < rhs.visibleFrame.intersection(frame).width * rhs.visibleFrame.intersection(frame).height
        }
    }

    private func clampedOrigin(_ origin: NSPoint, in visibleFrame: NSRect?) -> NSPoint {
        clampedOrigin(origin, size: panel.frame.size, in: visibleFrame)
    }

    private func clampedOrigin(_ origin: NSPoint, size: NSSize, in visibleFrame: NSRect?) -> NSPoint {
        guard let visibleFrame else { return origin }
        return NSPoint(
            x: max(visibleFrame.minX, min(origin.x, visibleFrame.maxX - size.width)),
            y: max(visibleFrame.minY, min(origin.y, visibleFrame.maxY - size.height))
        )
    }
}

final class FloatingCharacterPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingCharacterSpeechBubbleController {
    private let panel: FloatingCharacterPanel
    private let bubbleView: FloatingCharacterSpeechBubbleView
    nonisolated(unsafe) private var dismissTimer: Timer?

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    init() {
        bubbleView = FloatingCharacterSpeechBubbleView(
            frame: NSRect(origin: .zero, size: FloatingCharacterSpeechBubbleLayout.size)
        )
        panel = FloatingCharacterPanel(
            contentRect: bubbleView.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = bubbleView
    }

    deinit {
        dismissTimer?.invalidate()
    }

    func show(
        text: String,
        anchor: NSRect,
        visibleFrame: NSRect,
        duration: TimeInterval?
    ) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        bubbleView.text = text
        applyLayout(anchor: anchor, visibleFrame: visibleFrame)
        panel.orderFrontRegardless()

        guard let duration else { return }
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissTimer = timer
    }

    func reposition(anchor: NSRect, visibleFrame: NSRect) {
        guard panel.isVisible else { return }
        applyLayout(anchor: anchor, visibleFrame: visibleFrame)
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel.orderOut(nil)
    }

    private func applyLayout(anchor: NSRect, visibleFrame: NSRect) {
        let layout = FloatingCharacterSpeechBubbleLayout.frame(
            anchor: anchor,
            visibleFrame: visibleFrame
        )
        bubbleView.pointsDown = layout.pointsDown
        panel.setFrame(layout.frame, display: panel.isVisible)
    }
}

@MainActor
final class FloatingCharacterSpeechBubbleView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")

    var text: String = "" {
        didSet { label.stringValue = text }
    }

    var pointsDown = true {
        didSet {
            needsLayout = true
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor(calibratedRed: 0.27, green: 0.18, blue: 0.38, alpha: 1)
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let body = bubbleBodyRect.insetBy(dx: 12, dy: 7)
        label.frame = body
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bodyPath = NSBezierPath(roundedRect: bubbleBodyRect, xRadius: 13, yRadius: 13)
        let fill = NSColor(calibratedRed: 1, green: 0.985, blue: 0.95, alpha: 0.97)
        let stroke = NSColor(calibratedRed: 0.48, green: 0.25, blue: 0.68, alpha: 0.9)
        fill.setFill()
        bodyPath.fill()
        stroke.setStroke()
        bodyPath.lineWidth = 1.5
        bodyPath.stroke()

        let tail = NSBezierPath()
        if pointsDown {
            tail.move(to: NSPoint(x: bounds.midX - 8, y: 12))
            tail.line(to: NSPoint(x: bounds.midX, y: 2))
            tail.line(to: NSPoint(x: bounds.midX + 8, y: 12))
        } else {
            tail.move(to: NSPoint(x: bounds.midX - 8, y: bounds.maxY - 12))
            tail.line(to: NSPoint(x: bounds.midX, y: bounds.maxY - 2))
            tail.line(to: NSPoint(x: bounds.midX + 8, y: bounds.maxY - 12))
        }
        tail.close()
        fill.setFill()
        tail.fill()
        stroke.setStroke()
        tail.lineWidth = 1.5
        tail.stroke()
    }

    private var bubbleBodyRect: NSRect {
        pointsDown
            ? NSRect(x: 1, y: 11, width: bounds.width - 2, height: bounds.height - 12)
            : NSRect(x: 1, y: 1, width: bounds.width - 2, height: bounds.height - 12)
    }
}

@MainActor
final class FloatingCharacterImageStore {
    static let shared = FloatingCharacterImageStore()
    static let maximumCachedImageCount = 8
    static let maximumCacheCost = 10 * 1024 * 1024

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = Self.maximumCachedImageCount
        cache.totalCostLimit = Self.maximumCacheCost
    }

    func image(named name: String) -> NSImage? {
        let key = name as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let image = Self.loadUncachedImage(named: name) else { return nil }
        cache.setObject(image, forKey: key, cost: Self.estimatedDecodedCost(of: image))
        return image
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    static func estimatedDecodedCost(width: Int, height: Int) -> Int {
        max(0, width) * max(0, height) * 4
    }

    private static func estimatedDecodedCost(of image: NSImage) -> Int {
        let representation = image.representations.max { lhs, rhs in
            lhs.pixelsWide * lhs.pixelsHigh < rhs.pixelsWide * rhs.pixelsHigh
        }
        return estimatedDecodedCost(
            width: representation?.pixelsWide ?? Int(image.size.width),
            height: representation?.pixelsHigh ?? Int(image.size.height)
        )
    }

    static func loadUncachedImage(named name: String) -> NSImage? {
        if let url = Bundle.main.url(
            forResource: name,
            withExtension: "png",
            subdirectory: "FloatingCharacter"
        ) {
            return NSImage(contentsOf: url)
        }
        if let url = Bundle.main.url(forResource: name, withExtension: "png") {
            return NSImage(contentsOf: url)
        }

        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: name, withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        #endif

        return nil
    }
}

@MainActor
final class FloatingCharacterView: NSView {
    static let ambientScaleAnimationKey = "characterAmbientScale"
    static let ambientFloatAnimationKey = "characterAmbientFloat"
    static let ambientSwayAnimationKey = "characterAmbientSway"
    static let clickActionAnimationKey = "characterClickAction"
    static let dragLandingAnimationKey = "characterDragLanding"
    static let dockPeekAnimationKey = "characterDockPeek"

    var onPointerDown: (() -> Void)?
    var onClick: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDrag: ((NSPoint, NSPoint, NSPoint) -> Void)?
    var onDragEnded: ((NSPoint, NSPoint) -> Void)?

    var price: String = "0.00" {
        didSet { needsDisplay = true }
    }

    var priceTrend: FloatingCharacterPriceTrend = .flat {
        didSet { needsDisplay = true }
    }

    var pose: FloatingCharacterPose = .happy {
        didSet {
            guard pose != oldValue else { return }
            updateRenderedImage(animated: true)
        }
    }

    var presentationMode: FloatingCharacterPresentationMode = .full {
        didSet {
            guard presentationMode != oldValue else { return }
            isDockedBlinking = false
            updateRenderedImage(animated: true)
        }
    }

    var isDockedBlinking = false {
        didSet {
            guard isDockedBlinking != oldValue, case .docked = presentationMode else { return }
            updateRenderedImage(animated: false)
        }
    }

    private var image: NSImage?
    private var isRenderingEnabled = false
    private var mouseDownLocation: NSPoint?
    private var panelOriginAtMouseDown: NSPoint?
    private var maximumDragDistance: CGFloat = 0
    private var didBeginDrag = false
    private var dragVelocityTracker = FloatingCharacterDragVelocityTracker()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.anchorPoint = NSPoint(x: 0.5, y: 0.5)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    func resumeRendering() {
        isRenderingEnabled = true
        updateRenderedImage(animated: false)
    }

    func releaseRenderedAssets() {
        isRenderingEnabled = false
        image = nil
        FloatingCharacterImageStore.shared.removeAll()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let image else { return }

        NSGraphicsContext.current?.imageInterpolation = .high
        NSGraphicsContext.saveGraphicsState()
        if case .docked(.left) = presentationMode {
            let transform = NSAffineTransform()
            transform.translateX(by: bounds.maxX, yBy: 0)
            transform.scaleX(by: -1, yBy: 1)
            transform.concat()
        }
        image.draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSGraphicsContext.restoreGraphicsState()
        drawPrice()
    }

    override func mouseDown(with event: NSEvent) {
        onPointerDown?()
        mouseDownLocation = NSEvent.mouseLocation
        panelOriginAtMouseDown = window?.frame.origin
        maximumDragDistance = 0
        didBeginDrag = false
        dragVelocityTracker.reset(point: NSEvent.mouseLocation, timestamp: event.timestamp)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownLocation, let panelOriginAtMouseDown else { return }
        let current = NSEvent.mouseLocation
        let delta = NSPoint(x: current.x - mouseDownLocation.x, y: current.y - mouseDownLocation.y)
        maximumDragDistance = max(maximumDragDistance, hypot(delta.x, delta.y))
        dragVelocityTracker.record(point: current, timestamp: event.timestamp)
        if !didBeginDrag, maximumDragDistance >= 4 {
            didBeginDrag = true
            onDragBegan?()
        }
        onDrag?(
            NSPoint(x: panelOriginAtMouseDown.x + delta.x, y: panelOriginAtMouseDown.y + delta.y),
            current,
            delta
        )
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownLocation = nil
            panelOriginAtMouseDown = nil
            maximumDragDistance = 0
        }

        if maximumDragDistance < 4 {
            onClick?()
        } else {
            let pointer = NSEvent.mouseLocation
            dragVelocityTracker.record(point: pointer, timestamp: event.timestamp)
            onDragEnded?(pointer, dragVelocityTracker.velocity())
        }
    }

    func rebaseDrag(panelOrigin: NSPoint, mouseLocation: NSPoint) {
        panelOriginAtMouseDown = panelOrigin
        mouseDownLocation = mouseLocation
    }

    func play(animation: FloatingCharacterAnimation) {
        stopMotionAnimations()
        let keyPath: String
        let values: [NSNumber]
        let duration: TimeInterval
        let repeatCount: Float
        switch animation {
        case .bounce:
            keyPath = "transform.translation.y"
            values = [0, 8, -2, 4, 0]
            duration = 0.65
            repeatCount = 1
        case .shake:
            keyPath = "transform.translation.x"
            values = [0, -6, 6, -5, 5, -2, 0]
            duration = 0.55
            repeatCount = 1
        case .sway:
            keyPath = "transform.rotation.z"
            values = [0, -0.035, 0.04, -0.02, 0]
            duration = 0.75
            repeatCount = 1
        case .nod:
            keyPath = "transform.translation.y"
            values = [0, -3, 1, -2, 0]
            duration = 0.8
            repeatCount = 1
        case .hop:
            keyPath = "transform.translation.y"
            values = [0, 12, 0, 6, 0]
            duration = 0.7
            repeatCount = 1
        case .tilt:
            keyPath = "transform.rotation.z"
            values = [0, 0.055, 0.025, 0.055, 0]
            duration = 0.8
            repeatCount = 1
        case .clap:
            keyPath = "transform.scale"
            values = [1, 1.035, 0.99, 1.03, 1]
            duration = 0.65
            repeatCount = 3
        case .dance:
            keyPath = "transform.rotation.z"
            values = [0, -0.06, 0.07, -0.04, 0.05, 0]
            duration = 1.2
            repeatCount = 2
        case .pop:
            keyPath = "transform.scale"
            values = [1, 0.92, 1.08, 0.98, 1.03, 1]
            duration = 0.8
            repeatCount = 2
        case .sigh:
            keyPath = "transform.translation.y"
            values = [0, -2, -7, -7, -3, 0]
            duration = 1.35
            repeatCount = 2
        case .tremble:
            keyPath = "transform.rotation.z"
            values = [0, 0.025, -0.025, 0.02, -0.02, 0]
            duration = 0.7
            repeatCount = 3
        case .shiver:
            keyPath = "transform.translation.x"
            values = [0, -4, 4, -3, 3, -2, 2, 0]
            duration = 0.45
            repeatCount = 5
        }

        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.duration = duration
        animation.repeatCount = repeatCount
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(animation, forKey: Self.clickActionAnimationKey)
    }

    func playDragLandingAnimation(horizontalVelocity: CGFloat) {
        layer?.removeAnimation(forKey: Self.dragLandingAnimationKey)
        let direction: CGFloat = horizontalVelocity >= 0 ? 1 : -1

        let landing = CAKeyframeAnimation(keyPath: "transform.translation.y")
        landing.values = [0, -12, 4, -5, 2, 0]
        landing.keyTimes = [0, 0.28, 0.48, 0.68, 0.84, 1]

        let sway = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        sway.values = [0, direction * 0.055, -direction * 0.035, direction * 0.018, 0]
        sway.keyTimes = [0, 0.30, 0.56, 0.80, 1]

        let squash = CAKeyframeAnimation(keyPath: "transform.scale")
        squash.values = [1, 0.96, 1.045, 0.985, 1]
        squash.keyTimes = [0, 0.30, 0.50, 0.78, 1]

        let group = CAAnimationGroup()
        group.animations = [landing, sway, squash]
        group.duration = FloatingCharacterDragPhysics.landingDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(group, forKey: Self.dragLandingAnimationKey)
    }

    func playDockPeekAnimation(edge: FloatingCharacterDockEdge, emphasized: Bool) {
        layer?.removeAnimation(forKey: Self.dockPeekAnimationKey)
        let outward: CGFloat = edge == .left ? -1 : 1
        let distance: CGFloat = emphasized ? 18 : 12
        let peek = CAKeyframeAnimation(keyPath: "transform.translation.x")
        peek.values = [
            outward * distance,
            -outward * distance * 0.45,
            outward * distance * 0.18,
            0,
        ]
        peek.keyTimes = [0, 0.48, 0.76, 1]
        peek.duration = FloatingCharacterDragPhysics.landingDuration
        peek.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(peek, forKey: Self.dockPeekAnimationKey)
    }

    func startAmbientAnimation() {
        guard layer?.animation(forKey: Self.ambientScaleAnimationKey) == nil else { return }

        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [
            1,
            FloatingCharacterAmbientMotion.scaleFrom,
            FloatingCharacterAmbientMotion.scaleTo,
            1,
        ]
        scale.keyTimes = [0, 0.25, 0.70, 1]
        scale.duration = FloatingCharacterAmbientMotion.scaleCycleDuration
        scale.repeatCount = .infinity
        scale.timingFunctions = Self.easeInOutTimingFunctions(count: 3)

        let float = CAKeyframeAnimation(keyPath: "transform.translation.y")
        float.values = [
            0,
            FloatingCharacterAmbientMotion.floatFrom,
            FloatingCharacterAmbientMotion.floatTo,
            0,
        ]
        float.keyTimes = [0, 0.25, 0.70, 1]
        float.duration = FloatingCharacterAmbientMotion.floatCycleDuration
        float.repeatCount = .infinity
        float.timingFunctions = Self.easeInOutTimingFunctions(count: 3)

        let sway = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        sway.values = [
            0,
            -FloatingCharacterAmbientMotion.swayAngle,
            0,
            FloatingCharacterAmbientMotion.swayAngle,
            0,
        ]
        sway.keyTimes = [0, 0.2, 0.5, 0.8, 1]
        sway.duration = FloatingCharacterAmbientMotion.swayCycleDuration
        sway.repeatCount = .infinity
        sway.timingFunctions = Self.easeInOutTimingFunctions(count: 4)

        layer?.add(scale, forKey: Self.ambientScaleAnimationKey)
        layer?.add(float, forKey: Self.ambientFloatAnimationKey)
        layer?.add(sway, forKey: Self.ambientSwayAnimationKey)
    }

    func stopAllAnimations() {
        layer?.removeAllAnimations()
        layer?.transform = CATransform3DIdentity
    }

    private func stopMotionAnimations() {
        layer?.removeAnimation(forKey: Self.ambientScaleAnimationKey)
        layer?.removeAnimation(forKey: Self.ambientFloatAnimationKey)
        layer?.removeAnimation(forKey: Self.ambientSwayAnimationKey)
        layer?.removeAnimation(forKey: Self.clickActionAnimationKey)
        layer?.removeAnimation(forKey: Self.dragLandingAnimationKey)
        layer?.removeAnimation(forKey: Self.dockPeekAnimationKey)
        layer?.transform = CATransform3DIdentity
    }

    private static func easeInOutTimingFunctions(count: Int) -> [CAMediaTimingFunction] {
        (0..<count).map { _ in CAMediaTimingFunction(name: .easeInEaseOut) }
    }

    private func drawPrice() {
        let normalizedSignRect: NSRect
        switch presentationMode {
        case .full:
            normalizedSignRect = pose.normalizedSignRect
        case .docked(.right):
            normalizedSignRect = Self.dockedRightSignRect
        case .docked(.left):
            normalizedSignRect = NSRect(
                x: 1 - Self.dockedRightSignRect.maxX,
                y: Self.dockedRightSignRect.minY,
                width: Self.dockedRightSignRect.width,
                height: Self.dockedRightSignRect.height
            )
        }
        let signRect = Self.signRect(in: bounds, normalized: normalizedSignRect).insetBy(dx: 5, dy: 4)
        guard signRect.width > 0, signRect.height > 0 else { return }

        let fontSize = Self.fittedFontSize(for: price, in: signRect.size)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.white.withAlphaComponent(0.75)
        shadow.shadowBlurRadius = 1
        shadow.shadowOffset = NSSize(width: 0, height: -1)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: priceTrend.color,
            .shadow: shadow,
        ]
        let attributed = NSAttributedString(string: price, attributes: attributes)
        let measured = attributed.size()
        let drawRect = NSRect(
            x: signRect.midX - measured.width / 2,
            y: signRect.midY - measured.height / 2,
            width: measured.width,
            height: measured.height
        )

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: signRect).addClip()
        attributed.draw(in: drawRect)
        NSGraphicsContext.restoreGraphicsState()
    }

    static func signRect(in bounds: NSRect, normalized: NSRect) -> NSRect {
        NSRect(
            x: bounds.minX + normalized.minX * bounds.width,
            y: bounds.minY + (1 - normalized.maxY) * bounds.height,
            width: normalized.width * bounds.width,
            height: normalized.height * bounds.height
        )
    }

    static func fittedFontSize(for text: String, in availableSize: NSSize) -> CGFloat {
        guard !text.isEmpty, availableSize.width > 0, availableSize.height > 0 else { return 1 }

        var lower: CGFloat = 1
        var upper: CGFloat = 48
        for _ in 0..<12 {
            let candidate = (lower + upper) / 2
            let font = NSFont.monospacedDigitSystemFont(ofSize: candidate, weight: .bold)
            let measured = (text as NSString).size(withAttributes: [.font: font])
            if measured.width <= availableSize.width, measured.height <= availableSize.height {
                lower = candidate
            } else {
                upper = candidate
            }
        }
        return max(1, floor(lower * 10) / 10)
    }

    static func loadImage(named name: String) -> NSImage? {
        FloatingCharacterImageStore.shared.image(named: name)
    }

    static let dockedRightSignRect = NSRect(x: 0.32, y: 0.54, width: 0.53, height: 0.34)

    private func updateRenderedImage(animated: Bool) {
        guard isRenderingEnabled else {
            needsDisplay = true
            return
        }
        if animated {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = FloatingCharacterActionTiming.transitionDuration
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(transition, forKey: "characterPoseTransition")
        }
        let resourceName: String
        switch presentationMode {
        case .full:
            resourceName = pose.resourceName
        case .docked:
            resourceName = isDockedBlinking
                ? "character-docked-sneak-blink"
                : "character-docked-sneak-open"
        }
        image = FloatingCharacterImageStore.shared.image(named: resourceName)
        needsDisplay = true
    }
}
