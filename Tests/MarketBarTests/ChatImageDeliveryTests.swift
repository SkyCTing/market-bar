import AppKit
import XCTest
import ImageIO

@testable import MarketBar

final class ChatImageDeliveryTests: XCTestCase {
    func testStdinIsWrittenAndClosedEvenForPayloadLargerThanPipeBuffer() async throws {
        let payload = Data(repeating: 65, count: 512 * 1_024)
        let output = try await ClaudeProcessRunner.run(
            ClaudeProcessSpec(
                executable: URL(fileURLWithPath: "/bin/cat"), arguments: [],
                workingDirectory: FileManager.default.temporaryDirectory, stdin: payload
            ),
            timeout: 2
        )
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.stdout, payload)
    }

    func testImageInvocationExplicitlyEnablesPrintMode() {
        let arguments = ClaudeChatInvocation.arguments(
            prompt: "test", sessionID: UUID(), isResume: false, usesStreamInput: true
        )
        XCTAssertTrue(arguments.contains("--print"))
    }

    func testNonReadingChildDoesNotBlockInputTimeout() async throws {
        let start = Date()
        do {
            _ = try await ClaudeProcessRunner.run(
                ClaudeProcessSpec(
                    executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"],
                    workingDirectory: FileManager.default.temporaryDirectory,
                    stdin: Data(repeating: 65, count: 512 * 1_024)
                ), timeout: 0.2
            )
            XCTFail("Expected timeout")
        } catch let error as ClaudeChatError {
            guard case .timeout = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testEarlyReaderExitDoesNotCrashAppOrHideSessionFailure() async throws {
        let output = try await ClaudeProcessRunner.run(
            ClaudeProcessSpec(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'No conversation found with session ID: test' >&2; exit 1"],
                workingDirectory: FileManager.default.temporaryDirectory,
                stdin: Data(repeating: 65, count: 512 * 1_024)
            ), timeout: 2
        )
        XCTAssertEqual(output.status, 1)
        XCTAssertTrue(ClaudeChatParser.indicatesBrokenSession(output))
    }

    func testFullImageMessageReachesChildAsValidJSON() async throws {
        let image = try XCTUnwrap(ChatImageAttachment.make(from: testImage()))
        let message = ClaudeChatMessage(text: "测试图片", images: [image])
        let data = try XCTUnwrap(message.streamJSONLine())
        let output = try await ClaudeProcessRunner.run(
            ClaudeProcessSpec(
                executable: URL(fileURLWithPath: "/bin/cat"), arguments: [],
                workingDirectory: FileManager.default.temporaryDirectory, stdin: data
            ), timeout: 2
        )
        XCTAssertEqual(output.stdout, data)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: output.stdout) as? [String: Any])
        let payload = try XCTUnwrap(json["message"] as? [String: Any])
        let blocks = try XCTUnwrap(payload["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[1]["type"] as? String, "image")
    }

    func testPixelBoundAndEXIFRotationAreApplied() throws {
        let data = try testImage(width: 3_200, height: 1_600)
        let image = try XCTUnwrap(ChatImageAttachment.make(from: data))
        let png = try XCTUnwrap(Data(base64Encoded: image.base64))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(rep.pixelsWide, 1_568)
        XCTAssertEqual(rep.pixelsHigh, 784)

        let source = try XCTUnwrap(CGImageSourceCreateWithData(try testImage(width: 20, height: 10) as CFData, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let rotated = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(rotated, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let attachment = try XCTUnwrap(ChatImageAttachment.make(from: rotated as Data))
        let result = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(Data(base64Encoded: attachment.base64))))
        XCTAssertEqual(result.pixelsWide, 10)
        XCTAssertEqual(result.pixelsHigh, 20)
    }
}

private func testImage(width: Int = 4, height: Int = 4) throws -> Data {
    let rep = try XCTUnwrap(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ))
    rep.bitmapData?.initialize(repeating: 255, count: rep.bytesPerRow * height)
    return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
}

@MainActor
final class ChatImageInteractionTests: XCTestCase {
    func testClearingTranscriptInvalidatesOldStreamOffset() {
        let view = ClaudeChatView()
        view.append(ChatMessage(role: .user, text: String(repeating: "old", count: 200)))
        view.beginStream()
        view.clearTranscript()
        view.renderStream(thinking: "", text: "late old reply", tokens: nil, date: Date(), isFinal: false)
        XCTAssertTrue(view.isTranscriptEmpty)
        view.beginStream()
        view.renderStream(thinking: "", text: "new reply", tokens: nil, date: Date(), isFinal: true)
        XCTAssertFalse(view.isTranscriptEmpty)
    }

    func testCommandVThroughEditMenuAttachesImageFromNamedPasteboard() throws {
        _ = NSApplication.shared
        let board = NSPasteboard(name: .init("ChatImageInteractionTests.\(UUID())"))
        defer { board.releaseGlobally() }
        board.setData(try testImage(), forType: .png)
        let view = ClaudeChatView(frame: NSRect(x: 0, y: 0, width: 560, height: 520))
        let input = try XCTUnwrap(view.inputResponder as? ChatInputTextView)
        input.pasteboard = board
        XCTAssertTrue(input.readablePasteboardTypes.contains(.png))
        XCTAssertTrue(input.readablePasteboardTypes.contains(.tiff))
        XCTAssertTrue(input.readablePasteboardTypes.contains(.fileURL))
        let menu = try XCTUnwrap(MarketBarApp.makeEditMenu().items.first?.submenu)
        for item in menu.items { item.target = input }
        menu.update()
        let pasteItem = try XCTUnwrap(menu.items.first { $0.action == #selector(NSText.paste(_:)) })
        XCTAssertTrue(pasteItem.isEnabled)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9
        ))
        XCTAssertTrue(menu.performKeyEquivalent(with: event))
        XCTAssertEqual(view.attachedImages.count, 1)
        XCTAssertTrue(view.inputText.isEmpty)
        let preview = try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first {
            $0.toolTip == "图片 1：点击移除"
        })
        XCTAssertNotNil(preview.image)
        preview.performClick(nil)
        XCTAssertTrue(view.attachedImages.isEmpty)
        board.clearContents()
        board.setString("hello", forType: .string)
        input.string = "hello"
        input.setSelectedRange(NSRange(location: 0, length: 5))
        var error: String?
        input.onPasteError = { error = $0 }
        XCTAssertTrue(menu.performKeyEquivalent(with: event))
        XCTAssertEqual(input.string, "hello")
        XCTAssertNil(error, "Pasting identical text must not report an image failure")
        view.setSending(true)
        menu.update()
        XCTAssertFalse(pasteItem.isEnabled)
    }

    func testDraftAndAttachmentsRemainUntilSuccessfulSend() throws {
        let view = ClaudeChatView()
        let image = try XCTUnwrap(ChatImageAttachment.make(from: testImage()))
        view.insertDraft("看看图片")
        view.attachImages([image])
        var sent: ClaudeChatMessage?
        view.onSend = { sent = ClaudeChatMessage(text: $0, images: $1) }
        let input = try XCTUnwrap(view.inputResponder as? ChatInputTextView)
        input.onSend?()
        XCTAssertEqual(sent, ClaudeChatMessage(text: "看看图片", images: [image]))
        XCTAssertEqual(view.inputText, "看看图片")
        XCTAssertEqual(view.attachedImages, [image])
        view.setSending(true)
        let sessionButton = try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first { $0.title == "会话…" })
        XCTAssertFalse(sessionButton.isEnabled)
        view.attachImages([image])
        XCTAssertEqual(view.attachedImages.count, 1)
        view.setSending(false)
        XCTAssertTrue(sessionButton.isEnabled)
        XCTAssertEqual(view.inputText, "看看图片", "Failure or cancellation keeps the draft")
        view.clearDraft()
        XCTAssertTrue(view.inputText.isEmpty)
        XCTAssertTrue(view.attachedImages.isEmpty)
    }

    func testCommandDeleteOnlyClearsImagesWhenPresent() throws {
        let view = ClaudeChatView()
        view.insertDraft("hello")
        let input = try XCTUnwrap(view.inputResponder as? ChatInputTextView)
        input.setSelectedRange(NSRange(location: 5, length: 0))
        input.deleteToBeginningOfLine(nil)
        XCTAssertEqual(view.inputText, "")
        view.insertDraft("keep text")
        view.attachImages([try XCTUnwrap(ChatImageAttachment.make(from: testImage()))])
        input.deleteToBeginningOfLine(nil)
        XCTAssertEqual(view.inputText, "keep text")
        XCTAssertTrue(view.attachedImages.isEmpty)
    }

    func testMultipleFinderFilesAndAttachmentLimit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ImagePaste-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Could not remove test images: \(error)") }
        }
        let files = [directory.appendingPathComponent("one.png"), directory.appendingPathComponent("two.png")]
        for file in files { try testImage().write(to: file) }
        let board = NSPasteboard(name: .init("ChatImageInteractionTests.\(UUID())"))
        defer { board.releaseGlobally() }
        board.writeObjects(files.map { $0 as NSURL })
        let images = try ChatImageAttachment.images(from: board)
        XCTAssertEqual(images.count, 2)
        let view = ClaudeChatView()
        view.attachImages(images)
        view.attachImages(images)
        XCTAssertEqual(view.attachedImages.count, 4)
        view.attachImages(images)
        XCTAssertEqual(view.attachedImages.count, 4)
    }

    func testControllerRetriesBrokenSessionWithSameImagePayload() async throws {
        let id = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ImageRetry-\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let suite = "ChatImageRetry.\(id)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let executable = directory.appendingPathComponent("fake-claude")
        let script = """
        #!/bin/sh
        if [ ! -e "$0.first" ]; then
            /bin/cat > "$0.first"
            printf 'No conversation found with session ID: test' >&2
            exit 1
        fi
        /bin/cat > "$0.second"
        printf '%s\\n' '{"type":"result","result":"图片已收到","is_error":false}'
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        defaults.set(id.uuidString, forKey: "claudeChatSessionID")
        defaults.set(executable.path, forKey: "claudeChatExecutablePath")
        defaults.set(directory.path, forKey: "claudeChatWorkingDirectory")
        let controller = ClaudeChatController(defaults: defaults)
        defer {
            controller.shutdown()
            ChatTranscriptStore.remove(sessionID: id)
            if let retriedID = controller.sessionID { ChatTranscriptStore.remove(sessionID: retriedID) }
            defaults.removePersistentDomain(forName: suite)
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Could not clean up isolated retry test: \(error)") }
        }
        let draft = "图片重试测试 \(id)"
        controller.showDraft(draft, anchor: NSRect(x: 500, y: 500, width: 200, height: 200))
        let view = try XCTUnwrap(NSApp.windows.compactMap { $0.contentView as? ClaudeChatView }.first {
            $0.inputText == draft
        })
        let image = try XCTUnwrap(ChatImageAttachment.make(from: testImage()))
        view.attachImages([image])
        let input = try XCTUnwrap(view.inputResponder as? ChatInputTextView)
        input.onSend?()
        for _ in 0..<200 {
            if view.inputText.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(view.inputText.isEmpty, "Only successful delivery clears the draft")
        XCTAssertTrue(view.attachedImages.isEmpty)
        let first = try Data(contentsOf: URL(fileURLWithPath: executable.path + ".first"))
        let second = try Data(contentsOf: URL(fileURLWithPath: executable.path + ".second"))
        func canonical(_ data: Data) throws -> Data {
            try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data), options: .sortedKeys)
        }
        XCTAssertEqual(try canonical(first), try canonical(second), "Session recovery must resend the image, not just the text")
        let expected = try XCTUnwrap(ClaudeChatMessage(text: draft, images: [image]).streamJSONLine())
        XCTAssertEqual(try canonical(first), try canonical(expected))
        let retriedID = try XCTUnwrap(controller.sessionID)
        XCTAssertEqual(ChatTranscriptStore.load(sessionID: retriedID).filter { $0.role == .user }.map(\.text),
                       [draft + "（附 1 张图）"])
    }

    func testNewSessionPersistsFirstQuestionBeforeStartingCLI() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FirstChat-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let suite = "FirstChat.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let executable = directory.appendingPathComponent("fake-claude")
        try """
        #!/bin/sh
        printf '%s\\n' '{"type":"result","result":"test reply","is_error":false}'
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        defaults.set(executable.path, forKey: "claudeChatExecutablePath")
        defaults.set(directory.path, forKey: "claudeChatWorkingDirectory")
        let controller = ClaudeChatController(defaults: defaults)
        defer {
            controller.shutdown()
            if let id = controller.sessionID { ChatTranscriptStore.remove(sessionID: id) }
            defaults.removePersistentDomain(forName: suite)
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Test cleanup failed: \(error)") }
        }
        XCTAssertNil(controller.sessionID)
        let draft = "first message \(UUID())"
        controller.showDraft(draft, anchor: NSRect(x: 500, y: 500, width: 200, height: 200))
        let view = try XCTUnwrap(NSApp.windows.compactMap { $0.contentView as? ClaudeChatView }.first { $0.inputText == draft })
        let input = try XCTUnwrap(view.inputResponder as? ChatInputTextView)
        input.onSend?()
        let id = try XCTUnwrap(controller.sessionID)
        XCTAssertEqual(ChatTranscriptStore.load(sessionID: id).map(\.text), [draft])
        for _ in 0..<160 {
            if view.inputText.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(view.inputText.isEmpty)
        XCTAssertEqual(ChatTranscriptStore.load(sessionID: id).filter { $0.role == .user }.map(\.text), [draft])
    }

    func testSwitchingSessionCancelsPendingReplyWithoutChangingNewHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SwitchChat-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let suite = "SwitchChat.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let old = UUID()
        let new = UUID()
        let executable = directory.appendingPathComponent("fake-claude")
        try """
        #!/bin/sh
        printf started > "$0.started"
        exec /bin/sleep 5
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        defaults.set(old.uuidString, forKey: "claudeChatSessionID")
        defaults.set(executable.path, forKey: "claudeChatExecutablePath")
        defaults.set(directory.path, forKey: "claudeChatWorkingDirectory")
        let saved = ChatMessage(role: .assistant, text: "new session history")
        ChatTranscriptStore.append(saved, sessionID: new)
        let controller = ClaudeChatController(defaults: defaults)
        defer {
            controller.shutdown()
            ChatTranscriptStore.remove(sessionID: old)
            ChatTranscriptStore.remove(sessionID: new)
            defaults.removePersistentDomain(forName: suite)
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Test cleanup failed: \(error)") }
        }
        let draft = "session switch \(UUID())"
        controller.showDraft(draft, anchor: NSRect(x: 500, y: 500, width: 200, height: 200))
        let view = try XCTUnwrap(NSApp.windows.compactMap { $0.contentView as? ClaudeChatView }.first { $0.inputText == draft })
        let input = try XCTUnwrap(view.inputResponder as? ChatInputTextView)
        input.onSend?()
        let marker = executable.path + ".started"
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: marker) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker))
        controller.switchSession(to: new)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(controller.sessionID, new)
        XCTAssertEqual(ChatTranscriptStore.load(sessionID: new), [saved])
        XCTAssertEqual(view.inputText, draft)
        XCTAssertTrue(input.isEditable)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
