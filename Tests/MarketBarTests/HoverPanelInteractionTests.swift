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

    func testPinnedHotKeyPanelStaysOpenAfterCursorLeaves() {
        XCTAssertFalse(HoverPanelInteraction.shouldDismiss(pinned: true, overButton: false, overPanel: false))
        XCTAssertTrue(HoverPanelInteraction.shouldDismiss(pinned: false, overButton: false, overPanel: false))
        XCTAssertFalse(HoverPanelInteraction.shouldDismiss(pinned: false, overButton: false, overPanel: true))
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

    func testOnlyStockNameAndPriceRevealTheirQuoteTime() {
        let titles = ["usAAPL": NSRect(x: 20, y: 120, width: 130, height: 20)]
        let prices = ["usAAPL": NSRect(x: 460, y: 120, width: 96, height: 20)]
        XCTAssertEqual(
            HoverPanelInteraction.quoteCode(at: NSPoint(x: 30, y: 130), titles: titles, prices: prices),
            "usAAPL"
        )
        XCTAssertEqual(
            HoverPanelInteraction.quoteCode(at: NSPoint(x: 500, y: 130), titles: titles, prices: prices),
            "usAAPL"
        )
        XCTAssertNil(HoverPanelInteraction.quoteCode(
            at: NSPoint(x: 200, y: 130), titles: titles, prices: prices
        ))
    }
}
