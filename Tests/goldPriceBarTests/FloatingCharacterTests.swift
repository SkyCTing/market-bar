import AppKit
import XCTest
@testable import goldPriceBar

final class FloatingCharacterTests: XCTestCase {
    func testEmotionUsesSadOnlyForNegativePrices() {
        XCTAssertEqual(FloatingCharacterEmotion(isNegative: true), .sad)
        XCTAssertEqual(FloatingCharacterEmotion(isNegative: false), .happy)
        XCTAssertEqual(FloatingCharacterEmotion(isNegative: nil), .happy)
    }

    func testEachEmotionHasMatchingBaseAndActionPoses() {
        XCTAssertEqual(FloatingCharacterPose.basePose(for: .happy), .happy)
        XCTAssertEqual(FloatingCharacterPose.basePose(for: .sad), .sad)
        XCTAssertEqual(FloatingCharacterPose.actions(for: .happy).count, 8)
        XCTAssertEqual(FloatingCharacterPose.actions(for: .sad).count, 8)
        XCTAssertTrue(FloatingCharacterPose.actions(for: .happy).allSatisfy { $0.emotion == .happy })
        XCTAssertTrue(FloatingCharacterPose.actions(for: .sad).allSatisfy { $0.emotion == .sad })
        XCTAssertTrue(FloatingCharacterPose.actions(for: .happy).contains(.happyClap))
        XCTAssertTrue(FloatingCharacterPose.actions(for: .happy).contains(.happyDance))
        XCTAssertTrue(FloatingCharacterPose.actions(for: .happy).contains(.happyThumbsUp))
        XCTAssertTrue(FloatingCharacterPose.actions(for: .sad).contains(.sadSigh))
        XCTAssertTrue(FloatingCharacterPose.actions(for: .sad).contains(.sadFacepalm))
        XCTAssertTrue(FloatingCharacterPose.actions(for: .sad).contains(.sadShiver))
    }

    @MainActor
    func testFloatingCharacterSizeOptionsUseRequestedDefaults() {
        let size = FloatingCharacterController.defaultSize
        XCTAssertEqual(size, NSSize(width: 240, height: 240))
        XCTAssertEqual(FloatingCharacterSizeOption.small.size, NSSize(width: 220, height: 220))
        XCTAssertEqual(FloatingCharacterSizeOption.standard.size, NSSize(width: 240, height: 240))
        XCTAssertEqual(FloatingCharacterSizeOption.large.size, NSSize(width: 260, height: 260))
        XCTAssertEqual(FloatingCharacterSizeOption.defaultOption, .standard)
        XCTAssertEqual(FloatingCharacterSizeOption.small.dockedSize, NSSize(width: 165, height: 103))
        XCTAssertEqual(FloatingCharacterSizeOption.standard.dockedSize, NSSize(width: 180, height: 112))
        XCTAssertEqual(FloatingCharacterSizeOption.large.dockedSize, NSSize(width: 195, height: 122))
    }

    @MainActor
    func testControllerAppliesEveryWindowSize() {
        let controller = FloatingCharacterController(idleTimeProvider: { 0 })
        for option in FloatingCharacterSizeOption.allCases {
            controller.setSize(option)
            XCTAssertEqual(controller.sizeOption, option)
            XCTAssertEqual(controller.panelSize, option.size)
        }
    }

    @MainActor
    func testCompletedActionRestartsAmbientMotion() throws {
        let suiteName = "FloatingCharacterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = FloatingCharacterController(defaults: defaults, idleTimeProvider: { 0 })
        defer { controller.setVisible(false) }

        controller.setVisible(true)
        XCTAssertEqual(controller.motionState, .ambient)
        controller.triggerActionForTesting()
        XCTAssertEqual(controller.motionState, .action)
        controller.finishActionForTesting()
        XCTAssertEqual(controller.motionState, .ambient)
    }

    @MainActor
    func testCompletedActionEntersSleepWhenUserIsIdle() throws {
        let suiteName = "FloatingCharacterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var idleDuration: TimeInterval = 0
        let controller = FloatingCharacterController(
            defaults: defaults,
            idleTimeProvider: { idleDuration }
        )
        defer { controller.setVisible(false) }

        controller.setVisible(true)
        controller.triggerActionForTesting()
        XCTAssertEqual(controller.motionState, .action)
        idleDuration = FloatingCharacterMotionPolicy.idleThreshold
        controller.finishActionForTesting()
        XCTAssertEqual(controller.motionState, .sleeping)
    }

