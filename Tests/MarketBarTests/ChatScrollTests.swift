import AppKit
import XCTest

@testable import MarketBar

@MainActor
final class ChatScrollTests: XCTestCase {
    private var panel: ClaudeChatPanel!
    private var view: ClaudeChatView!
    private var scroll: ChatTranscriptScrollView!
    private var transcript: ChatTranscriptTextView!

    override func setUp() async throws {
        _ = NSApplication.shared
        view = ClaudeChatView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))
        panel = ClaudeChatPanel(contentRect: view.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        panel.orderFront(nil)
        view.layoutSubtreeIfNeeded()
        scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? ChatTranscriptScrollView }.first)
        transcript = try XCTUnwrap(scroll.documentView as? ChatTranscriptTextView)
        await settle()
    }

    override func tearDown() async throws {
        panel.close()
        panel = nil
        view = nil
        scroll = nil
        transcript = nil
    }

    private func settle() async {
        for _ in 0..<3 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(60))
    }

    private func fillHistory() async {
        for index in 0..<40 {
            view.append(ChatMessage(role: .assistant, text: "历史消息 \(index)\n第二行内容"))
        }
        await settle()
    }

    private func wheel(_ delta: Int32) throws {
        let cg = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0
        ))
        scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cg)))
    }

    private var distanceFromBottom: CGFloat {
        transcript.bounds.maxY - scroll.contentView.bounds.maxY
    }

    func testBulkHistoryAndRapidStreamingAlwaysFollowLatest() async {
        await fillHistory()
        XCTAssertLessThanOrEqual(abs(distanceFromBottom), 1)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        view.beginStream()
        for size in [20, 50, 100] {
            view.renderStream(
                thinking: "正在思考", text: String(repeating: "新增内容\n", count: size),
                tokens: nil, date: Date(), isFinal: false
            )
        }
        await settle()
        XCTAssertLessThanOrEqual(abs(distanceFromBottom), 1)
        let previousHeight = transcript.frame.height
        view.renderStream(
            thinking: "", text: String(repeating: "最终回复\n", count: 140),
            tokens: nil, date: Date(), isFinal: true
        )
        await settle()
        XCTAssertGreaterThan(transcript.frame.height, previousHeight)
        XCTAssertLessThanOrEqual(abs(distanceFromBottom), 1)
    }

    func testWheelUpCancelsAlreadyQueuedAutoScrollAndKeepsReadingPosition() async throws {
        await fillHistory()
        view.beginStream()
        view.renderStream(thinking: "", text: "第一段", tokens: nil, date: Date(), isFinal: false)
        try wheel(8)
        await settle()
        let readingY = scroll.contentView.bounds.minY
        XCTAssertGreaterThan(distanceFromBottom, 4, "Real wheel event must move away from the bottom")
        view.renderStream(
            thinking: "", text: String(repeating: "后续回复\n", count: 100),
            tokens: nil, date: Date(), isFinal: true
        )
        await settle()
        XCTAssertEqual(scroll.contentView.bounds.minY, readingY, accuracy: 1)
        XCTAssertGreaterThan(distanceFromBottom, 100)
    }

    func testScrollingBackToBottomResumesFollowing() async throws {
        await fillHistory()
        try wheel(8)
        await settle()
        XCTAssertGreaterThan(distanceFromBottom, 4)
        try wheel(-10_000)
        await settle()
        XCTAssertLessThanOrEqual(abs(distanceFromBottom), 1)
        view.append(ChatMessage(role: .assistant, text: String(repeating: "新消息\n", count: 40)))
        await settle()
        XCTAssertLessThanOrEqual(abs(distanceFromBottom), 1)
    }

    func testSendingNewMessageResumesFollowingFromHistory() async throws {
        await fillHistory()
        try wheel(8)
        await settle()
        view.insertDraft("新的提问")
        view.onSend = { [weak view] text, _ in view?.append(ChatMessage(role: .user, text: text)) }
        let input = try XCTUnwrap(view.inputResponder as? ChatInputTextView)
        input.onSend?()
        await settle()
        XCTAssertLessThanOrEqual(abs(distanceFromBottom), 1)
    }

    func testResizeKeepsFollowingAndTranscriptResetDiscardsReadingPosition() async throws {
        await fillHistory()
        panel.setContentSize(NSSize(width: 420, height: 350))
        await settle()
        XCTAssertLessThanOrEqual(abs(distanceFromBottom), 1)
        try wheel(8)
        view.clearTranscript()
        view.append(ChatMessage(role: .system, text: "新会话"))
        await settle()
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
        XCTAssertLessThanOrEqual(abs(distanceFromBottom), 1)
    }

    func testScrollbarTrackingAlsoPausesFollowing() async throws {
        await fillHistory()
        let scroller = try XCTUnwrap(scroll.verticalScroller as? ChatTranscriptScroller)
        XCTAssertTrue(ChatTranscriptScroller.isCompatibleWithOverlayScrollers)
        scroller.onUserScrollBegan?()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        scroll.reflectScrolledClipView(scroll.contentView)
        scroller.onUserScrollEnded?()
        view.append(ChatMessage(role: .assistant, text: String(repeating: "回复\n", count: 30)))
        await settle()
        XCTAssertEqual(scroll.contentView.bounds.minY, 100, accuracy: 1)
    }

    func testPageUpPausesFollowingWhileReadingWithKeyboard() async throws {
        await fillHistory()
        panel.makeFirstResponder(transcript)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "\u{F72C}",
            charactersIgnoringModifiers: "\u{F72C}", isARepeat: false, keyCode: 116
        ))
        transcript.keyDown(with: event)
        await settle()
        XCTAssertGreaterThan(distanceFromBottom, 4)
        let readingY = scroll.contentView.bounds.minY
        view.append(ChatMessage(role: .assistant, text: String(repeating: "新消息\n", count: 40)))
        await settle()
        XCTAssertEqual(scroll.contentView.bounds.minY, readingY, accuracy: 1)
    }
}
