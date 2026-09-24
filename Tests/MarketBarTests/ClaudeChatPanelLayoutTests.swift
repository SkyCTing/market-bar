import AppKit
import XCTest

@testable import MarketBar

@MainActor
final class ClaudeChatPanelLayoutTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1512, height: 900)
    private let panelSize = ClaudeChatPanelLayout.defaultSize

    func testPanelSitsLeftOfThePet() {
        let pet = NSRect(x: 1200, y: 400, width: 240, height: 240)

        let origin = ClaudeChatPanelLayout.origin(anchor: pet, panelSize: panelSize, visibleFrame: screen)

        XCTAssertEqual(origin.x + panelSize.width + ClaudeChatPanelLayout.gap, pet.minX, accuracy: 0.5)
        XCTAssertEqual(origin.y + panelSize.height / 2, pet.midY, accuracy: 0.5)
    }

    /// 宠物贴在屏幕左边缘时，左边放不下 → 换到右侧
    func testPanelFlipsToTheRightWhenThereIsNoRoomOnTheLeft() {
        let pet = NSRect(x: 0, y: 300, width: 240, height: 240)

        let origin = ClaudeChatPanelLayout.origin(anchor: pet, panelSize: panelSize, visibleFrame: screen)

        XCTAssertEqual(origin.x, pet.maxX + ClaudeChatPanelLayout.gap, accuracy: 0.5)
    }

    func testPanelStaysInsideTheVisibleFrame() {
        for petY in [-100.0, 0, 300, 880, 1200] {
            let pet = NSRect(x: 1300, y: petY, width: 240, height: 240)
            let origin = ClaudeChatPanelLayout.origin(anchor: pet, panelSize: panelSize, visibleFrame: screen)
            let frame = NSRect(origin: origin, size: panelSize)

            XCTAssertGreaterThanOrEqual(frame.minX, screen.minX - 0.5, "y=\(petY)")
            XCTAssertLessThanOrEqual(frame.maxX, screen.maxX + 0.5, "y=\(petY)")
            XCTAssertGreaterThanOrEqual(frame.minY, screen.minY - 0.5, "y=\(petY)")
            XCTAssertLessThanOrEqual(frame.maxY, screen.maxY + 0.5, "y=\(petY)")
        }
    }

    /// 小屏（1280×800）也要放得下
    func testPanelFitsOnASmallScreen() {
        let smallScreen = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let pet = NSRect(x: 1000, y: 300, width: 220, height: 220)

        let origin = ClaudeChatPanelLayout.origin(anchor: pet, panelSize: panelSize, visibleFrame: smallScreen)
        let frame = NSRect(origin: origin, size: panelSize)

        XCTAssertGreaterThanOrEqual(frame.minX, 0)
        XCTAssertLessThanOrEqual(frame.maxX, smallScreen.maxX)
    }

    func testPanelSizeIsUsableAndWithinTheMinimum() {
        XCTAssertGreaterThanOrEqual(ClaudeChatPanelLayout.defaultSize.width, ClaudeChatPanelLayout.minimumSize.width)
        XCTAssertGreaterThanOrEqual(ClaudeChatPanelLayout.defaultSize.height, ClaudeChatPanelLayout.minimumSize.height)
    }

    // MARK: 输入框高度（测量而非估算）

    func testEmptyInputUsesMinimumHeight() {
        XCTAssertEqual(
            ClaudeChatPanelLayout.inputHeight(for: "", width: 300, font: .systemFont(ofSize: 13)),
            ClaudeChatPanelLayout.inputMinimumHeight
        )
    }

    func testInputGrowsWithContent() {
        let font = NSFont.systemFont(ofSize: 13)
        let single = ClaudeChatPanelLayout.inputHeight(for: "一行", width: 300, font: font)
        let multi = ClaudeChatPanelLayout.inputHeight(
            for: String(repeating: "这是一段很长的输入，", count: 8),
            width: 300,
            font: font
        )

        XCTAssertGreaterThanOrEqual(single, ClaudeChatPanelLayout.inputMinimumHeight)
        XCTAssertGreaterThan(multi, single)
    }

    func testInputHeightIsCappedSoTheTranscriptKeepsRoom() {
        let font = NSFont.systemFont(ofSize: 13)
        let huge = ClaudeChatPanelLayout.inputHeight(
            for: String(repeating: "很长的内容", count: 500),
            width: 300,
            font: font
        )

        XCTAssertEqual(huge, ClaudeChatPanelLayout.inputMaximumHeight)
        XCTAssertLessThan(huge, ClaudeChatPanelLayout.defaultSize.height / 2)
    }
}