    @MainActor
    func testSleepingCharacterWakesWhenActivityReturns() throws {
        let suiteName = "FloatingCharacterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var idleDuration = FloatingCharacterMotionPolicy.idleThreshold
        let controller = FloatingCharacterController(
            defaults: defaults,
            idleTimeProvider: { idleDuration }
        )
        defer { controller.setVisible(false) }

        controller.setVisible(true)
        XCTAssertEqual(controller.motionState, .sleeping)
        idleDuration = 0
        controller.evaluateMotionPolicyForTesting()
        XCTAssertEqual(controller.motionState, .ambient)
    }

    func testMarketReactionDetectorUsesOneYuanThresholdAndCooldown() {
        var detector = FloatingCharacterMarketReactionDetector()
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertNil(detector.process(price: 1_000, at: start))
        XCTAssertNil(detector.process(price: 1_000.5, at: start.addingTimeInterval(1)))
        XCTAssertEqual(
            detector.process(price: 1_001.5, at: start.addingTimeInterval(2)),
            .rapidRise(delta: 1)
        )
        XCTAssertNil(detector.process(price: 1_003, at: start.addingTimeInterval(20)))
        XCTAssertEqual(
            detector.process(price: 1_004, at: start.addingTimeInterval(48)),
            .rapidRise(delta: 1)
        )
    }

    func testMarketReactionDetectorIgnoresInvalidPricesAndCanReset() {
        var detector = FloatingCharacterMarketReactionDetector()
        let start = Date(timeIntervalSince1970: 2_000)

        XCTAssertNil(detector.process(price: 1_000, at: start))
        XCTAssertNil(detector.process(price: 0, at: start.addingTimeInterval(1)))
        XCTAssertEqual(
            detector.process(price: 997, at: start.addingTimeInterval(2)),
            .rapidFall(delta: -3)
        )
        detector.reset()
        XCTAssertNil(detector.process(price: 900, at: start.addingTimeInterval(100)))
    }

    @MainActor
    func testControllerReactsToRapidPriceChangeAndResetsHistory() throws {
        let suiteName = "FloatingCharacterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var now = Date(timeIntervalSince1970: 3_000)
        let controller = FloatingCharacterController(
            defaults: defaults,
            idleTimeProvider: { 0 },
            nowProvider: { now }
        )
        defer { controller.setVisible(false) }

        controller.setVisible(true)
        controller.update(price: "1000.00", numericPrice: 1_000, isNegative: false)
        XCTAssertEqual(controller.motionState, .ambient)

        now = now.addingTimeInterval(1)
        controller.update(price: "1001.00", numericPrice: 1_001, isNegative: false)
        XCTAssertEqual(controller.motionState, .action)

        controller.finishActionForTesting()
        controller.resetQuoteHistory()
        now = now.addingTimeInterval(60)
        controller.update(price: "900.00", numericPrice: 900, isNegative: true)
        XCTAssertEqual(controller.motionState, .ambient)
    }

    func testSpeechBubbleLayoutStaysInsideVisibleScreen() {
        let visibleFrame = NSRect(x: 100, y: 50, width: 900, height: 650)
        let topRightAnchor = NSRect(x: 920, y: 620, width: 80, height: 80)
        let topLayout = FloatingCharacterSpeechBubbleLayout.frame(
            anchor: topRightAnchor,
            visibleFrame: visibleFrame
        )
        XCTAssertFalse(topLayout.pointsDown)
        XCTAssertTrue(visibleFrame.contains(topLayout.frame))

        let lowerAnchor = NSRect(x: 120, y: 80, width: 180, height: 112)
        let lowerLayout = FloatingCharacterSpeechBubbleLayout.frame(
            anchor: lowerAnchor,
            visibleFrame: visibleFrame
        )
        XCTAssertTrue(lowerLayout.pointsDown)
        XCTAssertTrue(visibleFrame.contains(lowerLayout.frame))
    }

