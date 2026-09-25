import AppKit
import XCTest

@testable import MarketBar

final class HoverPanelInteractionTests: XCTestCase {
    private let button = NSRect(x: 400, y: 800, width: 60, height: 24)
    private let panel = NSRect(x: 180, y: 100, width: 500, height: 696) // 4pt gap

    func testCrossingGapKeepsPanelOpen() {
        XCTAssertTrue(HoverPanelInteraction.contains(
            NSPoint(x: 430, y: 798), button: button, panel: panel
        ))
        XCTAssertTrue(HoverPanelInteraction.contains(
            NSPoint(x: 430, y: 795), button: button, panel: panel
        ))
    }

    func testOutsideButtonAndPanelStillDismisses() {
        XCTAssertFalse(HoverPanelInteraction.contains(
            NSPoint(x: 300, y: 798), button: button, panel: panel
        ))
        XCTAssertFalse(HoverPanelInteraction.contains(
            NSPoint(x: 800, y: 300), button: button, panel: panel
        ))
    }

    func testOverlappingOrDistantPanelDoesNotCreateExtraHitArea() {
        let overlapping = NSRect(x: 180, y: 805, width: 500, height: 100)
        XCTAssertFalse(HoverPanelInteraction.contains(
            NSPoint(x: 430, y: 795), button: button, panel: overlapping
        ))
        let displaced = NSRect(x: 700, y: 100, width: 500, height: 696)
        XCTAssertFalse(HoverPanelInteraction.contains(
            NSPoint(x: 430, y: 798), button: button, panel: displaced
        ))
    }
}
