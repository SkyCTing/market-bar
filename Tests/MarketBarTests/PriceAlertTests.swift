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

    // MARK: 默认提示语

    func testDefaultMessageForStockIsCodeColonPrice() {
        var stock = PriceAlert(target: .stock(code: "sh600036"), direction: .above, threshold: 45)

        XCTAssertEqual(stock.displayMessage(price: 45.678), "sh600036: 45.68")
        stock.message = "招行到价了"
        XCTAssertEqual(stock.displayMessage(price: 45.678), "招行到价了", "自定义优先")
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