    func testSpeechCatalogProvidesAllInteractionMessages() {
        XCTAssertEqual(FloatingCharacterSpeechCatalog.ambientDelayRange, 45...90)
        XCTAssertEqual(FloatingCharacterSpeechCatalog.displayDuration, 3.5)
        let triggers: [FloatingCharacterSpeechTrigger] = [
            .ambient, .click, .doubleClick, .impatient, .hide,
            .rapidRise(delta: 3), .rapidFall(delta: -3), .sleeping, .wake,
        ]
        for trigger in triggers {
            XCTAssertFalse(
                FloatingCharacterSpeechCatalog.text(for: trigger, emotion: .happy).isEmpty
            )
            XCTAssertFalse(
                FloatingCharacterSpeechCatalog.text(for: trigger, emotion: .sad).isEmpty
            )
        }
    }

    func testRapidClickSequenceEscalatesAndEnforcesCooldown() {
        var sequence = FloatingCharacterClickSequence()
        let start = Date(timeIntervalSince1970: 4_000)

        XCTAssertEqual(
            sequence.register(at: start, doubleClickInterval: 0.5),
            .pendingSingle
        )
        XCTAssertEqual(
            sequence.register(at: start.addingTimeInterval(0.2), doubleClickInterval: 0.5),
            .doubleClick
        )
        XCTAssertEqual(
            sequence.register(at: start.addingTimeInterval(0.4), doubleClickInterval: 0.5),
            .impatient
        )
        XCTAssertEqual(
            sequence.register(at: start.addingTimeInterval(0.6), doubleClickInterval: 0.5),
            .hide
        )
        XCTAssertEqual(
            sequence.register(at: start.addingTimeInterval(2), doubleClickInterval: 0.5),
            .ignoredDuringCooldown
        )
        XCTAssertEqual(
            sequence.register(at: start.addingTimeInterval(8.7), doubleClickInterval: 0.5),
            .pendingSingle
        )
        XCTAssertEqual(FloatingCharacterClickSequence.burstInterval, 3)
        XCTAssertEqual(FloatingCharacterClickSequence.terminalCooldown, 8)
        XCTAssertEqual(FloatingCharacterClickSequence.hideDuration, 4)
    }

    func testClickSequenceResetsAfterBurstInterval() {
        var sequence = FloatingCharacterClickSequence()
        let start = Date(timeIntervalSince1970: 5_000)

        XCTAssertEqual(sequence.register(at: start, doubleClickInterval: 0.5), .pendingSingle)
        XCTAssertEqual(
            sequence.register(at: start.addingTimeInterval(3.1), doubleClickInterval: 0.5),
            .pendingSingle
        )
        XCTAssertEqual(sequence.clickCount, 1)

        var slidingSequence = FloatingCharacterClickSequence()
        XCTAssertEqual(
            slidingSequence.register(at: start, doubleClickInterval: 0.5),
            .pendingSingle
        )
        XCTAssertEqual(
            slidingSequence.register(
                at: start.addingTimeInterval(2.9),
                doubleClickInterval: 0.5
            ),
            .pendingSingle
        )
        XCTAssertEqual(
            slidingSequence.register(
                at: start.addingTimeInterval(5.8),
                doubleClickInterval: 0.5
            ),
            .pendingSingle
        )
        XCTAssertEqual(slidingSequence.clickCount, 1)
    }

    func testDragVelocityTrackerUsesRecentSamples() {
        var tracker = FloatingCharacterDragVelocityTracker()
        tracker.reset(point: .zero, timestamp: 10)
        tracker.record(point: NSPoint(x: 20, y: 0), timestamp: 10.04)
        tracker.record(point: NSPoint(x: 80, y: 40), timestamp: 10.08)
        let velocity = tracker.velocity()
        XCTAssertEqual(velocity.x, 1_000, accuracy: 0.001)
        XCTAssertEqual(velocity.y, 500, accuracy: 0.001)

        tracker.record(point: NSPoint(x: 90, y: 50), timestamp: 10.25)
        XCTAssertEqual(tracker.velocity(), .zero)
    }

