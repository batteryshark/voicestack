import XCTest
import UIKit
import CallKit

/// Pure configuration/image unit test. Never launches the target app or creates CXProvider.
@MainActor final class CallKitPresentationUnitTests: XCTestCase {
    func testTemplateIconConfigurationAt2xAnd3x() throws {
        for scale in [CGFloat(2), CGFloat(3)] {
            let config = VoicestackCallKitPresentation.configuration(scale: scale)
            XCTAssertEqual(config.localizedName, "Voicestack")
            let data = try XCTUnwrap(config.iconTemplateImageData)
            XCTAssertFalse(data.isEmpty)
            let image = try XCTUnwrap(UIImage(data: data, scale: scale))
            XCTAssertEqual(image.size.width, 40); XCTAssertEqual(image.size.height, 40)
            XCTAssertEqual(image.scale, scale)
            let cg = try XCTUnwrap(image.cgImage)
            XCTAssertEqual(cg.width, Int(40 * scale)); XCTAssertEqual(cg.height, Int(40 * scale))
            var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            try pixels.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: cg.width, height: cg.height,
                    bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            }
            var clear = 0, marked = 0, maxColorError = 0
            for i in stride(from: 0, to: pixels.count, by: 4) {
                let alpha = pixels[i + 3]
                if alpha == 0 { clear += 1 }
                else {
                    marked += 1
                    for c in 0..<3 { maxColorError = max(maxColorError, abs(Int(pixels[i + c]) - Int(alpha))) }
                }
            }
            XCTAssertGreaterThan(clear, 0); XCTAssertGreaterThan(marked, 0)
            XCTAssertLessThanOrEqual(maxColorError, 1, "White premultiplied alpha mask")
        }
    }
}

// BEGIN IncomingBannerQuery (Foundation-only; exercised by captured-AX offline fixture).
enum IncomingBannerQuery {
    static let rejectID = "rejectCall"
    static let acceptID = "acceptCall"
    static func normalizedCaller(_ value: String) -> String {
        let bidi: Set<UInt32> = [0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]
        return value.unicodeScalars.filter { !bidi.contains($0.value) }.map(String.init).joined()
    }
    static func matches(buttons: [String: String], callers: [String], expectedCaller: String) -> Bool {
        buttons[rejectID] == "End" && buttons[acceptID] == "Accept" &&
            callers.contains { normalizedCaller($0) == normalizedCaller(expectedCaller) }
    }
}
// END IncomingBannerQuery

#if targetEnvironment(simulator)

