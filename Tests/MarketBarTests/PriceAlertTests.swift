import Foundation
import XCTest

@testable import MarketBar

/// 触发判定。纯函数，不需要 AppDelegate。
final class PriceAlertEvaluatorTests: XCTestCase {
    private func alert(
        _ direction: PriceAlert.Direction = .above,
        threshold: Double = 100,
        repeats: Bool = true,
        triggered: Bool = false
    ) -> PriceAlert {
        PriceAlert(
            target: .gold,
            direction: direction,
            threshold: threshold,
            repeats: repeats,
            isTriggered: triggered
        )
    }

    // MARK: 基本触发

    func testFiresWhenCrossingAbove() {
        let (fired, updated) = PriceAlertEvaluator.evaluate(alert(.above, threshold: 100), price: 120)

        XCTAssertTrue(fired)
        XCTAssertTrue(updated.isTriggered, "响过要闩上，否则每次刷新都会再响")
    }

    func testFiresWhenCrossingBelow() {
        let (fired, updated) = PriceAlertEvaluator.evaluate(alert(.below, threshold: 100), price: 80)

        XCTAssertTrue(fired)
        XCTAssertTrue(updated.isTriggered)
    }

    func testDoesNotFireBeforeReachingThreshold() {
        let (fired, updated) = PriceAlertEvaluator.evaluate(alert(.above, threshold: 100), price: 99.99)

        XCTAssertFalse(fired)
        XCTAssertFalse(updated.isTriggered)
    }

    /// 恰好等于阈值算「到了」（和原来金价提醒的 `>=` / `<=` 一致）
    func testExactlyAtThresholdFires() {
        XCTAssertTrue(PriceAlertEvaluator.evaluate(alert(.above, threshold: 100), price: 100).fired)
        XCTAssertTrue(PriceAlertEvaluator.evaluate(alert(.below, threshold: 100), price: 100).fired)
    }

    /// 已经闩上了就不再重复响，哪怕价格一直在阈值外面
    func testDoesNotRepeatWhileStillBeyond() {
        let (fired, _) = PriceAlertEvaluator.evaluate(alert(.above, threshold: 100, triggered: true), price: 150)

        XCTAssertFalse(fired)
    }

    // MARK: 重复提醒 vs 只响一次

    func testRepeatsRearmsAfterPriceFallsBack() {
        var current = alert(.above, threshold: 100)
        (_, current) = PriceAlertEvaluator.evaluate(current, price: 120)   // 第一次穿过
        XCTAssertTrue(current.isTriggered)

        (_, current) = PriceAlertEvaluator.evaluate(current, price: 90)    // 回落
        XCTAssertFalse(current.isTriggered, "勾了重复提醒，回落就该重新武装")

        let (fired, _) = PriceAlertEvaluator.evaluate(current, price: 130) // 再穿过
        XCTAssertTrue(fired, "回落之后再次穿过要再响一次")
    }

    func testNonRepeatingStaysLatchedAfterFallingBack() {
        var current = alert(.above, threshold: 100, repeats: false)
        (_, current) = PriceAlertEvaluator.evaluate(current, price: 120)
        (_, current) = PriceAlertEvaluator.evaluate(current, price: 90)

        XCTAssertTrue(current.isTriggered, "没勾重复提醒，回落也不该重新武装")

        let (fired, _) = PriceAlertEvaluator.evaluate(current, price: 130)
        XCTAssertFalse(fired, "只响一次")
    }

    /// 等于阈值时既不算越过也不算回落，闩锁不能来回抖
    func testExactlyAtThresholdDoesNotResetTheLatch() {
        let (fired, updated) = PriceAlertEvaluator.evaluate(alert(.above, threshold: 100, triggered: true), price: 100)

        XCTAssertFalse(fired)
        XCTAssertTrue(updated.isTriggered, "卡在阈值上不该把闩锁解开")
    }

    func testBelowDirectionMirrorsAbove() {
        var current = alert(.below, threshold: 100)
        (_, current) = PriceAlertEvaluator.evaluate(current, price: 80)
        (_, current) = PriceAlertEvaluator.evaluate(current, price: 110)

        XCTAssertFalse(current.isTriggered)

        let (fired, _) = PriceAlertEvaluator.evaluate(current, price: 70)
        XCTAssertTrue(fired)
    }

    // MARK: N 分钟内涨跌

    private func movement(percent: Double = 2, minutes: Int = 5, repeats: Bool = true, triggered: Bool = false) -> PriceAlert {
        PriceAlert(
            target: .stock(code: "sh600036"),
            direction: .movesWithin(percent: percent, minutes: minutes),
            threshold: percent,
            repeats: repeats,
            isTriggered: triggered
        )
    }