    func testDragPhysicsThresholdAndDisplacementCap() {
        XCTAssertEqual(
            FloatingCharacterDragPhysics.projectedDisplacement(
                for: NSPoint(x: FloatingCharacterDragPhysics.speedThreshold - 1, y: 0)
            ),
            .zero
        )
        let displacement = FloatingCharacterDragPhysics.projectedDisplacement(
            for: NSPoint(x: 2_000, y: 2_000)
        )
        XCTAssertEqual(
            FloatingCharacterDragPhysics.speed(of: displacement),
            FloatingCharacterDragPhysics.maximumDisplacement,
            accuracy: 0.001
        )
        XCTAssertEqual(FloatingCharacterDragPhysics.inertiaDuration, 0.45)
        XCTAssertEqual(FloatingCharacterDragPhysics.dockingDuration, 0.25)
    }

    func testAutomaticActionsAreVisibleLongEnough() {
        XCTAssertEqual(FloatingCharacterActionTiming.ambientDelayRange, 10...15)
        XCTAssertEqual(FloatingCharacterActionTiming.actionDuration, 3)
        XCTAssertEqual(FloatingCharacterActionTiming.transitionDuration, 0.2)
        XCTAssertEqual(FloatingCharacterDockedTiming.ambientBlinkDelayRange, 4.5...5.5)
        XCTAssertEqual(FloatingCharacterDockedTiming.closedFrameDuration, 0.12)
        XCTAssertEqual(FloatingCharacterDockedTiming.betweenBlinksDuration, 0.14)
    }

    func testAmbientMotionUsesVisibleButGentleParameters() {
        XCTAssertEqual(FloatingCharacterAmbientMotion.scaleFrom, 0.985, accuracy: 0.0001)
        XCTAssertEqual(FloatingCharacterAmbientMotion.scaleTo, 1.020, accuracy: 0.0001)
        XCTAssertEqual(FloatingCharacterAmbientMotion.scaleCycleDuration, 2.6)
        XCTAssertEqual(FloatingCharacterAmbientMotion.floatFrom, -3, accuracy: 0.001)
        XCTAssertEqual(FloatingCharacterAmbientMotion.floatTo, 5, accuracy: 0.001)
        XCTAssertEqual(FloatingCharacterAmbientMotion.floatCycleDuration, 3.2)
        XCTAssertEqual(
            FloatingCharacterAmbientMotion.swayAngle,
            0.8 * .pi / 180,
            accuracy: 0.0001
        )
        XCTAssertEqual(FloatingCharacterAmbientMotion.swayCycleDuration, 4.4)
    }

    @MainActor
    func testAmbientMotionInstallsAndRemovesAllThreeAnimations() throws {
        let view = FloatingCharacterView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
        view.startAmbientAnimation()

        let scale = try XCTUnwrap(
            view.layer?.animation(forKey: FloatingCharacterView.ambientScaleAnimationKey)
                as? CAKeyframeAnimation
        )
        let float = try XCTUnwrap(
            view.layer?.animation(forKey: FloatingCharacterView.ambientFloatAnimationKey)
                as? CAKeyframeAnimation
        )
        let sway = try XCTUnwrap(
            view.layer?.animation(forKey: FloatingCharacterView.ambientSwayAnimationKey)
                as? CAKeyframeAnimation
        )
        XCTAssertEqual(scale.keyPath, "transform.scale")
        XCTAssertEqual(scale.duration, FloatingCharacterAmbientMotion.scaleCycleDuration)
        XCTAssertEqual(float.keyPath, "transform.translation.y")
        XCTAssertEqual(float.duration, FloatingCharacterAmbientMotion.floatCycleDuration)
        XCTAssertEqual(sway.keyPath, "transform.rotation.z")
        XCTAssertEqual(sway.duration, FloatingCharacterAmbientMotion.swayCycleDuration)
        XCTAssertEqual(scale.repeatCount, .infinity)
        XCTAssertEqual(float.repeatCount, .infinity)
        XCTAssertEqual(sway.repeatCount, .infinity)

        view.stopAllAnimations()
        XCTAssertNil(view.layer?.animation(forKey: FloatingCharacterView.ambientScaleAnimationKey))
        XCTAssertNil(view.layer?.animation(forKey: FloatingCharacterView.ambientFloatAnimationKey))
        XCTAssertNil(view.layer?.animation(forKey: FloatingCharacterView.ambientSwayAnimationKey))
    }