/// Runs only after the controller stages an isolated session/identity and owned fixture.
/// No helper start, level/caption assignment, fake ASR or prepared prompt is used here.
final class VoiceLoopUITests: XCTestCase {
    private func messageField(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["voice.message"]
        return field.exists ? field : app.textViews["voice.message"]
    }
    private func expectKeyboardDownAndControls(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let down = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.keyboards.count == 0 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [down], timeout: 4), .completed, file: file, line: line)
        XCTAssertEqual(app.keyboards.count, 0, file: file, line: line)
        XCTAssertTrue(app.buttons["voice.startStop"].isHittable, file: file, line: line)
        XCTAssertTrue(app.buttons["voice.micMute"].isHittable, file: file, line: line)
    }
    func testKeyboardSendDismissesAndMultilineReturnStaysUnsent() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-FVPolish", "keyboard"]; app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["voice.startStop"].waitForExistence(timeout: 10))
        for multiline in [false, true] {
            let text = multiline ? "Synthetic first line.\nSynthetic second line." : "Synthetic button delivery."
            let field = messageField(app); field.tap()
            if multiline {
                field.typeText("Synthetic first line.\n")
                XCTAssertEqual(app.keyboards.count, 1, "Multiline Return must not send or dismiss")
                XCTAssertEqual(field.value as? String, "Synthetic first line.\n")
                XCTAssertEqual(app.otherElements["voice.userCaption"].label, "Synthetic button delivery.", "Return must not post another turn")
                field.typeText("Synthetic second line.")
            } else { field.typeText(text) }
            XCTAssertEqual(app.keyboards.count, 1)
            app.buttons["voice.sendTyped"].tap()
            expectKeyboardDownAndControls(app)
            let sent = app.otherElements["voice.userCaption"]
            XCTAssertTrue(sent.waitForExistence(timeout: 5)); XCTAssertEqual(sent.label, text)
            XCTAssertFalse(app.staticTexts["Not confirmed sent"].exists)
            XCTAssertTrue((messageField(app).value as? String ?? "").isEmpty || messageField(app).value as? String == "Message")
        }
    }
    func testKeyboardSwipeOutsideRoundControlsAndSheetsDismiss() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-FVPolish", "keyboard"]; app.launch()
        XCTAssertTrue(app.buttons["voice.startStop"].waitForExistence(timeout: 10))
        for action in ["swipe", "outside", "voice.micMute", "voice.outputMute", "voice.speaker", "History", "Settings"] {
            let field = messageField(app); field.tap(); field.typeText(" draft")
            XCTAssertEqual(app.keyboards.count, 1)
            switch action {
            case "swipe":
                app.scrollViews["voice.conversationLog"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)))
            case "outside": app.staticTexts["voice.state"].tap()
            default:
                let button = app.buttons[action]; XCTAssertTrue(button.isHittable)
                let before = button.value as? String
                button.tap()
                if action == "voice.micMute" || action == "voice.outputMute" { XCTAssertNotEqual(button.value as? String, before) }
                if ["voice.speaker", "History", "Settings"].contains(action) {
                    let down = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.keyboards.count == 0 }, object: nil)
                    XCTAssertEqual(XCTWaiter.wait(for: [down], timeout: 4), .completed)
                    let done = app.buttons["Done"]; XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap()
                }
            }
            expectKeyboardDownAndControls(app)
            XCTAssertTrue((messageField(app).value as? String ?? "").contains("draft"), "Dismissal must not send or clear the draft")
        }
        app.terminate()
        // History has no chat composer; its embedded Canvas note is the native
        // text input. Exercise interactive dismissal without submitting a form.
        defer { app.terminate() }
        for mode in ["canvas-history-html", "canvas-main-html"] {
            app.launchArguments = ["-FVPolish", mode]; app.launch()
            let history = mode.contains("history")
            let scroll = app.scrollViews[history ? "history.conversation" : "voice.conversationLog"]
            let note = app.textFields["Optional note"]
            XCTAssertTrue(note.waitForExistence(timeout: 20))
            if !note.isHittable { scroll.swipeUp() }
            note.tap(); note.typeText("Keyboard-only synthetic note")
            XCTAssertEqual(app.keyboards.count, 1, "An embedded input tap must retain focus")
            XCTAssertEqual(note.value as? String, "Keyboard-only synthetic note")
            if history {
                // Start in the native gutter, not the HTML web view, and finish
                // the interactive drag past the keyboard's top edge.
                scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.2))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.92)))
                let down = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.keyboards.count == 0 }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [down], timeout: 4), .completed)
                XCTAssertEqual(app.keyboards.count, 0); XCTAssertTrue(app.buttons["Done"].isHittable)
            } else {
                app.buttons["voice.micMute"].tap()
                expectKeyboardDownAndControls(app)
            }
            XCTAssertEqual(note.value as? String, "Keyboard-only synthetic note", "Dismissal must preserve form input")
            app.terminate()
        }
    }
    func testVoiceEndedIsQuietSystemNoteInHistoryAndMain() throws {
        for mode in ["sender-ended-history", "sender-ended-main"] {
            let app = XCUIApplication(); app.launchArguments = ["-FVPolish", mode]; app.launch()
            if mode.hasSuffix("history") {
                let role = app.staticTexts["history.role.voice_ended_note"]
                XCTAssertTrue(role.waitForExistence(timeout: 10)); XCTAssertEqual(role.label, "From Voicestack")
                XCTAssertTrue(app.staticTexts["history.systemNote.voice_ended_note"].exists)
            } else {
                let note = app.staticTexts["voice.systemNote.voice_ended_note"]
                XCTAssertTrue(note.waitForExistence(timeout: 10)); XCTAssertTrue(note.label.contains("Voice ended"))
                XCTAssertFalse(app.staticTexts["voice.sender.voice_ended_note"].exists)
            }
            app.terminate()
        }
    }
    func testMixedSenderMainAndHistoryPresentation() throws {
        continueAfterFailure = false
        for mode in ["sender-main", "sender-history"] {
            let app = XCUIApplication(); app.launchArguments = ["-FVPolish", mode]; app.launch()
            let isMain = mode == "sender-main"
            let prefix = isMain ? "voice.sender." : "history.role."
            let labels = [("sender_you", "You"), ("sender_agent", "Agent"),
                          ("sender_lead", "From Lead · Voicestack iPhone"), ("sender_docket", "From Docket"),
                          ("sender_canvas", "From Agent Canvas"), ("sender_unknown", "From Message")]
            let scroll = isMain ? app.scrollViews["voice.conversationLog"] : app.scrollViews.firstMatch
            XCTAssertTrue(scroll.waitForExistence(timeout: 10))
            for (id, label) in labels {
                let header = app.staticTexts[prefix + id]
                // Main uses an eager stack; History may lazily instantiate rows.
                for _ in 0..<6 { if header.exists && header.isHittable { break }; scroll.swipeDown() }
                for _ in 0..<6 { if header.exists && header.isHittable { break }; scroll.swipeUp() }
                XCTAssertTrue(header.exists); XCTAssertEqual(header.label, label)
            }
            for _ in 0..<5 { scroll.swipeDown() }
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = mode + "-mixed-thread"; shot.lifetime = .keepAlways; add(shot)
            app.terminate()
        }
    }
    func testDiscardPendingCountdownAndNoFakeBridgePrompt() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-FVPolish", "discard-countdown"]; app.launch()
        let discard = app.buttons["voice.discard"]
        XCTAssertTrue(discard.waitForExistence(timeout: 10)); XCTAssertTrue(discard.isHittable)
        XCTAssertEqual(discard.label, "Discard and start over")
        let before = XCTAttachment(screenshot: app.screenshot()); before.name = "discard-pending"; before.lifetime = .keepAlways; add(before)
        discard.tap()
        let confirmation = app.staticTexts["voice.discardConfirmation"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 2)); XCTAssertEqual(confirmation.label, "Discarded")
        let after = XCTAttachment(screenshot: app.screenshot()); after.name = "discard-confirmation"; after.lifetime = .keepAlways; add(after)
        XCTAssertFalse(discard.exists)
        Thread.sleep(forTimeInterval: 7) // Past the original send timer and the retired recognizer's final.
        XCTAssertFalse(confirmation.exists)
        XCTAssertEqual(app.staticTexts["discard.fixture.posts"].label, "Prompts: 0")
        XCTAssertTrue(app.buttons["voice.startStop"].exists)
        app.terminate()
    }
    func testDiscardBeforeFirstPartialAndHiddenWhenIdle() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-FVPolish", "discard-recording"]; app.launch()
        let discard = app.buttons["voice.discard"]
        XCTAssertTrue(discard.waitForExistence(timeout: 10))
        discard.tap()
        XCTAssertTrue(app.staticTexts["voice.discardConfirmation"].waitForExistence(timeout: 2))
        XCTAssertFalse(discard.exists)
        app.terminate()
        app.launchArguments = ["-FVPolish", "discard-idle"]; app.launch()
        XCTAssertTrue(app.staticTexts["discard.fixture.posts"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["voice.discard"].exists)
        XCTAssertFalse(app.staticTexts["voice.discardConfirmation"].exists)
        app.terminate()
    }
    func testDiscardIsGoneAfterPromptDispatch() throws {
        let app = XCUIApplication(); app.launchArguments = ["-FVPolish", "discard-posted"]; app.launch()
        let count = app.staticTexts["discard.fixture.posts"]
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        let sent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Prompts: 1'"), object: count)
        XCTAssertEqual(XCTWaiter.wait(for: [sent], timeout: 10), .completed)
        XCTAssertFalse(app.buttons["voice.discard"].exists)
        XCTAssertFalse(app.staticTexts["voice.discardConfirmation"].exists)
        app.terminate()
    }
    func testSpeechServiceUnavailableAndWarmingPresentation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-FVPolish", "speech-unavailable"]; app.launch()
        let error = app.staticTexts["voice.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertEqual(error.label, "Speech service at 127.0.0.1:8446 isn't running")
        XCTAssertFalse(app.staticTexts["voice.warming"].exists)
        app.terminate()
        app.launchArguments = ["-FVPolish", "speech-warming"]; app.launch()
        let warming = app.staticTexts["voice.warming"]
        XCTAssertTrue(warming.waitForExistence(timeout: 10))
        XCTAssertEqual(warming.label, "Warming up speech…")
        XCTAssertFalse(app.staticTexts["voice.error"].exists)
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "speech-warming"; image.lifetime = .keepAlways; add(image)
        app.terminate()
    }
    func testProbeFailureRemainsVisibleAfterStartupErrorClears() throws {
        try probeFailure("probe-stopped")
    }
    func testProbeFailureRemainsVisibleInPresentedHistory() throws {
        try probeFailure("history-probe-stopped")
    }
    private func probeFailure(_ mode: String) throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-FVPolish", mode]; app.launch()
        let error = app.staticTexts["canvas.probe.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertEqual(error.label, "Canvas check stopped (preparation). No input was sent.")
        XCTAssertEqual(app.navigationBars["History"].exists, mode.hasPrefix("history"))
        app.terminate()
    }
    func testCanvasOpenUIHistoryRoundTrip() throws { try canvasFixture("canvas-history-openui") }
    func testCanvasHTMLHistoryRoundTrip() throws { try canvasFixture("canvas-history-html") }
    func testCanvasOpenUIMainRoundTrip() throws { try canvasFixture("canvas-main-openui") }
    func testCanvasHTMLMainRoundTrip() throws { try canvasFixture("canvas-main-html") }
    /// Separate run with the loopback fixture's FV_CANVAS_FIXTURE_PENDING_FOREVER=1.
    func testCanvasPendingBudgetEndsUnknown() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-FVPolish", "canvas-history-html"]; app.launch()
        let rows = app.descendants(matching: .any).matching(identifier: "history.message.msg_html")
        let row = rows.element
        XCTAssertTrue(row.waitForExistence(timeout: 20)); XCTAssertEqual(rows.count, 1)
        let web = row.webViews.matching(identifier: "canvas.show.msg_html").element
        XCTAssertTrue(web.waitForExistence(timeout: 20))
        let choice = web.buttons["Review first"]
        XCTAssertTrue(choice.waitForExistence(timeout: 20))
        if !choice.isHittable { row.swipeUp() }
        XCTAssertTrue(choice.isHittable); choice.tap() // One SYNTHETIC submit, never retry.
        let sending = row.staticTexts["Sending your input…"]
        XCTAssertTrue(sending.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 4)
        XCTAssertTrue(sending.exists, "Missing proof must not end polling on the first response")
        XCTAssertTrue(row.staticTexts["Delivery unknown · check History; not retried"].waitForExistence(timeout: 45))
        XCTAssertFalse(sending.exists); XCTAssertFalse(row.staticTexts["Input sent"].exists)
        XCTAssertFalse(row.buttons["Retry confirmed unsent input"].exists)
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "canvas-pending-budget-unknown"; image.lifetime = .keepAlways; add(image)
        app.terminate()
    }
    private func canvasFixture(_ mode: String) throws {
        let app = XCUIApplication(); app.launchArguments = ["-FVPolish", mode]; app.launch()
        let format = mode.hasSuffix("html") ? "html" : "openui"
        let revision = app.staticTexts["canvas.revision.msg_" + format]
        XCTAssertTrue(revision.waitForExistence(timeout: 30))
        XCTAssertEqual(revision.value as? String, (format == "html" ? "22222222-2222-4222-8222-222222222222" : "11111111-1111-4111-8111-111111111111") + ":1")
        let web = app.webViews.matching(identifier: "canvas.show.msg_" + format).firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 30))
        let choice = web.buttons["Review first"].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 30), app.debugDescription)
        if !choice.isHittable { app.swipeUp() }
        XCTAssertTrue(choice.isHittable)
        let before = XCTAttachment(screenshot: app.screenshot()); before.name = mode; before.lifetime = .keepAlways; add(before)
        choice.tap()
        XCTAssertTrue(app.staticTexts["Input sent"].waitForExistence(timeout: 15), app.debugDescription)
        let after = XCTAttachment(screenshot: app.screenshot()); after.name = mode + "-delivered"; after.lifetime = .keepAlways; add(after)
        app.terminate()
    }
    func testOldToolHistoryAnchorIsVisibleHighlightedAndStableAcrossLatestLayoutRace() throws {
        let app = XCUIApplication(); app.launchArguments = ["-FVPolish","history-target-race"]; app.launch()
        let row = app.descendants(matching:.any).matching(identifier:"history.message.fixture_36").firstMatch
        let marker = app.staticTexts["history.notificationTarget.fixture_36"]
        XCTAssertTrue(marker.waitForExistence(timeout:15)); XCTAssertTrue(marker.isHittable)
        XCTAssertTrue(row.isHittable); XCTAssertTrue((row.value as? String)?.contains("highlighted") == true)
        Thread.sleep(forTimeInterval:2)
        XCTAssertTrue(marker.isHittable); XCTAssertTrue(app.staticTexts["history.work.fixture_36"].exists)
        let image = XCTAttachment(screenshot:app.screenshot()); image.name="history-old-tool-highlight"; image.lifetime = .keepAlways; add(image)
        app.swipeUp()
        XCTAssertFalse(marker.exists, "Principal scrolling releases the pin/highlight")
    }
    func testEmptyHistoryTargetResolvesToNearestVisibleHighlightedNeighbour() throws {
        let app = XCUIApplication(); app.launchArguments = ["-FVPolish","history-target-empty"]; app.launch()
        // Equal-distance tie chooses the preceding collapsed tool row, not latest.
        let marker = app.staticTexts["history.notificationTarget.fixture_36"]
        XCTAssertTrue(marker.waitForExistence(timeout:15)); XCTAssertTrue(marker.isHittable)
        XCTAssertFalse(app.descendants(matching:.any).matching(identifier:"history.message.fixture_37").firstMatch.exists)
        let image = XCTAttachment(screenshot:app.screenshot()); image.name="history-empty-neighbour-highlight"; image.lifetime = .keepAlways; add(image)
    }
    func testNotificationFailurePresentation() throws {
        let app = XCUIApplication(); app.launchArguments = ["-FVPolish", "notification-error"]; app.launch()
        XCTAssertTrue(app.staticTexts["voice.error"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["voice.error"].label, "Couldn't open that message. Check History or try again.")
        XCTAssertFalse(app.staticTexts["Connection lost"].exists)
        polishScreenshot("notification-error")
        app.terminate()
    }
    func testMergedVoiceTurnControlsAndName() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        for mode in ["countdown-two", "chief-speaker", "chief-phone"] {
            app.terminate(); app.launchArguments = ["-FVPolish", mode]; app.launch()
            XCTAssertTrue(app.staticTexts["voice.build"].waitForExistence(timeout: 10))
            if mode == "countdown-two" {
                XCTAssertEqual(app.buttons["voice.sendCountdown"].label, "Sending in 2")
            } else {
                let name = "Agent"
                XCTAssertEqual(app.staticTexts["voice.state"].label, name + " speaking")
                XCTAssertEqual(app.staticTexts["voice.assistantWaveformLabel"].label, name)
                XCTAssertEqual(app.buttons["voice.bargeIn"].exists, mode != "chief-phone")
                XCTAssertFalse(app.staticTexts["Not listening"].exists)
                if mode == "chief-phone" { XCTAssertTrue(app.buttons["voice.speaker"].label.contains("Phone")) }
            }
            polishScreenshot(mode)
        }
        app.terminate()
    }
    func polishScreenshot(_ name: String) {
        let image = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertNoThrow(try image.pngRepresentation.write(to: URL.documentsDirectory.appendingPathComponent(name + ".png")))
    }
    func testPolishConversationLog() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        for mode in ["log-several-turns", "log-live-user", "log-live-user-grown", "log-scrolled"] {
            app.terminate(); app.launchArguments = ["-FVPolish", mode]; app.launch()
            let log = app.scrollViews["voice.conversationLog"]
            XCTAssertTrue(log.waitForExistence(timeout: 10))
            XCTAssertGreaterThan(log.frame.height, app.frame.height * 0.45, "The conversation log is the main content")
            XCTAssertFalse(app.staticTexts["voice.callstate"].exists)
            XCTAssertFalse(app.staticTexts["voice.route"].exists)
            if mode.hasPrefix("log-live-user") {
                let words = app.descendants(matching: .any).matching(identifier: "voice.userCaption").firstMatch
                XCTAssertTrue(words.waitForExistence(timeout: 5))
                XCTAssertEqual(words.label, mode == "log-live-user" ? "Let's review it after" : "Let's review it after lunch, once the build is ready.")
            }
            polishScreenshot(mode)
            if mode == "log-scrolled" {
                log.swipeDown(); log.swipeDown()
                let jump = app.buttons["voice.jumpLatest"]
                XCTAssertTrue(jump.waitForExistence(timeout: 5))
                polishScreenshot("log-scrolled-up")
                jump.tap()
                XCTAssertFalse(jump.exists)
                polishScreenshot("log-jump-latest")
            }
        }
        app.terminate()
    }
    func testPolishReplyCaptions() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let first = "The update is ready for you to review."
        let full = first + " Nothing will install until you confirm it."
        for mode in ["main-speaker", "caption-mid", "caption-finished", "caption-muted", "caption-next-turn"] {
            app.terminate(); app.launchArguments = ["-FVPolish", mode]; app.launch()
            XCTAssertTrue(app.staticTexts["voice.build"].waitForExistence(timeout: 10))
            let caption = app.descendants(matching: .any).matching(identifier: "voice.chiefCaption").firstMatch
            if mode == "main-speaker" {
                XCTAssertTrue(caption.waitForExistence(timeout: 5))
                XCTAssertTrue(caption.label.hasPrefix("Ready when you are\n\nThe iPhone update"))
                XCTAssertTrue(app.scrollViews["voice.conversationLog"].frame.contains(caption.frame))
            } else if mode == "caption-next-turn" {
                let user = app.descendants(matching: .any).matching(identifier: "voice.userCaption").firstMatch
                XCTAssertTrue(user.waitForExistence(timeout: 5))
                XCTAssertEqual(user.label, "Let's try it after lunch.")
                app.scrollViews["voice.conversationLog"].swipeDown()
                XCTAssertTrue(caption.waitForExistence(timeout: 5), "A new principal turn must retain the preceding chief turn")
                XCTAssertEqual(caption.label, full)
                if app.buttons["voice.jumpLatest"].exists { app.buttons["voice.jumpLatest"].tap() }
            } else {
                XCTAssertTrue(caption.waitForExistence(timeout: 5))
                XCTAssertEqual(caption.label, mode == "caption-mid" ? first : full)
                XCTAssertFalse(caption.label.contains("Before you try it"))
                XCTAssertTrue(app.staticTexts["Before you try it"].exists)
                let log = app.scrollViews["voice.conversationLog"]
                XCTAssertTrue(log.frame.contains(caption.frame), "The complete spoken reply must be in the log viewport")
                let heading = app.staticTexts["Before you try it"]
                XCTAssertTrue(log.frame.contains(heading.frame), "The detail heading must not be clipped")
            }
            polishScreenshot(mode)
            if mode == "caption-finished" {
                XCTAssertTrue(caption.isHittable, "The spoken reply remains readable above its detail")
                app.scrollViews.firstMatch.swipeUp()
                let detail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'install when you are ready'")).firstMatch
                XCTAssertTrue(detail.isHittable, "The full secondary reply must remain scrollable")
                XCTAssertTrue(app.scrollViews["voice.conversationLog"].frame.contains(detail.frame))
                let scrolled = XCTAttachment(screenshot: app.screenshot()); scrolled.name = "caption-finished-scrolled"; scrolled.lifetime = .keepAlways; add(scrolled)
            }
        }
        app.terminate()
    }
    override func tearDownWithError() throws {
        // Real scene suspension flushes render evidence even on an assertion failure.
        XCUIDevice.shared.press(.home)
        try super.tearDownWithError()
    }
    func testOwnedRecordedConversation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "Owned app microphone permission") { alert in
            if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap(); return true }
            return false
        }
        app.launchArguments = ["-FVSimulatorProof"]
        app.launch()
        let start = app.buttons["voice.startStop"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: start)
        waitForExpectations(timeout: 15)
        // The proof launch must fail closed rather than falling back to the chief.
        XCTAssertTrue(app.staticTexts["voice.target"].label.contains("Simulator proof"))
        start.tap()
        app.tap() // Let XCTest handle the real microphone permission alert if presented.
        XCTAssertTrue(app.otherElements["voice.inputWaveform"].exists)
        XCTAssertTrue(app.otherElements["voice.outputWaveform"].exists)
        let state = app.staticTexts["voice.state"]
        // Genuine zero lead-in must be ready before any speech/onset is admitted.
        expectation(for: NSPredicate(format: "label == 'Listening'"), evaluatedWith: state)
        waitForExpectations(timeout: 4)
        expectation(for: NSPredicate(format: "label == 'Listening'"), evaluatedWith: state)
        waitForExpectations(timeout: 15)
        let user = app.descendants(matching: .any).matching(identifier: "voice.userCaption").firstMatch
        let chief = app.descendants(matching: .any).matching(identifier: "voice.chiefCaption").firstMatch
        let words = NSPredicate(format: "label CONTAINS[c] 'lighthouse' OR label CONTAINS[c] 'frozen'")
        expectation(for: NSPredicate(format: "label BEGINSWITH[c] 'Please' AND label.length < 65"), evaluatedWith: user)
        waitForExpectations(timeout: 45)
        expectation(for: words, evaluatedWith: chief)
        waitForExpectations(timeout: 75)
        expectation(for: NSPredicate(format: "label == 'Agent speaking'"), evaluatedWith: state)
        waitForExpectations(timeout: 25)
        expectation(for: NSPredicate(format: "label == 'Listening'"), evaluatedWith: state)
        waitForExpectations(timeout: 20)
        app.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == 'You'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == 'Agent'")).firstMatch.exists)
        let newRows = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'frozen lake'"))
        expectation(for: NSPredicate { _, _ in newRows.allElementsBoundByIndex.filter(\.isHittable).count >= 2 }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        let history = XCTAttachment(screenshot: app.screenshot()); history.lifetime = .keepAlways; add(history)
        // Source records and real rendered sound are checked in the external trace as well;
        // these UI checks alone cannot accept a proof.
        app.buttons["Done"].tap()
        start.tap() // flush actual mixer PCM/trace while the owned app is still alive.
    }
}
#else
private final class RouteCallCleanupEvidence {
    var startAttempted = false
    var endTapAttempted = false
    var endConfirmed = false
    var terminationRequested = false
    var forcedTermination = false
    var processStopped = false
    var elapsed: TimeInterval?
    var began: Date?
    var snapshots: [String] = []
    var events: [String] = []
}