    /// 涨超阈值要响
    func testFiresWhenRisingBeyondThreshold() {
        let (fired, updated) = PriceAlertEvaluator.evaluate(movement(), price: 102, referencePrice: 100)

        XCTAssertTrue(fired)
        XCTAssertTrue(updated.isTriggered)
    }

    /// **跌**超阈值一样要响 —— 用户要的是「涨跌」，不是只盯涨
    func testFiresWhenFallingBeyondThreshold() {
        let (fired, _) = PriceAlertEvaluator.evaluate(movement(), price: 97.9, referencePrice: 100)

        XCTAssertTrue(fired)
    }

    func testDoesNotFireInsideTheThreshold() {
        let (fired, updated) = PriceAlertEvaluator.evaluate(movement(), price: 101, referencePrice: 100)

        XCTAssertFalse(fired)
        XCTAssertFalse(updated.isTriggered)
    }

    /// ⚠️ 没有参考价（刚启动、刚加进自选）时**什么都不做**：
    /// 不响，也不动闩锁 —— 拿一个更近的价格冒充「N 分钟前」会静默漏报
    func testWithoutReferencePriceNothingHappens() {
        let (fired, updated) = PriceAlertEvaluator.evaluate(movement(triggered: true), price: 200, referencePrice: nil)

        XCTAssertFalse(fired)
        XCTAssertTrue(updated.isTriggered, "闩锁也不该被改动")
    }

    func testMovementRearmsAfterCalmingDown() {
        var current = movement()
        (_, current) = PriceAlertEvaluator.evaluate(current, price: 103, referencePrice: 100)
        XCTAssertTrue(current.isTriggered)

        (_, current) = PriceAlertEvaluator.evaluate(current, price: 100.5, referencePrice: 100)
        XCTAssertFalse(current.isTriggered, "波动回到阈值内就该重新武装")
    }

    func testMovementHonoursRepeatFlag() {
        var current = movement(repeats: false)
        (_, current) = PriceAlertEvaluator.evaluate(current, price: 103, referencePrice: 100)
        (_, current) = PriceAlertEvaluator.evaluate(current, price: 100.5, referencePrice: 100)

        XCTAssertTrue(current.isTriggered, "没勾重复提醒就一直锁着")
    }

    func testMovementRatioHelper() {
        XCTAssertEqual(PriceAlert.Direction.movement(price: 102, reference: 100)!, 0.02, accuracy: 1e-9)
        XCTAssertEqual(PriceAlert.Direction.movement(price: 98, reference: 100)!, -0.02, accuracy: 1e-9)
        XCTAssertNil(PriceAlert.Direction.movement(price: 100, reference: 0))
        XCTAssertNil(PriceAlert.Direction.movement(price: .nan, reference: 100))
    }

    func testMovementSummaryAndMessage() {
        let alert = movement(percent: 2, minutes: 5)

        XCTAssertEqual(alert.summary(displayName: "招商银行"), "⚡️ 招商银行 5 分钟内涨跌 ±2.00%")
        XCTAssertEqual(alert.displayMessage(price: 102.5), "sh600036: 102.50（5 分钟内涨跌超过 2.00%）")
    }

    /// 新方向要能存能读；老数据（"above"/"below" 两个裸字符串）也必须还认
    func testDirectionCodableIsBackwardCompatible() throws {
        for direction in [PriceAlert.Direction.above, .below, .movesWithin(percent: 2.5, minutes: 15)] {
            var alert = PriceAlert()
            alert.direction = direction

            let data = try JSONEncoder().encode(alert)
            XCTAssertEqual(try JSONDecoder().decode(PriceAlert.self, from: data).direction, direction)
        }

        let legacy = #"{"id":"11111111-2222-3333-4444-555555555555","target":"gold","direction":"below","threshold":880}"#
        XCTAssertEqual(
            try JSONDecoder().decode(PriceAlert.self, from: Data(legacy.utf8)).direction,
            .below
        )
    }

    // MARK: 默认提示语

    func testDefaultMessageForStockIsCodeColonPrice() {
        var stock = PriceAlert(target: .stock(code: "sh600036"), direction: .above, threshold: 45)

        XCTAssertEqual(stock.displayMessage(price: 45.678), "sh600036: 45.68")
        stock.message = "招行到价了"
        XCTAssertEqual(stock.displayMessage(price: 45.678), "招行到价了", "自定义优先")
    }