    @MainActor
    func testNewPoseAnimationsRepeatWithoutExceedingActionDuration() throws {
        let view = FloatingCharacterView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
        let expectations: [(FloatingCharacterAnimation, String)] = [
            (.clap, "transform.scale"),
            (.dance, "transform.rotation.z"),
            (.pop, "transform.scale"),
            (.sigh, "transform.translation.y"),
            (.tremble, "transform.rotation.z"),
            (.shiver, "transform.translation.x"),
        ]

        for (profile, expectedKeyPath) in expectations {
            view.play(animation: profile)
            let animation = try XCTUnwrap(
                view.layer?.animation(forKey: FloatingCharacterView.clickActionAnimationKey)
                    as? CAKeyframeAnimation
            )
            XCTAssertEqual(animation.keyPath, expectedKeyPath)
            XCTAssertGreaterThanOrEqual(animation.repeatCount, 2)
            XCTAssertLessThanOrEqual(
                animation.duration * Double(animation.repeatCount),
                FloatingCharacterActionTiming.actionDuration
            )
        }
    }

    @MainActor
    func testDragLandingAndDockPeekUseReplaceableCoreAnimations() throws {
        let view = FloatingCharacterView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
        view.playDragLandingAnimation(horizontalVelocity: 1_000)
        let landing = try XCTUnwrap(
            view.layer?.animation(forKey: FloatingCharacterView.dragLandingAnimationKey)
                as? CAAnimationGroup
        )
        XCTAssertEqual(landing.duration, FloatingCharacterDragPhysics.landingDuration)
        XCTAssertEqual(landing.animations?.count, 3)

        view.playDockPeekAnimation(edge: .right, emphasized: true)
        let peek = try XCTUnwrap(
            view.layer?.animation(forKey: FloatingCharacterView.dockPeekAnimationKey)
                as? CAKeyframeAnimation
        )
        XCTAssertEqual(peek.duration, FloatingCharacterDragPhysics.landingDuration)

        view.stopAllAnimations()
        XCTAssertNil(view.layer?.animation(forKey: FloatingCharacterView.dragLandingAnimationKey))
        XCTAssertNil(view.layer?.animation(forKey: FloatingCharacterView.dockPeekAnimationKey))
    }

    func testDockingDetectsOnlyLeftAndRightEdgeThresholds() {
        let visibleFrame = NSRect(x: 100, y: 50, width: 1_000, height: 700)
        XCTAssertEqual(
            FloatingCharacterDockLayout.edge(for: NSPoint(x: 136, y: 300), in: visibleFrame),
            .left
        )
        XCTAssertEqual(
            FloatingCharacterDockLayout.edge(for: NSPoint(x: 1_064, y: 300), in: visibleFrame),
            .right
        )
        XCTAssertNil(FloatingCharacterDockLayout.edge(
            for: NSPoint(x: 137, y: 300),
            in: visibleFrame
        ))
        XCTAssertNil(FloatingCharacterDockLayout.edge(
            for: NSPoint(x: 500, y: visibleFrame.maxY + 1),
            in: visibleFrame
        ))
    }

    func testDockedCharacterRestoresOnlyAfterInwardDrag() {
        XCTAssertTrue(FloatingCharacterDockLayout.shouldRestore(horizontalDrag: 48, from: .left))
        XCTAssertFalse(FloatingCharacterDockLayout.shouldRestore(horizontalDrag: 47.9, from: .left))
        XCTAssertFalse(FloatingCharacterDockLayout.shouldRestore(horizontalDrag: -100, from: .left))
        XCTAssertTrue(FloatingCharacterDockLayout.shouldRestore(horizontalDrag: -48, from: .right))
        XCTAssertFalse(FloatingCharacterDockLayout.shouldRestore(horizontalDrag: -47.9, from: .right))
        XCTAssertFalse(FloatingCharacterDockLayout.shouldRestore(horizontalDrag: 100, from: .right))
    }

    func testDockedOriginSnapsHorizontallyAndClampsVertically() {
        let visibleFrame = NSRect(x: 100, y: 50, width: 1_000, height: 700)
        let size = NSSize(width: 180, height: 112)
        XCTAssertEqual(
            FloatingCharacterDockLayout.dockedOrigin(
                edge: .left,
                proposedY: -200,
                size: size,
                visibleFrame: visibleFrame
            ),
            NSPoint(x: 100, y: 50)
        )
        XCTAssertEqual(
            FloatingCharacterDockLayout.dockedOrigin(
                edge: .right,
                proposedY: 900,
                size: size,
                visibleFrame: visibleFrame
            ),
            NSPoint(x: 920, y: 638)
        )
    }