/// Fenced app-started REAL CallKit route test. No push, typed input or settings edits.
final class DeviceRouteUITests: XCTestCase {
    private func registerCallCleanup(_ app: XCUIApplication, _ evidence: RouteCallCleanupEvidence) {
        // XCTest executes these independently in LIFO order, even when a failed
        // assertion aborts the test via an exception. Swift defer is NOT sufficient.
        addTeardownBlock {
            self.continueAfterFailure = true
            let row: [String: Any] = ["build": 29, "attempt": 3, "startAttempted": evidence.startAttempted,
                "endTapAttempted": evidence.endTapAttempted, "endConfirmed": evidence.endConfirmed,
                "terminationRequested": evidence.terminationRequested, "forcedTermination": evidence.forcedTermination,
                "processStopped": evidence.processStopped, "elapsedSeconds": evidence.elapsed ?? -1,
                "elapsedAtCleanupSeconds": evidence.began.map { Date().timeIntervalSince($0) } ?? -1,
                "targetSeconds": 10, "events": evidence.events, "routes": evidence.snapshots]
            let bytes = try JSONSerialization.data(withJSONObject: row, options: .sortedKeys)
            let text = String(decoding: bytes, as: UTF8.self)
            print("FV_ROUTE29_CLEANUP " + text); fflush(stdout)
            let attachment = XCTAttachment(string: text)
            attachment.name = "route29-attempt3-cleanup"; attachment.lifetime = .keepAlways; self.add(attachment)
            XCTAssertTrue(!evidence.startAttempted || evidence.processStopped, "Owned app process must not survive cleanup")
        }
        addTeardownBlock {
            self.continueAfterFailure = true
            guard evidence.startAttempted else { evidence.events.append("noOwnedStart"); return }
            // Normal process cleanup also follows confirmed End. Unknown/live
            // calls get forced termination after the independent five-second wait.
            evidence.forcedTermination = !evidence.endConfirmed
            if app.state != .notRunning {
                evidence.terminationRequested = true; evidence.events.append("terminateRequested")
                app.terminate()
            }
            evidence.processStopped = app.state == .notRunning
            evidence.events.append(evidence.processStopped ? "processStopped" : "processStillRunning")
        }
        addTeardownBlock {
            self.continueAfterFailure = true
            guard evidence.startAttempted else { return }
            evidence.events.append("waitForEnd")
            let ended = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                if app.state == .notRunning { return true }
                let call = app.buttons["voice.startStop"]
                return call.exists && call.label == "Start voice"
            }, object: nil)
            evidence.endConfirmed = XCTWaiter.wait(for: [ended], timeout: 5) == .completed
            evidence.events.append(evidence.endConfirmed ? "endObserved" : "endUnconfirmedAfter5s")
        }
        addTeardownBlock {
            self.continueAfterFailure = true
            guard evidence.startAttempted else { return }
            let call = app.buttons["voice.startStop"]
            if call.exists && call.label == "End call" && call.isHittable {
                evidence.endTapAttempted = true; evidence.events.append("tapEnd")
                call.tap()
            } else { evidence.events.append("endNotVisible") }
        }
    }
    func testAppStartedRapidPhoneSpeakerRoutes() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FV_ROUTE29_AUTHORIZED"] == "UNLOCKED-B29-ROUTE-ATTEMPT-3",
            "Lead must install the signed route candidate and explicitly authorize the unlocked-phone run")
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "org.example.voicestack")
        let evidence = RouteCallCleanupEvidence()
        registerCallCleanup(app, evidence) // Registered BEFORE any launch/assertion/Start side effect.
        app.launchArguments = ["-FVRoute28Probe"]; app.launch()
        let call = app.buttons["voice.startStop"], route = app.buttons["voice.speaker"]
        XCTAssertTrue(call.waitForExistence(timeout: 30)); XCTAssertEqual(call.label, "Start voice")
        XCTAssertTrue(app.staticTexts["voice.build"].exists)
        XCTAssertEqual(app.staticTexts["voice.build"].label, "build 29")
        let actual = app.staticTexts["voice.route.actual"]
        XCTAssertTrue(actual.waitForExistence(timeout: 5))
        XCTAssertTrue((actual.value as? String ?? "").contains("schema=route-recovery-2;"), "Require the recovery-capable build29 before Start")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in call.isEnabled }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 40), .completed)
        let began = Date()
        evidence.began = began
        evidence.startAttempted = true // Arm cleanup BEFORE the Start tap, including uncertain tap failures.
        call.tap() // exactly one Start gesture
        let active = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            call.value as? String == "In call"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [active], timeout: 40), .completed)
        func check(_ speaker: Bool, _ name: String) {
            let value = actual.value as? String ?? ""
            evidence.snapshots.append("\(name) elapsed=\(Date().timeIntervalSince(began)) \(value)")
            XCTAssertEqual(route.label, speaker ? "Speaker" : "Speaker, current route Phone")
            XCTAssertTrue(value.contains("outputPort=\(speaker ? 2 : 4);"), value)
            XCTAssertTrue(value.contains("active=1;media=1;"), value)
            XCTAssertTrue(value.contains("captureReady=1"), "Latest capture graph must supply real frames: " + value)
            XCTAssertEqual(call.value as? String, "In call")
            XCTAssertFalse(app.buttons["voice.retryAudio"].exists)
        }
        check(false, "route29-initial-phone")
        for (index, speaker) in [true, false, true, false].enumerated() {
            route.tap(); Thread.sleep(forTimeInterval: 1.5)
            check(speaker, "route29-toggle-\(index + 1)")
        }
        evidence.elapsed = Date().timeIntervalSince(began) // About ten seconds is a target, NOT a hard failure.
        print("FV_ROUTE29_ELAPSED \(evidence.elapsed!) target=10 soft=true"); fflush(stdout)
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "route29-attempt3-still-connected"; image.lifetime = .keepAlways; add(image)
        XCTAssertFalse(app.staticTexts["voice.error"].exists, "Inspect route/network failure before repeating")
        // All call cleanup belongs to the registered teardown blocks, including success.
    }
}