    func testOverseasPriceAlertsIdentifyTheirCurrency() {
        let us = PriceAlert(target: .stock(code: "usAAPL"), direction: .above, threshold: 300)
        let hk = PriceAlert(target: .stock(code: "hk00700"), direction: .below, threshold: 400)
        XCTAssertEqual(PriceAlert.defaultMessage(for: us, price: 338.35), "usAAPL: 338.35 USD")
        XCTAssertEqual(hk.summary(displayName: "腾讯控股"), "📉 腾讯控股 ≤ 400.00 HKD")
    }

    func testDefaultMessageForGold() {
        let gold = PriceAlert(target: .gold, direction: .above, threshold: 900)

        XCTAssertEqual(gold.displayMessage(price: 925.906), "金价: 925.91")
    }

    // MARK: 摘要与编码

    func testSummary() {
        let alert = PriceAlert(target: .stock(code: "sh600036"), direction: .above, threshold: 45)

        XCTAssertEqual(alert.summary(displayName: "招商银行"), "📈 招商银行 ≥ 45.00")
    }

    func testTargetRoundTripsThroughJSON() throws {
        for target in [PriceAlert.Target.gold, .stock(code: "sz159813")] {
            var alert = PriceAlert()
            alert.target = target

            let data = try JSONEncoder().encode(alert)
            let decoded = try JSONDecoder().decode(PriceAlert.self, from: data)

            XCTAssertEqual(decoded.target, target)
        }
    }

    /// 旧数据缺字段（比如还没有 repeats / isTriggered 的时候）必须解得出
    func testDecodesWithoutNewerKeys() throws {
        let legacy = """
        {"id":"11111111-2222-3333-4444-555555555555","target":"gold","direction":"above","threshold":900}
        """

        let alert = try JSONDecoder().decode(PriceAlert.self, from: Data(legacy.utf8))

        XCTAssertEqual(alert.target, .gold)
        XCTAssertEqual(alert.threshold, 900)
        XCTAssertEqual(alert.methods, .default)
        XCTAssertTrue(alert.repeats, "默认要重复提醒")
        XCTAssertFalse(alert.isTriggered)
    }

    func testUnknownOrInvalidMovementDirectionDoesNotBecomeAnAboveAlert() throws {
        for raw in ["move:NaN:5", "move:-2:5", "move:2:0", "move:2:121", "move:garbage:5", "future:2:5"] {
            let json = """
            {"target":"gold","direction":"\(raw)","threshold":2}
            """
            XCTAssertThrowsError(try JSONDecoder().decode(PriceAlert.self, from: Data(json.utf8)), raw)
        }
        let legacy = #"{"target":"gold","direction":"below","threshold":900}"#
        XCTAssertEqual(
            try JSONDecoder().decode(PriceAlert.self, from: Data(legacy.utf8)).direction,
            .below
        )
    }

    func testUnknownTargetCannotSilentlyBecomeGold() {
        for raw in ["platinum", "stock:", "stock:usAAPL&x=1"] {
            let json = """
            {"target":"\(raw)","direction":"above","threshold":900}
            """
            XCTAssertThrowsError(try JSONDecoder().decode(PriceAlert.self, from: Data(json.utf8)), raw)
        }
    }
}

final class PriceHistoryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testFiveSecondSamplesKeepAReferenceAcrossEverySecondOfTheWindow() {
        var history = PriceHistory()
        for second in stride(from: 0, through: 360, by: 5) {
            history.record(price: 100 + Double(second), for: "sh600036",
                           at: start.addingTimeInterval(Double(second)), window: 300)
            if second >= 300 {
                for offset in 0..<5 {
                    let now = start.addingTimeInterval(Double(second + offset))
                    XCTAssertNotNil(history.referencePrice(for: "sh600036", minutes: 5, at: now),
                                    "丢了窗口左边界前的采样：\(second + offset) 秒")
                }
            }
        }
        XCTAssertNil(history.referencePrice(for: "sh600036", minutes: 5,
                                            at: start.addingTimeInterval(299)))
    }

    func testGapTooLongDoesNotPretendAnOldSampleIsFiveMinutesAgo() {
        var history = PriceHistory()
        history.record(price: 100, for: "sh600036", at: start, window: 300)
        history.record(price: 130, for: "sh600036", at: start.addingTimeInterval(400), window: 300)
        XCTAssertNil(history.referencePrice(for: "sh600036", minutes: 5,
                                            at: start.addingTimeInterval(400)))
    }

    func testReferenceUsesLastSampleNotAFutureOne() {
        var history = PriceHistory()
        history.record(price: 100, for: "sh600036", at: start, window: 60)
        history.record(price: 120, for: "sh600036", at: start.addingTimeInterval(5), window: 60)
        XCTAssertEqual(history.referencePrice(for: "sh600036", minutes: 1,
                                               at: start.addingTimeInterval(63)), 100)
        XCTAssertNil(history.referencePrice(for: "sh600036", minutes: 121,
                                            at: start.addingTimeInterval(121 * 60)))
    }

    func testMovementCanFireBetweenFiveSecondSamplingBoundaries() {
        var history = PriceHistory()
        for second in stride(from: 0, through: 305, by: 5) {
            history.record(
                price: second >= 305 ? 103 : 100,
                for: "sh600036",
                at: start.addingTimeInterval(Double(second)),
                window: 300
            )
        }
        let now = start.addingTimeInterval(307)
        let reference = history.referencePrice(for: "sh600036", minutes: 5, at: now)
        let alert = PriceAlert(
            target: .stock(code: "sh600036"),
            direction: .movesWithin(percent: 2, minutes: 5),
            threshold: 2
        )
        XCTAssertEqual(reference, 100)
        XCTAssertTrue(PriceAlertEvaluator.evaluate(alert, price: 103, referencePrice: reference).fired)
    }

    func testClearRemovedStockButKeepGoldHistory() {
        var history = PriceHistory()
        history.record(price: 100, for: "sh600036", at: start, window: 300)
        history.record(price: 900, for: "__gold__", at: start, window: 300)
        history.retain(keys: ["__gold__"])
        XCTAssertNil(history.referencePrice(for: "sh600036", minutes: 1,
                                            at: start.addingTimeInterval(60)))
        XCTAssertEqual(history.referencePrice(for: "__gold__", minutes: 1,
                                             at: start.addingTimeInterval(60)), 900)
    }
}