    func testPriceTrendMatchesStatusBarSemantics() {
        XCTAssertEqual(FloatingCharacterPriceTrend(isNegative: false), .up)
        XCTAssertEqual(FloatingCharacterPriceTrend(isNegative: true), .down)
        XCTAssertEqual(FloatingCharacterPriceTrend(isNegative: nil), .flat)
    }

    func testMotionPolicyPausesForIdleLowPowerAndInactiveSessions() {
        XCTAssertTrue(FloatingCharacterMotionPolicy.allowsAmbientMotion(
            isVisible: true,
            isScreenAwake: true,
            isSessionActive: true,
            isLowPowerModeEnabled: false,
            idleDuration: FloatingCharacterMotionPolicy.idleThreshold - 1
        ))
        XCTAssertFalse(FloatingCharacterMotionPolicy.allowsAmbientMotion(
            isVisible: true,
            isScreenAwake: true,
            isSessionActive: true,
            isLowPowerModeEnabled: false,
            idleDuration: FloatingCharacterMotionPolicy.idleThreshold
        ))
        XCTAssertFalse(FloatingCharacterMotionPolicy.allowsAmbientMotion(
            isVisible: true,
            isScreenAwake: true,
            isSessionActive: true,
            isLowPowerModeEnabled: true,
            idleDuration: 0
        ))
        XCTAssertFalse(FloatingCharacterMotionPolicy.allowsAmbientMotion(
            isVisible: true,
            isScreenAwake: false,
            isSessionActive: true,
            isLowPowerModeEnabled: false,
            idleDuration: 0
        ))
        XCTAssertFalse(FloatingCharacterMotionPolicy.allowsAmbientMotion(
            isVisible: true,
            isScreenAwake: true,
            isSessionActive: false,
            isLowPowerModeEnabled: false,
            idleDuration: 0
        ))
    }

    @MainActor
    func testAllSignRectsStayInsideImageBounds() {
        for pose in FloatingCharacterPose.allCases {
            let rect = pose.normalizedSignRect
            XCTAssertGreaterThan(rect.width, 0)
            XCTAssertGreaterThan(rect.height, 0)
            XCTAssertGreaterThanOrEqual(rect.minX, 0)
            XCTAssertGreaterThanOrEqual(rect.minY, 0)
            XCTAssertLessThanOrEqual(rect.maxX, 1)
            XCTAssertLessThanOrEqual(rect.maxY, 1)
        }
        let right = FloatingCharacterView.dockedRightSignRect
        let left = NSRect(x: 1 - right.maxX, y: right.minY, width: right.width, height: right.height)
        for rect in [left, right] {
            XCTAssertGreaterThan(rect.width, 0)
            XCTAssertGreaterThan(rect.height, 0)
            XCTAssertGreaterThanOrEqual(rect.minX, 0)
            XCTAssertGreaterThanOrEqual(rect.minY, 0)
            XCTAssertLessThanOrEqual(rect.maxX, 1)
            XCTAssertLessThanOrEqual(rect.maxY, 1)
        }
    }

    @MainActor
    func testPriceFontFitsRepresentativeAmounts() {
        for option in FloatingCharacterSizeOption.allCases {
            let bounds = NSRect(origin: .zero, size: option.size)
            for pose in FloatingCharacterPose.allCases {
                let availableSize = FloatingCharacterView.signRect(
                    in: bounds,
                    normalized: pose.normalizedSignRect
                ).insetBy(dx: 5, dy: 4).size
                for value in ["0.00", "999.99", "1049.59", "99999999.99"] {
                    let size = FloatingCharacterView.fittedFontSize(for: value, in: availableSize)
                    let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
                    let measured = (value as NSString).size(withAttributes: [.font: font])
                    XCTAssertLessThanOrEqual(measured.width, availableSize.width + 1)
                    XCTAssertLessThanOrEqual(measured.height, availableSize.height + 1)
                }
            }
        }
    }