/// No app.launch(), launch flags or debugger: open the actual SpringBoard icon.
final class DeviceHomeUITests: XCTestCase {
    func testCanvas25OwnedThrowawayChoice() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["FV_CANVAS25_AUTHORIZED"] == "UNLOCKED-B25-SUBMIT-THROWAWAY", "Lead must explicitly authorize the one real panel input")
        continueAfterFailure = false // Any failed identity/readiness assertion stops BEFORE the tap.
        historyOnly = true // Cleanup may restore Chief, never start/end a call.
        let app = XCUIApplication(); app.launchArguments = ["-FVCanvas25Probe"]; app.launch()
        let session = "ses_SYNTHETIC0017", message = "msg_SYNTHETIC0003"
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.staticTexts["canvas.probe.ready"].exists || app.staticTexts["canvas.probe.error"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 60), .completed, "Probe readiness/routing timed out. No tap permitted.")
        XCTAssertFalse(app.staticTexts["canvas.probe.error"].exists, app.staticTexts["canvas.probe.error"].label)
        XCTAssertTrue(app.staticTexts["canvas.probe.ready"].exists, "Routing must finish, including viewport confirmation, before input")
        XCTAssertTrue(app.navigationBars["History"].exists)
        XCTAssertTrue(app.staticTexts["history.session." + session].exists)
        // Only History assigns this row identifier. The same message's main-log
        // panel remains mounted behind the sheet and must never be selected.
        let rows = app.descendants(matching: .any).matching(identifier: "history.message." + message)
        XCTAssertEqual(rows.count, 1, "Require the unique History-owned row; never firstMatch globally")
        let historyRow = rows.element
        let revisions = historyRow.staticTexts.matching(identifier: "canvas.revision." + message)
        let revision = revisions.element
        XCTAssertTrue(revision.waitForExistence(timeout: 30))
        XCTAssertEqual(revisions.count, 1)
        XCTAssertEqual(revision.value as? String, "a513aa2d-c796-47e2-a4cf-6dea84ff9e53:1")
        let webs = historyRow.webViews.matching(identifier: "canvas.show." + message)
        let web = webs.element
        XCTAssertTrue(web.waitForExistence(timeout: 10))
        XCTAssertEqual(webs.count, 1, "Require the webview inside the History row")
        let before = XCTAttachment(screenshot: app.screenshot()); before.name = "canvas25-real-before"; before.lifetime = .keepAlways; add(before)
        if let raw = env["FV_CANVAS25_FIELDS"], let fields = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: String] {
            for (label, value) in fields.sorted(by: { $0.key < $1.key }) {
                let field = web.textFields[label].firstMatch
                XCTAssertTrue(field.exists && field.isEnabled); field.tap(); field.typeText(value)
            }
        }
        // The lead supplies the exact visible choice/submit label. Never guess at another control or another session.
        let label = try XCTUnwrap(env["FV_CANVAS25_ACTION_LABEL"]); XCTAssertFalse(label.isEmpty)
        let choices = web.buttons.matching(NSPredicate(format: "label == %@", label))
        let choice = choices.element
        XCTAssertTrue(choice.waitForExistence(timeout: 10)); XCTAssertTrue(choice.isEnabled)
        XCTAssertEqual(choices.count, 1, "Require one exact action inside History's webview")
        if !choice.isHittable { historyRow.swipeUp() }
        XCTAssertTrue(choice.isHittable)
        XCTAssertFalse(app.staticTexts["canvas.probe.error"].exists)
        XCTAssertTrue(app.staticTexts["canvas.probe.ready"].exists)
        choice.tap() // Exactly one submission gesture; no retry, even on unknown delivery.
        let sent = historyRow.staticTexts["Input sent"]
        XCTAssertTrue(sent.waitForExistence(timeout: 40), "Stop and inspect History; do not repeat an unknown submission")
        let after = XCTAttachment(screenshot: app.screenshot()); after.name = "canvas25-real-delivered"; after.lifetime = .keepAlways; add(after)
    }
    private var expectedBuild: String { ProcessInfo.processInfo.environment["FV_M4_BUILD"] ?? "20" }
    let app = XCUIApplication(bundleIdentifier: "org.example.voicestack")
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var locking = false
    private var historyOnly = false
    private func restoreHistoryChief() -> Bool {
        guard app.state == .runningForeground else { return false }
        // This lane must NEVER use shared call cleanup (which can tap End).
        if app.navigationBars["www.apple.com"].exists { app.buttons["Done"].firstMatch.tap() }
        if app.navigationBars["History"].exists { app.buttons["Done"].firstMatch.tap() }
        if !app.navigationBars["Choose session"].exists {
            if !app.navigationBars["Sessions & settings"].exists {
                guard app.buttons["Settings"].exists else { return false }
                app.buttons["Settings"].tap()
            }
            guard app.buttons["settings.session"].waitForExistence(timeout: 5) else { return false }
            app.buttons["settings.session"].tap()
        }
        guard app.buttons["picker.chief"].waitForExistence(timeout: 5) else { return false }
        app.buttons["picker.chief"].tap()
        guard app.navigationBars["Sessions & settings"].waitForExistence(timeout: 5) else { return false }
        app.buttons["Done"].tap()
        return app.buttons["Settings"].waitForExistence(timeout: 5) && !app.staticTexts["voice.target"].exists
    }
    private func restoreChiefIfForeground() -> Bool {
        guard app.state == .runningForeground else { return false }
        if app.navigationBars["History"].exists && app.buttons["Done"].exists { app.buttons["Done"].tap() }
        let call = app.buttons["voice.startStop"]
        if call.exists && ["End call", "Stop voice", "End"].contains(call.label) {
            call.tap()
            guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Start voice'"), object: call)], timeout: 8) == .completed else { return false }
        }
        if !app.navigationBars["Choose session"].exists {
            if !app.navigationBars["Sessions & settings"].exists {
                guard app.buttons["Settings"].exists else { return false }
                app.buttons["Settings"].tap()
            }
            guard app.buttons["settings.session"].waitForExistence(timeout: 5) else { return false }
            app.buttons["settings.session"].tap()
        }
        guard app.buttons["picker.chief"].waitForExistence(timeout: 5) else { return false }
        app.buttons["picker.chief"].tap()
        guard app.navigationBars["Sessions & settings"].waitForExistence(timeout: 5) else { return false }
        app.buttons["Done"].tap()
        return !app.staticTexts["voice.target"].exists
    }
    override func tearDownWithError() throws {
        if historyOnly && app.state == .runningForeground {
            XCTAssertTrue(restoreHistoryChief(), "History-only chief restoration failed; never start/end a call")
        } else if !locking && app.state == .runningForeground {
            XCTAssertTrue(restoreChiefIfForeground(), "Chief cleanup failed; stop, never start a call on chief")
        }
        app.terminate() // also runs after assertions; never leave a probe/call process behind
        try super.tearDownWithError()
    }
    func mark(_ name: String) {
        if name.hasSuffix("-home") { XCTAssertEqual(springboard.state, .runningForeground) }
        else { XCTAssertEqual(app.state, .runningForeground) }
        print("FVHOME_CAPTURE \(name) \(Int(Date().timeIntervalSince1970 * 1000))")
        fflush(stdout)
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
        Thread.sleep(forTimeInterval: 1.5)
    }
    func picker() {
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["settings.build"].waitForExistence(timeout: 5))
        app.buttons["settings.session"].tap()
        XCTAssertTrue(app.navigationBars["Choose session"].waitForExistence(timeout: 5))
    }
    func testHomeScreenTwice() throws {
        continueAfterFailure = false
        let count = ProcessInfo.processInfo.environment["FV_HOME_RUNS"] == "1" ? 1 : 2
        for run in 1...count {
            app.terminate()
            XCUIDevice.shared.press(.home)
            let icon = springboard.icons["Voicestack"].firstMatch
            for _ in 0..<8 {
                if icon.exists && icon.isHittable { break }
                springboard.swipeLeft()
            }
            XCTAssertTrue(icon.exists && icon.isHittable, "Voicestack must have a real SpringBoard icon")
            mark("run\(run)-home")
            icon.tap()
            let build = app.staticTexts["voice.build"]
            XCTAssertTrue(build.waitForExistence(timeout: 10))
            XCTAssertEqual(build.label, "build " + expectedBuild)
            let start = app.buttons["voice.startStop"]
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: start)
            waitForExpectations(timeout: 12)
            mark("run\(run)-main-build" + expectedBuild)
            picker()
            let search = app.searchFields.firstMatch
            search.tap(); search.typeText("ses_SYNTHETIC0017")
            let owned = app.buttons["picker.ses_SYNTHETIC0017"]
            XCTAssertTrue(owned.waitForExistence(timeout: 5)); owned.tap()
            XCTAssertTrue(app.navigationBars["Sessions & settings"].waitForExistence(timeout: 5))
            app.buttons["Done"].tap()
            XCTAssertTrue(app.staticTexts["voice.target"].exists, "The explicitly selected throwaway session must have its own display title")
            mark("run\(run)-owned-selection")
            // Route-control proof stays silent even if real room speech triggers a reply.
            // Full unmuted playback is proved separately through the receiver in C/D.
            let outputMute = app.buttons["voice.outputMute"]
            let outputWasMuted = (outputMute.value as? String) == "on"
            if !outputWasMuted { outputMute.tap() }
            start.tap()
            let state = app.staticTexts["voice.state"]
            expectation(for: NSPredicate(format: "label == 'Listening'"), evaluatedWith: state)
            waitForExpectations(timeout: 8)
            expectation(for: NSPredicate(format: "value == 'In call'"), evaluatedWith: app.buttons["voice.startStop"])
            waitForExpectations(timeout: 3)
            mark("run\(run)-listening")
            Thread.sleep(forTimeInterval: 4.5)
            let mute = app.buttons["voice.micMute"]
            mute.tap()
            expectation(for: NSPredicate(format: "value == 'on'"), evaluatedWith: mute)
            waitForExpectations(timeout: 3)
            mark("run\(run)-muted")
            mute.tap()
            expectation(for: NSPredicate(format: "value == 'off'"), evaluatedWith: mute)
            waitForExpectations(timeout: 3)
            mark("run\(run)-unmuted")
            let route = app.buttons["voice.speaker"]
            if (route.value as? String) != "on" { route.tap() }
            expectation(for: NSPredicate(format: "value == 'on'"), evaluatedWith: route)
            waitForExpectations(timeout: 3)
            app.buttons["voice.speaker"].tap()
            expectation(for: NSPredicate(format: "value == 'off' AND label CONTAINS 'Phone'"), evaluatedWith: route)
            waitForExpectations(timeout: 3)
            mark("run\(run)-receiver")
            app.buttons["voice.speaker"].tap()
            expectation(for: NSPredicate(format: "value == 'on'"), evaluatedWith: route)
            waitForExpectations(timeout: 3)
            mark("run\(run)-speaker")
            start.tap()
            expectation(for: NSPredicate(format: "label == 'Start voice'"), evaluatedWith: start)
            waitForExpectations(timeout: 5)
            mark("run\(run)-stopped")
            if !outputWasMuted { outputMute.tap() }
            picker()
            app.buttons["picker.chief"].tap()
            XCTAssertTrue(app.navigationBars["Sessions & settings"].waitForExistence(timeout: 5))
            app.buttons["Done"].tap()
            XCTAssertFalse(app.staticTexts["voice.target"].exists)
            mark("run\(run)-chief-restored")
            XCUIDevice.shared.press(.home)
            app.terminate()
            print("FVHOME_FINISHED run\(run) \(Int(Date().timeIntervalSince1970 * 1000))")
        }
    }
    func testLockedCallProbe() throws {
        continueAfterFailure = false
        defer { app.terminate() } // never attempt to unlock; D runs last
        app.launchArguments = ["-FVPhoneLoopProbe", "-FVLockedCallProbe"]
        app.launch()
        let call = app.buttons["voice.startStop"]
        expectation(for: NSPredicate(format: "value == 'In call'"), evaluatedWith: call)
        waitForExpectations(timeout: 25)
        XCTAssertEqual(app.staticTexts["voice.build"].label, "build " + expectedBuild)
        XCTAssertTrue(app.staticTexts["voice.target"].exists)
        mark("locked-prelock")
        let selector = NSSelectorFromString("pressLockButton")
        XCTAssertTrue(XCUIDevice.shared.responds(to: selector), "Required runner-only lock selector unavailable")
        print("FVLOCK_REQUEST \(Int(Date().timeIntervalSince1970 * 1000))")
        locking = true // Native probe owns End/chief restoration; never launch or unlock afterward.
        XCUIDevice.shared.perform(selector)
        Thread.sleep(forTimeInterval: 45) // app owns the 30 s timer and CXEndCallAction
        // No screenshot or Home action while locked. File evidence is pulled by the driver.
    }

    // These tests never send pushes. Only the doubly-authorized suite driver reacts to READY.
    func m4Authorization(push: Bool = false) throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["FV_M4_AUTHORIZED"] == "UNLOCKED-B" + expectedBuild, "Run through the authorized candidate suite")
        if push { try XCTSkipUnless(env["FV_M4_PUSH_AUTHORIZED"] == "SANDBOX-B" + expectedBuild, "Real sandbox push authorization required") }
        continueAfterFailure = false
    }
    func m4Home() {
        app.terminate(); XCUIDevice.shared.press(.home)
        let icon = springboard.icons["Voicestack"].firstMatch
        for _ in 0..<8 {
            if icon.exists && icon.isHittable { break }
            springboard.swipeLeft()
        }
        XCTAssertTrue(icon.exists && icon.isHittable)
        icon.tap()
        XCTAssertTrue(app.staticTexts["voice.build"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["voice.build"].label, "build " + expectedBuild)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["voice.startStop"])
        waitForExpectations(timeout: 15)
    }
    var m4Alerts: XCUIElementQuery {
        let name = ProcessInfo.processInfo.environment["FV_M4_ASSISTANT_NAME"] ?? "Agent"
        return springboard.staticTexts.matching(NSPredicate(format: "label == %@", name + " needs a decision"))
    }
    func m4NotificationCenter() {
        XCUIDevice.shared.press(.home)
        let screen = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.01))
        screen.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.8)))
        Thread.sleep(forTimeInterval: 1)
    }
    func m4Ready(_ step: String) {
        // Refuse to clear the principal's notifications or confuse old alerts with this proof.
        m4NotificationCenter()
        XCTAssertEqual(m4Alerts.count, 0, "Existing chief notifications: stop; lead must arrange an isolated notification window")
        XCUIDevice.shared.press(.home)
        print("FVM4_READY \(step)"); fflush(stdout)
    }
    func m4Screenshot(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
    func testD1RealHistoryBuild23() throws {
        // Obsolete after build 23: use device_canvas25.py and its one-choice scoped check.
        try XCTSkipUnless(expectedBuild == "23", "Build-23-only D1 proof; use device_canvas25.py for build 25")
        historyOnly = true
        try m4Authorization()
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(expectedBuild == "23" && env["FV_D1_REAL_HISTORY"] == "OWNED-REAL-NO-CHOICE", "Dedicated gated real-content driver only")
        let session = "ses_SYNTHETIC0017"
        let message = "msg_SYNTHETIC0004"
        let canvasMessage = "msg_SYNTHETIC0003"
        m4Home()
        XCTAssertEqual(app.buttons["voice.startStop"].label, "Start voice", "No active call may be touched by this lane")
        picker()
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText(session)
        let owned = app.buttons["picker." + session]
        XCTAssertTrue(owned.waitForExistence(timeout: 8)); owned.tap()
        XCTAssertTrue(app.navigationBars["Sessions & settings"].waitForExistence(timeout: 8))
        app.buttons["Done"].tap()
        app.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 8))
        let bound = app.staticTexts["history.session." + session]
        XCTAssertTrue(bound.waitForExistence(timeout: 8), "Must bind the real throwaway, never chief")
        let scroll = app.scrollViews.firstMatch
        func row(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: "history.message." + id).firstMatch }
        func text(_ value: String) -> XCUIElement { row(message).staticTexts.matching(NSPredicate(format: "label == %@", value)).firstMatch }
        func visible(_ element: XCUIElement) -> Bool {
            element.exists && element.isHittable && !element.frame.isEmpty && scroll.frame.contains(element.frame)
        }
        func reveal(_ element: XCUIElement, upward: Bool) {
            for _ in 0..<14 {
                if visible(element) { return }
                if upward { scroll.swipeDown() } else { scroll.swipeUp() }
            }
            XCTAssertTrue(visible(element), "Specific real-content element must be inside the History viewport")
        }
        func capture(_ name: String, _ elements: [XCUIElement]) {
            XCTAssertEqual(app.state, .runningForeground)
            XCTAssertTrue(bound.exists)
            for element in elements { XCTAssertTrue(visible(element), "Do not screenshot an off-screen/placeholder element") }
            m4Screenshot(name)
        }
        let heading = text("D1 Real History Proof")
        reveal(heading, upward: true); capture("d1-real-heading", [heading])
        let cells = (1...3).flatMap { number in ["A", "B", "C"].map { text("D1-\($0)\(number)") } }
        reveal(cells.last!, upward: false)
        capture("d1-real-table", [text("A"), text("B"), text("C")] + cells)
        let code = text("let d1HistoryProof = \"real-content\"")
        reveal(code, upward: false); capture("d1-real-swift-code", [code, text("swift")])
        let image = row(message).images["D1 real PNG"].firstMatch
        _ = image.waitForExistence(timeout: 15)
        reveal(image, upward: false)
        XCTAssertGreaterThan(image.frame.width, 32); XCTAssertGreaterThan(image.frame.height, 32)
        capture("d1-real-png", [image])
        let link = row(message).descendants(matching: .any).matching(NSPredicate(format: "label == 'D1 Apple link'")).firstMatch
        reveal(link, upward: true); capture("d1-real-link", [link]); link.tap()
        let webBar = app.navigationBars["www.apple.com"]
        XCTAssertTrue(webBar.waitForExistence(timeout: 12))
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 20)); XCTAssertTrue(web.isHittable)
        let apple = web.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'Apple'")).firstMatch
        XCTAssertTrue(apple.waitForExistence(timeout: 20), "Require real website content, not just a web-view shell")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'This page could not be opened safely'")).firstMatch.exists)
        XCTAssertEqual(app.state, .runningForeground); m4Screenshot("d1-real-in-app-web")
        webBar.buttons["Done"].tap()
        XCTAssertTrue(bound.waitForExistence(timeout: 8))
        let canvasRow = row(canvasMessage)
        let tool = canvasRow.descendants(matching: .any).matching(identifier: "history.work." + canvasMessage + ".1").firstMatch
        reveal(tool, upward: true)
        XCTAssertTrue(tool.label.contains("canvas_show")); XCTAssertFalse(tool.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        // A collapsed tool row only. Do not expand it, open its viewer link or tap a choice.
        XCTAssertFalse(canvasRow.staticTexts["D1 real section"].exists)
        XCTAssertFalse(canvasRow.buttons.matching(NSPredicate(format: "label CONTAINS 'D1 confirm' OR label CONTAINS 'D1 defer'")).firstMatch.exists)
        capture("d1-real-canvas-unsupported-tool", [tool])
        print("FVD1_GAP Canvas (canvas_show) unsupported on build 23: known D1 gap"); fflush(stdout)
        XCTAssertTrue(restoreHistoryChief())
        XCTAssertEqual(app.buttons["voice.startStop"].label, "Start voice")
        m4Screenshot("d1-real-chief-restored")
        print("FVD1_REAL_HISTORY_COMPLETE"); fflush(stdout)
        app.terminate()
    }
    func testM4Enrollment() throws {
        try m4Authorization()
        m4Home(); app.buttons["Settings"].tap()
        let enable = app.buttons["Enable notifications"]
        for _ in 0..<6 {
            if enable.exists && enable.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(enable.exists && enable.isHittable)
        enable.tap()
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        XCTAssertTrue(app.staticTexts["Notifications: Allowed · respects Focus"].waitForExistence(timeout: 10), "Permission denied: stop and ask lead; do not change iOS settings automatically")
        let synced = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH ' · Synced'")).firstMatch
        XCTAssertTrue(synced.waitForExistence(timeout: 20))
        m4Screenshot("m4-enrollment-settings")
        app.buttons["Done"].tap(); XCUIDevice.shared.press(.home)
    }
    func testM4OrdinaryNotificationTap() throws {
        try m4Authorization(push: true)
        let env = ProcessInfo.processInfo.environment
        let session = try XCTUnwrap(env["FV_M4_SESSION"]), message = try XCTUnwrap(env["FV_M4_MESSAGE"])
        XCTAssertFalse(session.isEmpty); XCTAssertFalse(message.isEmpty)
        m4Home(); m4Ready("G")
        let alert = m4Alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 50), "A real banner must be shown, not just APNs accepted")
        m4Screenshot("m4-ordinary-notification")
        alert.tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["history.session." + session].exists)
        let row = app.descendants(matching: .any).matching(identifier: "history.message." + message).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10)); XCTAssertTrue(row.isHittable)
        if expectedBuild == "22" {
            let target = app.staticTexts["history.notificationTarget." + message]
            XCTAssertTrue(target.waitForExistence(timeout:10)); XCTAssertTrue(target.isHittable)
            XCTAssertEqual(target.value as? String,"highlighted")
            XCTAssertTrue((row.value as? String)?.contains("highlighted") == true)
        }
        m4Screenshot("m4-history-message")
        app.buttons["Done"].tap(); XCUIDevice.shared.press(.home)
    }
    func testM4IncomingDeclineAndFallback() throws {
        try m4Authorization(push: true)
        var baselineAlerts = 0
        m4Home()
        if expectedBuild == "23" {
            // Re-verify existing UPDATE enrollment, then terminate so this really
            // exercises cold PushKit startup and later SwiftUI scene creation.
            app.buttons["Settings"].tap()
            let synced = app.staticTexts.matching(NSPredicate(format:"label ENDSWITH ' · Synced'")).firstMatch
            for _ in 0..<6 { if synced.exists && synced.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(synced.waitForExistence(timeout:20)); app.buttons["Done"].tap()
            app.terminate(); m4NotificationCenter(); baselineAlerts = m4Alerts.count
            XCUIDevice.shared.press(.home)
            print("FVM4_READY H"); fflush(stdout)
        } else { m4Ready("H") }
        let calls = XCUIApplication(bundleIdentifier: "com.apple.InCallService")
        let name = ProcessInfo.processInfo.environment["FV_M4_ASSISTANT_NAME"] ?? "Agent"
        func visibleDecline() -> XCUIElement? {
            // The captured AX main window contains BOTH real banner controls.
            // Never query the hidden/scaled full-screen "Decline" subtree or
            // substitute a SpringBoard control. Accept is a readiness check ONLY.
            for window in calls.windows.allElementsBoundByIndex where window.exists && !window.frame.isEmpty {
                let decline = window.buttons[IncomingBannerQuery.rejectID].firstMatch
                let accept = window.buttons[IncomingBannerQuery.acceptID].firstMatch
                guard decline.exists, decline.isHittable, accept.exists, accept.isHittable else { continue }
                let identities = window.staticTexts.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }.map(\.label)
                guard IncomingBannerQuery.matches(buttons: [decline.identifier: decline.label, accept.identifier: accept.label], callers: identities, expectedCaller: name) else { continue }
                return decline
            }
            return nil
        }
        let deadline = Date().addingTimeInterval(expectedBuild == "23" ? 12 : 20)
        var readyDecline: XCUIElement?
        while Date() < deadline {
            readyDecline = visibleDecline()
            if readyDecline != nil { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        let hierarchy = XCTAttachment(string: "InCallService:\n" + calls.debugDescription + "\nSpringBoard:\n" + springboard.debugDescription)
        hierarchy.name = "m4-incoming-call-ax-before-assert"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        m4Screenshot("m4-incoming-call")
        XCTAssertNotNil(readyDecline, "Visible/hittable InCallService banner caller, rejectCall and acceptCall must be ready together")
        guard let decline = readyDecline else { return }
        XCTAssertTrue(decline.isHittable, "Call ended while evidence was captured; never substitute another control")
        if expectedBuild == "23" {
            let began = Date()
            print("FVB23_RING_BEGIN \(Int(began.timeIntervalSince1970*1000))"); fflush(stdout)
            m4Screenshot("b23-ringing-start")
            var middle = false
            while Date().timeIntervalSince(began) < 10 {
                XCTAssertNotNil(visibleDecline(), "Call stopped ringing before10seconds")
                if !middle && Date().timeIntervalSince(began) >= 5 { m4Screenshot("b23-ringing-five-seconds"); middle = true }
                Thread.sleep(forTimeInterval:0.2)
            }
            m4Screenshot("b23-ringing-ten-seconds")
            let stillRinging = visibleDecline()
            XCTAssertNotNil(stillRinging)
            print("FVB23_RING_END \(Int(Date().timeIntervalSince1970*1000))"); fflush(stdout)
            stillRinging?.tap() // The sole action on this real chief invitation; NEVER Answer.
        } else { decline.tap() } // Exactly one decline, after evidence and identity validation.
        XCTAssertTrue(m4Alerts.firstMatch.waitForExistence(timeout: 50))
        m4NotificationCenter()
        XCTAssertEqual(m4Alerts.count, baselineAlerts + 1, "Exactly one additional visible fallback required; never clear old notifications")
        m4Screenshot("m4-fallback-one")
        Thread.sleep(forTimeInterval: 60) // Observe beyond the sender's 45-second fallback deadline.
        XCTAssertEqual(m4Alerts.count, baselineAlerts + 1)
        XCTAssertNil(visibleDecline(), "An unanswered decision must not ring again")
        m4Screenshot("m4-fallback-still-one")
        // Do not open/clear the fallback or answer a real call automatically.
        XCUIDevice.shared.press(.home)
    }
    func testSpeakerEchoProbe() throws {
        try m4Authorization()
        app.launchArguments = ["-FVSpeakerEchoProbe"]
        app.launch()
        XCTAssertTrue(app.staticTexts["voice.build"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["voice.build"].label, "build " + expectedBuild)
        expectation(for: NSPredicate(format: "value == 'In call'"), evaluatedWith: app.buttons["voice.startStop"])
        waitForExpectations(timeout: 25)
        // The app owns the bounded measurement and End, never a prepared ASR transcript.
        Thread.sleep(forTimeInterval: 25)
        XCTAssertEqual(app.buttons["voice.startStop"].label, "Start voice")
        XCTAssertFalse(app.staticTexts["voice.target"].exists)
        m4Screenshot("speaker-echo-complete")
        XCUIDevice.shared.press(.home)
    }
}
/// Same signed device/SpringBoard runner as the build-19 suite. Each case owns
/// selection/start/end/restoration; the host driver owns fixtures and evidence.
final class DeviceVoiceTurnUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "org.example.voicestack")
    private var needsCleanup = false

    private func marker(_ step: String, _ phase: String) {
        print("FVVOICE_UI \(step) \(phase) \(Int(Date().timeIntervalSince1970 * 1000))")
        fflush(stdout)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "\(step)-\(phase)"; shot.lifetime = .keepAlways; add(shot)
    }

    private func picker() {
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["settings.build"].waitForExistence(timeout: 5))
        app.buttons["settings.session"].tap()
        XCTAssertTrue(app.navigationBars["Choose session"].waitForExistence(timeout: 5))
    }

    /// Both build-19 switches and the new round-button row expose their real state.
    private func unmute(button id: String, legacy: String) {
        let button = app.buttons[id]
        if button.exists {
            if button.value as? String == "on" { button.tap() }
            XCTAssertEqual(button.value as? String, "off")
        } else {
            let toggle = app.switches[legacy]
            XCTAssertTrue(toggle.exists)
            if toggle.value as? String == "1" { toggle.tap() }
            XCTAssertEqual(toggle.value as? String, "0")
        }
    }

    /// Best-effort UI cleanup also runs after a failed assertion. Never starts a
    /// call on chief; only ends the owned call and restores the picker selection.
    private func endAndRestore() -> Bool {
        guard app.state == .runningForeground else { return false }
        let control = app.buttons["voice.startStop"]
        if control.exists && ["End call", "Stop voice", "End"].contains(control.label) {
            control.tap()
            guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Start voice' OR label == 'Start'"), object: control)], timeout: 8) == .completed else { return false }
        }
        if !app.navigationBars["Choose session"].exists {
            if !app.navigationBars["Sessions & settings"].exists {
                guard app.buttons["Settings"].exists else { return false }
                app.buttons["Settings"].tap()
            }
            guard app.buttons["settings.session"].waitForExistence(timeout: 5) else { return false }
            app.buttons["settings.session"].tap()
        }
        let chief = app.buttons["picker.chief"]
        guard chief.waitForExistence(timeout: 5) else { return false }
        chief.tap()
        guard app.navigationBars["Sessions & settings"].waitForExistence(timeout: 5) else { return false }
        app.buttons["Done"].tap()
        return !app.staticTexts["voice.target"].exists
    }

    override func tearDownWithError() throws {
        let restored = !needsCleanup || endAndRestore()
        app.terminate()
        XCTAssertTrue(restored, "Failed to end owned call/restore chief; stop device work, no retry")
        try super.tearDownWithError()
    }

    private func step(_ name: String, arguments: [String]) {
        continueAfterFailure = false
        app.terminate()
        app.launchArguments = ["-FVVoiceTurnProbe"] + arguments
        app.launch()
        needsCleanup = true
        let start = app.buttons["voice.startStop"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: start)
        waitForExpectations(timeout: 15)
        picker()
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText("ses_SYNTHETIC0017")
        let owned = app.buttons["picker.ses_SYNTHETIC0017"]
        XCTAssertTrue(owned.waitForExistence(timeout: 5)); owned.tap()
        XCTAssertTrue(app.navigationBars["Sessions & settings"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["voice.target"].exists, "The picker selected the exact owned ID; main displays its title, not a technical session ID")
        unmute(button: "voice.micMute", legacy: "Mic mute")
        unmute(button: "voice.outputMute", legacy: "Output mute")
        marker(name, "owned")
        start.tap()
        expectation(for: NSPredicate(format: "label == 'Listening'"), evaluatedWith: app.staticTexts["voice.state"])
        waitForExpectations(timeout: 15)
        marker(name, "listening")
        // Bounded native probe plus its initial UI-observation grace fits this wait.
        // The host additionally requires voiceprobe.completed and checks PCM/ASR evidence.
        Thread.sleep(forTimeInterval: 60)
        marker(name, "finished")
        XCTAssertTrue(endAndRestore(), "Owned call must end and chief must be restored through UI")
        needsCleanup = false
        marker(name, "chief-restored")
        app.terminate()
        print("FVVOICE_UI \(name) terminated \(Int(Date().timeIntervalSince1970 * 1000))")
        fflush(stdout)
    }

    func testVoiceTurnSpeaker() { step("speaker", arguments: []) }
    func testVoiceTurnEarpiece() { step("earpiece", arguments: ["-FVVoiceTurnReceiver"]) }
    func testVoiceTurnRoomGap() { step("mid-thought", arguments: ["-FVVoiceTurnReceiver", "-FVVoiceTurnMidThought"]) }
    func testVoiceTurnDigitalGap() { step("mid-thought-digital", arguments: ["-FVVoiceTurnReceiver", "-FVVoiceTurnMidThought", "-FVVoiceTurnDigitalGap"]) }
}
#endif
