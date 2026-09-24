import AppKit
import XCTest
@testable import MarketBar

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
        XCTAssertEqual(FloatingCharacterSizeOption.allCases.count, 5)
        XCTAssertEqual(FloatingCharacterSizeOption.mini.size, NSSize(width: 160, height: 160))
        XCTAssertEqual(FloatingCharacterSizeOption.small.size, NSSize(width: 200, height: 200))
        XCTAssertEqual(FloatingCharacterSizeOption.standard.size, NSSize(width: 240, height: 240))
        XCTAssertEqual(FloatingCharacterSizeOption.large.size, NSSize(width: 280, height: 280))
        XCTAssertEqual(FloatingCharacterSizeOption.huge.size, NSSize(width: 320, height: 320))
        XCTAssertEqual(FloatingCharacterSizeOption.defaultOption, .standard)

        // 贴边尺寸按固定比例缩放，保证各档位观感一致
        for option in FloatingCharacterSizeOption.allCases {
            XCTAssertEqual(option.dockedSize.width, (option.rawValue * 0.75).rounded())
            XCTAssertEqual(option.dockedSize.height, (option.rawValue * 0.4667).rounded())
            XCTAssertLessThan(option.dockedSize.width, option.size.width)
        }
    }

    /// 老版本存过 220 / 260 这类已下架的档位，不能悄悄回到默认，要还原成最接近的
    func testPersistedLegacySizeFallsBackToNearestOption() {
        XCTAssertEqual(FloatingCharacterSizeOption.option(forPersistedValue: 220), .small)
        XCTAssertEqual(FloatingCharacterSizeOption.option(forPersistedValue: 260), .standard)
        XCTAssertEqual(FloatingCharacterSizeOption.option(forPersistedValue: 240), .standard)
        XCTAssertEqual(FloatingCharacterSizeOption.option(forPersistedValue: 999), .huge)
        XCTAssertEqual(FloatingCharacterSizeOption.option(forPersistedValue: 1), .mini)
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
                ).insetBy(dx: FloatingCharacterView.signTextInset.width, dy: FloatingCharacterView.signTextInset.height).size
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
                ).insetBy(dx: FloatingCharacterView.signTextInset.width, dy: FloatingCharacterView.signTextInset.height).size
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

    // MARK: - 举牌两行排版（金价 + 组合当日盈亏）

    /// 所有姿态 × 尺寸下，两行可用区都要在牌子内、都是正的、且上下不重叠
    @MainActor
    func testTwoLineLayoutStaysInsideEverySignRect() {
        for option in FloatingCharacterSizeOption.allCases {
            let bounds = NSRect(origin: .zero, size: option.size)
            for pose in FloatingCharacterPose.allCases {
                assertTwoLineLayout(
                    signRect: FloatingCharacterView.signRect(in: bounds, normalized: pose.normalizedSignRect)
                        .insetBy(dx: FloatingCharacterView.signTextInset.width, dy: FloatingCharacterView.signTextInset.height)
                )
            }
        }

        let right = FloatingCharacterView.dockedRightSignRect
        for option in FloatingCharacterSizeOption.allCases {
            let bounds = NSRect(origin: .zero, size: option.dockedSize)
            for normalizedRect in [
                right,
                NSRect(x: 1 - right.maxX, y: right.minY, width: right.width, height: right.height),
            ] {
                assertTwoLineLayout(
                    signRect: FloatingCharacterView.signRect(in: bounds, normalized: normalizedRect)
                        .insetBy(dx: FloatingCharacterView.signTextInset.width, dy: FloatingCharacterView.signTextInset.height)
                )
            }
        }
    }

    private func assertTwoLineLayout(signRect: NSRect, file: StaticString = #filePath, line: UInt = #line) {
        let available = FloatingCharacterSignLayout.availableSizes(in: signRect, hasProfit: true)
        guard let profit = available.profit else {
            return XCTFail("有第二行时必须给出盈亏可用区", file: file, line: line)
        }

        XCTAssertGreaterThan(available.price.width, 0, file: file, line: line)
        XCTAssertGreaterThan(available.price.height, 0, file: file, line: line)
        XCTAssertGreaterThan(profit.height, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(available.price.height + profit.height, signRect.height, file: file, line: line)

        // 两行各自适配出来的实际绘制区不能互相压到
        let origins = FloatingCharacterSignLayout.drawOrigins(
            priceSize: available.price,
            profitSize: profit,
            in: signRect
        )
        guard let profitOrigin = origins.profit else {
            return XCTFail("有第二行时必须给出绘制原点", file: file, line: line)
        }
        // y 轴向上：金价那行的下沿要在盈亏那行的上沿之上（中间正好隔一个 gap）
        XCTAssertGreaterThanOrEqual(
            origins.price.y,
            profitOrigin.y + profit.height - 0.001,
            "盈亏那行不能压到金价那行",
            file: file, line: line
        )
        XCTAssertGreaterThanOrEqual(origins.price.y, signRect.minY - 0.001, file: file, line: line)
        XCTAssertLessThanOrEqual(profitOrigin.y, signRect.maxY + 0.001, file: file, line: line)
    }

    /// 两行的字号都要放得进各自那一半，且**盈亏必须比金价大**
    @MainActor
    func testTwoLineFontsFitTheirHalvesAndProfitDominates() {
        let bounds = NSRect(origin: .zero, size: FloatingCharacterSizeOption.standard.size)
        for pose in FloatingCharacterPose.allCases {
            let signRect = FloatingCharacterView.signRect(in: bounds, normalized: pose.normalizedSignRect)
                .insetBy(dx: FloatingCharacterView.signTextInset.width, dy: FloatingCharacterView.signTextInset.height)
            let available = FloatingCharacterSignLayout.availableSizes(in: signRect, hasProfit: true)
            let profitAvailable = available.profit!

            for price in ["0.00", "1049.59", "99999999.99"] {
                for profit in ["-8,055", "+1,100", "-1,234,567"] {
                    let profitSize = FloatingCharacterView.fittedFontSize(for: profit, in: profitAvailable)
                    let priceSize = min(
                        FloatingCharacterView.fittedFontSize(for: price, in: available.price),
                        profitSize * FloatingCharacterSignLayout.priceFontScale
                    )

                    for (text, size, box) in [(price, priceSize, available.price), (profit, profitSize, profitAvailable)] {
                        let measured = (text as NSString).size(
                            withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)]
                        )
                        XCTAssertLessThanOrEqual(measured.width, box.width + 1, text)
                        XCTAssertLessThanOrEqual(measured.height, box.height + 1, text)
                    }
                    XCTAssertGreaterThanOrEqual(priceSize, 1)
                    XCTAssertGreaterThan(
                        profitSize,
                        priceSize,
                        "盈亏那行必须比金价大（\(profit) vs \(price)）"
                    )
                }
            }
        }
    }

    /// 没有盈亏时必须是改动前的单行行为（同一个可用区、同一个居中公式）
    func testSingleLineLayoutIsTheOldCentering() {
        let signRect = NSRect(x: 20, y: 30, width: 90, height: 28)

        let available = FloatingCharacterSignLayout.availableSizes(in: signRect, hasProfit: false)
        XCTAssertEqual(available.price, signRect.size)
        XCTAssertNil(available.profit)

        let textSize = NSSize(width: 40, height: 14)
        let origins = FloatingCharacterSignLayout.drawOrigins(priceSize: textSize, profitSize: nil, in: signRect)
        XCTAssertNil(origins.profit)
        XCTAssertEqual(origins.price.x, signRect.midX - textSize.width / 2)
        XCTAssertEqual(origins.price.y, signRect.midY - textSize.height / 2)
    }

    /// 盈亏那行分到的高度要更多（它是主角），两行加间隙正好填满牌子
    func testProfitLineGetsMoreHeightThanThePriceLine() {
        let signRect = NSRect(x: 0, y: 0, width: 84.8, height: 26.8)   // 标准尺寸下最紧的姿态之一
        let available = FloatingCharacterSignLayout.availableSizes(in: signRect, hasProfit: true)

        XCTAssertGreaterThan(available.profit!.height, available.price.height)
        XCTAssertEqual(
            available.price.height + available.profit!.height + FloatingCharacterSignLayout.gap(in: signRect),
            signRect.height,
            accuracy: 0.001
        )
    }

    func testSignLayoutTreatsEmptyProfitTextAsNoSecondLine() {
        XCTAssertNil(FloatingCharacterSignLayout.normalizedProfitText(nil))
        XCTAssertNil(FloatingCharacterSignLayout.normalizedProfitText(""))
        XCTAssertEqual(FloatingCharacterSignLayout.normalizedProfitText("-8,055"), "-8,055")
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