    @MainActor
    func testDockedPriceFontFitsRepresentativeAmountsOnBothEdges() {
        let right = FloatingCharacterView.dockedRightSignRect
        let signRects = [
            right,
            NSRect(x: 1 - right.maxX, y: right.minY, width: right.width, height: right.height),
        ]
        for option in FloatingCharacterSizeOption.allCases {
            let bounds = NSRect(origin: .zero, size: option.dockedSize)
            for normalizedRect in signRects {
                let availableSize = FloatingCharacterView.signRect(
                    in: bounds,
                    normalized: normalizedRect
                ).insetBy(dx: 5, dy: 4).size
                for value in ["0.00", "1049.59", "99999999.99"] {
                    let size = FloatingCharacterView.fittedFontSize(for: value, in: availableSize)
                    let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
                    let measured = (value as NSString).size(withAttributes: [.font: font])
                    XCTAssertLessThanOrEqual(measured.width, availableSize.width + 1)
                    XCTAssertLessThanOrEqual(measured.height, availableSize.height + 1)
                }
            }
        }
    }

    @MainActor
    func testEveryPoseLoadsItsPackagedImage() {
        XCTAssertEqual(
            Set(FloatingCharacterPose.allCases.map(\.resourceName)).count,
            FloatingCharacterPose.allCases.count
        )
        for pose in FloatingCharacterPose.allCases {
            let image = FloatingCharacterView.loadImage(named: pose.resourceName)
            XCTAssertNotNil(image, "Missing image for \(pose.resourceName)")
            let representation = image?.representations.first
            XCTAssertEqual(representation?.pixelsWide, 512)
            XCTAssertEqual(representation?.pixelsHigh, 512)
            XCTAssertEqual((representation as? NSBitmapImageRep)?.hasAlpha, true)
        }
    }

    @MainActor
    func testDockedBlinkFramesLoadAtCompactRuntimeResolution() {
        for name in ["character-docked-sneak-open", "character-docked-sneak-blink"] {
            let image = FloatingCharacterView.loadImage(named: name)
            XCTAssertNotNil(image, "Missing image for \(name)")
            let representation = image?.representations.first
            XCTAssertEqual(representation?.pixelsWide, 512)
            XCTAssertEqual(representation?.pixelsHigh, 320)
        }
    }

    @MainActor
    func testControllerRestoresAndResizesPersistedDockedMode() throws {
        guard NSScreen.main != nil else {
            throw XCTSkip("No AppKit screen is available")
        }
        let suiteName = "FloatingCharacterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("docked", forKey: "floatingCharacterPresentationMode")
        defaults.set("right", forKey: "floatingCharacterDockEdge")
        defaults.set(120.0, forKey: "floatingCharacterOriginY")

        let controller = FloatingCharacterController(defaults: defaults, idleTimeProvider: { 0 })
        XCTAssertEqual(controller.presentationMode, .docked(.right))
        XCTAssertEqual(controller.panelSize, FloatingCharacterSizeOption.standard.dockedSize)
        controller.setSize(.large)
        XCTAssertEqual(controller.panelSize, FloatingCharacterSizeOption.large.dockedSize)
    }

    @MainActor
    func testImageCacheHasABoundedDecodedMemoryBudget() {
        let countLimit = FloatingCharacterImageStore.maximumCachedImageCount
        let costLimit = FloatingCharacterImageStore.maximumCacheCost
        let imageCost = FloatingCharacterImageStore.estimatedDecodedCost(width: 512, height: 512)
        let dockedImageCost = FloatingCharacterImageStore.estimatedDecodedCost(width: 512, height: 320)
        XCTAssertEqual(countLimit, 8)
        XCTAssertEqual(costLimit, 10 * 1024 * 1024)
        XCTAssertEqual(imageCost, 1024 * 1024)
        XCTAssertEqual(dockedImageCost, 640 * 1024)
    }

    @MainActor
    func testRepeatedPoseLoadingStaysStable() {
        let poses = FloatingCharacterPose.allCases
        for index in 0..<1_000 {
            XCTAssertNotNil(
                FloatingCharacterImageStore.shared.image(
                    named: poses[index % poses.count].resourceName
                )
            )
        }
        FloatingCharacterImageStore.shared.removeAll()
    }
}