@MainActor
final class PriceAlertStoreTests: XCTestCase {
    private func makeStore() throws -> (PriceAlertStore, UserDefaults, String) {
        let suite = "PriceAlertTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (PriceAlertStore(defaults: defaults), defaults, suite)
    }

    func testRoundTrip() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        store.upsert(PriceAlert(target: .stock(code: "sh600036"), direction: .above, threshold: 45))
        store.upsert(PriceAlert(target: .gold, direction: .below, threshold: 880))

        let reread = PriceAlertStore(defaults: defaults)
        XCTAssertEqual(reread.alerts.count, 2)
        XCTAssertEqual(reread.alerts(for: .stock(code: "sh600036")).count, 1)
        XCTAssertEqual(reread.alerts(for: .gold).count, 1)
    }

    /// 一条坏数据只能丢它自己 —— 整份 try? decode 会让其余提醒清零并被写回
    func testOneBadAlertDoesNotWipeTheOthers() throws {
        let (_, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let raw = """
        [{"id":"11111111-2222-3333-4444-555555555555","target":"gold","direction":"above","threshold":900},
         {"id":"22222222-2222-3333-4444-555555555555","target":"gold","direction":"above","threshold":"贵"},
         {"id":"33333333-2222-3333-4444-555555555555","target":"gold","direction":"below","threshold":800}]
        """
        defaults.set(Data(raw.utf8), forKey: "priceAlerts")

        let store = PriceAlertStore(defaults: defaults)
        XCTAssertEqual(store.alerts.count, 2, "只该丢坏的那条")

        store.upsert(PriceAlert(target: .gold, direction: .above, threshold: 1000))
        XCTAssertEqual(PriceAlertStore(defaults: defaults).alerts.count, 3)
    }

    // MARK: 从旧版两条金价阈值迁移

    func testMigratesLegacyGoldThresholds() throws {
        let suite = "PriceAlertTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(950.0, forKey: "highPriceThreshold")
        defaults.set(880.0, forKey: "lowPriceThreshold")

        let store = PriceAlertStore(defaults: defaults)

        XCTAssertEqual(store.alerts.count, 2)
        XCTAssertEqual(store.alerts(for: .gold).count, 2)
        XCTAssertTrue(store.alerts.contains { $0.direction == .above && $0.threshold == 950 })
        XCTAssertTrue(store.alerts.contains { $0.direction == .below && $0.threshold == 880 })
        XCTAssertNil(defaults.object(forKey: "highPriceThreshold"), "迁移完要清掉旧键，否则删了会被复活")
        XCTAssertNil(defaults.object(forKey: "lowPriceThreshold"))
    }

    func testDoesNotMigrateTwice() throws {
        let suite = "PriceAlertTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(950.0, forKey: "highPriceThreshold")

        let first = PriceAlertStore(defaults: defaults)
        first.removeAll()

        // 用户在新界面里删光了，重启不该被旧键复活
        let second = PriceAlertStore(defaults: defaults)
        XCTAssertTrue(second.alerts.isEmpty)
    }

    func testNoLegacyKeysMeansEmpty() throws {
        let (store, _, _) = try makeStore()

        XCTAssertTrue(store.alerts.isEmpty)
    }
}
