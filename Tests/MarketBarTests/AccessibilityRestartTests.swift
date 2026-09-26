import XCTest

@testable import MarketBar

final class AccessibilityRestartTests: XCTestCase {
    func testAlreadyAuthorizedLaunchNeverRestarts() {
        var policy = AccessibilityRestartPolicy()
        XCTAssertFalse(policy.shouldRestart(trusted: true, canRestart: true))
        XCTAssertFalse(policy.shouldRestart(trusted: true, canRestart: true))
    }

    func testGrantAfterDenialRestartsExactlyOnce() {
        var policy = AccessibilityRestartPolicy()
        XCTAssertFalse(policy.shouldRestart(trusted: false, canRestart: true))
        XCTAssertTrue(policy.shouldRestart(trusted: true, canRestart: true))
        XCTAssertFalse(policy.shouldRestart(trusted: true, canRestart: true))
        XCTAssertFalse(policy.shouldRestart(trusted: false, canRestart: true))
        XCTAssertFalse(policy.shouldRestart(trusted: true, canRestart: true))
    }

    func testWaitsUntilEditorsAreClosed() {
        var policy = AccessibilityRestartPolicy()
        XCTAssertFalse(policy.shouldRestart(trusted: false, canRestart: false))
        XCTAssertFalse(policy.shouldRestart(trusted: true, canRestart: false))
        XCTAssertFalse(policy.shouldRestart(trusted: true, canRestart: false))
        XCTAssertTrue(policy.shouldRestart(trusted: true, canRestart: true))
    }

    func testRevocationDuringSessionCanTriggerOnLaterGrant() {
        var policy = AccessibilityRestartPolicy()
        XCTAssertFalse(policy.shouldRestart(trusted: true, canRestart: true))
        XCTAssertFalse(policy.shouldRestart(trusted: false, canRestart: true))
        XCTAssertTrue(policy.shouldRestart(trusted: true, canRestart: true))
    }
}
