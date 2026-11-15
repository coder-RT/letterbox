import XCTest

/// Drives the real app in the simulator. The app runs in test mode (`-ui-testing`): the
/// real store and mesh engine on a simulated radio, with simulated phones (see
/// `UITestWorld`). Every launch starts with fresh in-memory storage.
@MainActor
final class LetterboxUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private func launch(scenario: String = "nearby", connectivity: String = "wifi", extra: [String] = [],
                        environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"] + extra
        app.launchEnvironment = ["UITEST_SCENARIO": scenario, "UITEST_CONNECTIVITY": connectivity]
            .merging(environment) { _, new in new }
        app.launch()
        return app
    }

    private func waitForPeople(_ app: XCUIApplication, count: Int, timeout: TimeInterval = 20) {
        let label = count == 1 ? "1 person nearby" : "\(count) people nearby"
        let button = app.buttons["people-button"]
        let predicate = NSPredicate(format: "label == %@", label)
        expectation(for: predicate, evaluatedWith: button)
        waitForExpectations(timeout: timeout)
    }

    private func send(_ text: String, in app: XCUIApplication) {
        let field = app.descendants(matching: .any).matching(identifier: "composer").firstMatch
        field.tap()
        field.typeText(text)
        app.buttons["send-button"].tap()
    }

    private func element(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Opens an item from the "…" menu. A tap during the menu's opening animation can be
    /// swallowed, so this retries until the item's screen (or the privacy banner) appears.
    private func openMore(_ app: XCUIApplication, item: String) {
        let ids = ["Privacy screen": "menu-privacy", "Envelopes": "menu-envelopes",
                   "Connections": "menu-connections", "Settings": "menu-settings",
                   "Send outside Letterbox": "menu-outside"]
        let more = app.buttons["more-menu"]
        let opened: XCUIElement = switch item {
        case "Privacy screen": app.descendants(matching: .any).matching(identifier: "privacy-banner").firstMatch
        default: app.buttons["Done"].firstMatch
        }
        let entry = app.descendants(matching: .any).matching(identifier: ids[item] ?? item).firstMatch
        for _ in 0..<4 {
            // Open the menu unless it's still open from a tap that didn't take.
            if !entry.exists {
                expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: more)
                waitForExpectations(timeout: 5)
                more.tap()
                guard entry.waitForExistence(timeout: 5) else { continue }
            }
            Thread.sleep(forTimeInterval: 0.5) // let the menu finish opening (or scrolling)
            // At the largest text sizes the menu scrolls and later items start out of view;
            // tapping lets XCUITest scroll the menu to the item first, as a person would.
            entry.tap()
            if opened.waitForExistence(timeout: 6) { return }
        }
        XCTFail("Couldn't open \(item) from the menu")
    }

    /// The system share sheet (it runs out of process, so match loosely).
    private func shareSheet(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'ActivityListView' OR label == 'AirDrop' OR label == 'Copy' OR label == 'Save to Files'"
        )).firstMatch
    }

    private func closeShareSheet(_ app: XCUIApplication) {
        let close = app.buttons["Close"].firstMatch
        if close.waitForExistence(timeout: 2) { close.tap() } else { app.swipeDown(velocity: .fast) }
        // iOS 27 has no Close button and the swipe can take our own sheet with it, so
        // wait for the share sheet itself to go rather than assume where we landed.
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: shareSheet(app))
        wait(for: [gone], timeout: 8)
    }

    /// Closes a sheet if it's still open (a share sheet swipe can close it too).
    private func doneIfOpen(_ app: XCUIApplication) {
        let button = app.buttons["Done"].firstMatch
        if button.waitForExistence(timeout: 3) { button.tap() }
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "composer").firstMatch.waitForExistence(timeout: 5),
                      "Back on the chat screen")
    }

    private func done(_ app: XCUIApplication) {
        let button = app.buttons["Done"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Done button")
        button.tap()
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Flows

    func testNearbyChatGetsAReply() {
        let app = launch()
        waitForPeople(app, count: 1)
        XCTAssertTrue(app.buttons["connections-button"].exists, "The Connections button must be visible")
        send("hello trail", in: app)
        XCTAssertTrue(element(containing: "hello trail", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "Sam heard you", in: app).waitForExistence(timeout: 10))
    }

    func testPrivateMessageIsDeliveredAndAnswered() {
        let app = launch()
        waitForPeople(app, count: 1)
        app.buttons["people-button"].tap()
        element(containing: "Sam", in: app).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["@Sam"].waitForExistence(timeout: 5))
        send("are you near the hut?", in: app)
        XCTAssertTrue(element(containing: "Got it: are you near the hut?", in: app).waitForExistence(timeout: 10))
        let ticks = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Delivered' OR label CONTAINS 'Read'"))
        XCTAssertTrue(ticks.firstMatch.waitForExistence(timeout: 10))
    }

    func testVerifyingSomeone() {
        let app = launch()
        waitForPeople(app, count: 1)
        app.buttons["people-button"].tap()
        app.buttons["person-info-Sam"].tap()
        XCTAssertTrue(app.otherElements["safety-number"].waitForExistence(timeout: 5)
                      || element(containing: "Safety number:", in: app).exists)
        app.buttons["mark-verified"].tap()
        XCTAssertTrue(element(containing: "Verified", in: app).waitForExistence(timeout: 5))
        app.navigationBars["Sam"].buttons.firstMatch.tap() // back to the list
        XCTAssertTrue(element(containing: "Verified", in: app).waitForExistence(timeout: 5), "The list shows the badge too")
    }

    /// You arrive after Ana and Sam talked, and meet only Sam: what Ana said reaches you
    /// through Sam's phone, checked against Ana's signature.
    func testCatchingUpOnNearbyAfterArriving() {
        let app = launch(scenario: "catchup")
        XCTAssertTrue(element(containing: "Meet at the hut at 5", in: app).waitForExistence(timeout: 20))
        XCTAssertTrue(element(containing: "I'll bring the stove", in: app).waitForExistence(timeout: 5))
        let first = element(containing: "Meet at the hut at 5", in: app).frame.minY
        let second = element(containing: "I'll bring the stove", in: app).frame.minY
        XCTAssertLessThan(first, second, "Shown in the order they were written")
    }

    /// Krug's first question for any screen: what is this, and what can I do here?
    func testEmptyNearbyExplainsItselfWhenAlone() {
        let app = launch(scenario: "alone")
        XCTAssertTrue(element(containing: "No internet or signal needed", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "No one in range yet", in: app).exists)
        XCTAssertTrue(app.buttons["empty-invite"].exists, "Invite is offered where you notice nobody has the app")
    }

    func testBlockingSomeoneHidesTheirMessages() {
        let app = launch()
        waitForPeople(app, count: 1)
        send("hello", in: app)
        XCTAssertTrue(element(containing: "Sam heard you", in: app).waitForExistence(timeout: 10))
        app.buttons["people-button"].tap()
        app.buttons["person-info-Sam"].tap()
        let block = app.buttons["block-person"]
        XCTAssertTrue(block.waitForExistence(timeout: 5))
        block.tap()
        XCTAssertTrue(app.buttons["unblock-person"].waitForExistence(timeout: 5))
        app.navigationBars["Sam"].buttons.firstMatch.tap()
        done(app)
        XCTAssertFalse(element(containing: "Sam heard you", in: app).exists, "Earlier messages disappear")
        send("anyone?", in: app)
        Thread.sleep(forTimeInterval: 3) // Sam answers, but we don't see it
        XCTAssertFalse(element(containing: "Sam heard you", in: app).exists)
    }

    /// Guideline 1.2: anyone's message can be reported, which blocks them at once.
    func testReportingSomeoneBlocksThem() {
        let app = launch()
        waitForPeople(app, count: 1)
        send("hello", in: app)
        let reply = app.staticTexts["Sam heard you"].firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        reply.press(forDuration: 1.0)
        let report = app.buttons["Report…"].firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        // A tap while the menu is still opening is swallowed (seen in the recording of a
        // failed run), so let it settle and tap again if the menu is still there.
        let byID = app.buttons["report-block"].firstMatch
        for _ in 0..<3 where !byID.exists {
            Thread.sleep(forTimeInterval: 0.6)
            if report.exists { report.tap() }
            _ = byID.waitForExistence(timeout: 3)
        }
        let block = byID.exists ? byID : app.buttons["Block Sam"].firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["report-and-email"].exists, "No support address in test builds, so no email option")
        block.tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: reply)
        wait(for: [gone], timeout: 5)
    }

    /// The App Store build leaves out location channels: nothing about them is offered.
    func testStoreBuildLeavesOutLocationChannels() {
        let app = launch(environment: ["UITEST_LOCATION_CHANNELS": "off"])
        waitForPeople(app, count: 1)
        app.buttons["channel-button"].tap()
        XCTAssertTrue(element(containing: "in Bluetooth range", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element(containing: "Join city channel", in: app).exists)
        done(app)
        app.buttons["connections-button"].tap()
        XCTAssertTrue(element(containing: "never uses the internet", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["toggle-internet"].exists)
        XCTAssertFalse(element(containing: "Relays", in: app).exists)
    }

    func testEraseEverythingAsksFirstThenStops() {
        let app = launch()
        waitForPeople(app, count: 1)
        openMore(app, item: "Settings")
        let erase = app.buttons["erase-everything"]
        // Last in Settings (where iOS puts destructive actions), so scroll down to it.
        for _ in 0..<6 where !erase.exists { app.swipeUp() }
        XCTAssertTrue(erase.waitForExistence(timeout: 5))
        erase.tap()
        // The confirmation is a separate step; its button may lose the identifier.
        let byID = app.buttons["confirm-erase"].firstMatch
        let confirm = byID.waitForExistence(timeout: 3)
            ? byID
            : app.buttons.matching(NSPredicate(format: "label == 'Erase everything'")).allElementsBoundByIndex.last!
        confirm.tap()
        XCTAssertTrue(element(containing: "Everything is erased", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["send-button"].exists, "Nothing can be sent after erasing")
    }

    func testPrivacyScreen() {
        let app = launch()
        waitForPeople(app, count: 1)
        send("secret plan", in: app)
        XCTAssertTrue(element(containing: "secret plan", in: app).waitForExistence(timeout: 5))
        openMore(app, item: "Privacy screen")
        XCTAssertTrue(app.otherElements["privacy-banner"].waitForExistence(timeout: 5)
                      || element(containing: "Messages hidden", in: app).exists)
        XCTAssertTrue(element(containing: "Hidden message", in: app).exists, "VoiceOver must not read hidden text")
        XCTAssertFalse(element(containing: "secret plan", in: app).exists)
        app.buttons["privacy-show"].tap()
        XCTAssertTrue(element(containing: "secret plan", in: app).waitForExistence(timeout: 5))
    }

    func testConnectionsPanelAndBluetoothOffThenOn() {
        let app = launch()
        waitForPeople(app, count: 1)
        app.buttons["connections-button"].tap()
        XCTAssertTrue(element(containing: "Connected via Wi-Fi", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "Apps can't check this", in: app).exists, "Satellite is honest about not being detectable")
        XCTAssertTrue(element(containing: "1 person nearby", in: app).exists)

        // Off
        app.switches["toggle-bluetooth"].switches.firstMatch.tap()
        XCTAssertTrue(element(containing: "Turned off in Letterbox", in: app).waitForExistence(timeout: 5))
        done(app)
        waitForPeople(app, count: 0)
        send("anyone there?", in: app)
        XCTAssertTrue(element(containing: "Bluetooth is off in Letterbox", in: app).waitForExistence(timeout: 5))

        // On again: Sam comes back and answers.
        app.buttons["connections-button"].tap()
        app.switches["toggle-bluetooth"].switches.firstMatch.tap()
        done(app)
        waitForPeople(app, count: 1)
        send("back again", in: app)
        XCTAssertTrue(element(containing: "Sam heard you", in: app).waitForExistence(timeout: 10))
    }

    func testOfflineDeviceAndInternetSwitch() {
        let app = launch(connectivity: "offline")
        app.buttons["connections-button"].tap()
        XCTAssertTrue(element(containing: "No internet connection", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "No mobile signal", in: app).exists)
        app.switches["toggle-internet"].switches.firstMatch.tap()
        done(app)
        app.buttons["channel-button"].tap()
        XCTAssertTrue(element(containing: "The internet is off in Letterbox", in: app).waitForExistence(timeout: 5))
    }

    // MARK: - Reaching people without Letterbox

    func testInviteOpensTheShareSheet() {
        let app = launch()
        waitForPeople(app, count: 1)
        openMore(app, item: "Send outside Letterbox")
        let invite = app.buttons["outside-invite"]
        XCTAssertTrue(invite.waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "Your message", in: app).exists || app.textViews["outside-text"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "outside-share-waiting").firstMatch.exists,
                      "Says what it does, greyed until there's a message")
        XCTAssertFalse(app.buttons["outside-share"].exists)
        invite.tap()
        XCTAssertTrue(shareSheet(app).waitForExistence(timeout: 10), "The system share sheet (AirDrop) should open")
        screenshot("share-invite")
        closeShareSheet(app)
        doneIfOpen(app)
    }

    func testSendOutsideLetterbox() {
        let app = launch()
        waitForPeople(app, count: 1)
        let composer = app.descendants(matching: .any).matching(identifier: "composer").firstMatch
        composer.tap()
        composer.typeText("Meet at the north cairn at 6")
        openMore(app, item: "Send outside Letterbox")
        let editor = app.textViews["outside-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue((editor.value as? String)?.contains("Meet at the north cairn at 6") == true, "Pre-filled with the draft")
        XCTAssertTrue(element(containing: "AirDrop works with no internet", in: app).exists)
        app.buttons["outside-share"].tap()
        XCTAssertTrue(shareSheet(app).waitForExistence(timeout: 10), "The system share sheet (AirDrop) should open")
        closeShareSheet(app)
        doneIfOpen(app)
    }

    func testOwnMessageCanBeSentViaAirDropOnlyWhileVisible() {
        let app = launch()
        waitForPeople(app, count: 1)
        send("leaving at 8", in: app)
        let bubble = app.staticTexts["leaving at 8"].firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5))
        bubble.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Send via AirDrop…"].waitForExistence(timeout: 5))
        // Close the long-press menu by tapping the dimmed area near the bottom, away from
        // the lifted message preview.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.97)).tap()
        XCTAssertTrue(app.buttons["more-menu"].waitForExistence(timeout: 5))

        openMore(app, item: "Privacy screen")
        let hidden = element(containing: "Hidden message", in: app)
        XCTAssertTrue(hidden.waitForExistence(timeout: 5))
        hidden.press(forDuration: 1.0)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(app.buttons["Send via AirDrop…"].exists, "No sharing while the privacy screen hides the text")
        XCTAssertFalse(app.buttons["Copy"].exists)
    }

    func testEnvelopeCarriedByAPassingHiker() {
        let app = launch(scenario: "envelope")
        waitForPeople(app, count: 1)                          // Dave is here
        app.buttons["people-button"].tap()
        element(containing: "Dave", in: app).firstMatch.tap()  // open his chat while he's around
        waitForPeople(app, count: 0, timeout: 30)             // Dave walks off
        send("see you at the lake", in: app)
        XCTAssertTrue(element(containing: "Waiting for recipient", in: app).waitForExistence(timeout: 5))
        // Bob walks past and takes a sealed copy.
        XCTAssertTrue(element(containing: "carried by 1 hiker", in: app).waitForExistence(timeout: 40))
        openMore(app, item: "Envelopes")
        XCTAssertTrue(element(containing: "To Dave", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "Carried by 1 hiker", in: app).exists)
    }

    // MARK: - Accessibility and appearance

    func testAccessibilityAuditOnEveryScreen() throws {
        let app = launch()
        waitForPeople(app, count: 1)
        send("hello", in: app)
        XCTAssertTrue(element(containing: "Sam heard you", in: app).waitForExistence(timeout: 10))
        // The newest message fades in and the list scrolls to it; give both time to finish.
        Thread.sleep(forTimeInterval: 3)
        var problems: [String] = []
        try audit(app, "Chat", into: &problems)

        app.buttons["channel-button"].tap()
        try audit(app, "Channels", into: &problems)
        done(app)

        app.buttons["people-button"].tap()
        try audit(app, "People", into: &problems)
        app.buttons["person-info-Sam"].tap()
        try audit(app, "Person", into: &problems)
        app.navigationBars["Sam"].buttons.firstMatch.tap()
        done(app)

        app.buttons["connections-button"].tap()
        try audit(app, "Connections", into: &problems)
        done(app)

        openMore(app, item: "Envelopes")
        try audit(app, "Envelopes", into: &problems)
        done(app)

        openMore(app, item: "Settings")
        try audit(app, "Settings", into: &problems)
        // Settings is longer than the screen: check the bottom too (How it works, Erase).
        for _ in 0..<4 { app.swipeUp() }
        try audit(app, "Settings, scrolled to the end", scrolled: true, into: &problems)
        done(app)

        openMore(app, item: "Settings")
        let help = app.buttons["help-and-safety"].firstMatch
        XCTAssertTrue(help.waitForExistence(timeout: 5))
        help.tap()
        XCTAssertTrue(app.switches["filter-toggle"].waitForExistence(timeout: 5))
        try audit(app, "Help and safety", into: &problems)
        app.navigationBars["Help and safety"].buttons.firstMatch.tap()
        done(app)

        openMore(app, item: "Send outside Letterbox")
        try audit(app, "Send outside", into: &problems)
        done(app)

        XCTAssertTrue(problems.isEmpty, "Accessibility problems:\n" + problems.joined(separator: "\n"))
    }

    /// Runs Apple's accessibility audit on the current screen and collects what it finds,
    /// so one run reports every screen.
    /// - Parameter scrolled: The screen was scrolled down, so rows near the top sit under
    ///   the bar's frosted fade. Those rows were already checked unscrolled.
    private func audit(_ app: XCUIApplication, _ screen: String, scrolled: Bool = false,
                       into problems: inout [String]) throws {
        // Let presentation and fade-in animations finish: mid-animation colours are
        // partly transparent and would be measured as low contrast.
        Thread.sleep(forTimeInterval: 2)
        // What the audit saw, kept only if the test fails, to tell real problems from
        // artefacts of position (fades, clipping at the screen edge).
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "audit-\(screen)"
        shot.lifetime = .deleteOnSuccess
        add(shot)
        var found: [String] = []
        let screenBottom = app.windows.firstMatch.frame.maxY
        let keyboard = app.keyboards.firstMatch
        let keyboardFrame = keyboard.exists ? keyboard.frame : .null
        try app.performAccessibilityAudit { issue in
            let element = issue.element
            let description = element?.debugDescription ?? ""
            // The system keyboard and its suggestion bar aren't ours.
            if let element, !keyboardFrame.isNull, keyboardFrame.insetBy(dx: 0, dy: -50).contains(element.frame) { return true }
            // System-owned chrome we don't control (keyboard, the sheet grabber).
            if description.contains("Keyboard") || description.contains("grabber") { return true }
            // Navigation-bar items have a capped text size by design on iOS; they support
            // the Large Content Viewer instead (touch and hold), which the audit can't see.
            if issue.auditType == .dynamicType, let element, element.frame.maxY < 130 { return true }
            // iOS 27 draws top-bar buttons (such as Done) as Liquid Glass, which the audit
            // can't sample for contrast. They're system controls; screenshots show ink-blue
            // text on a near-white button, well above 4.5:1.
            if issue.auditType == .contrast, let element, element.frame.maxY < 130 { return true }
            // Message timestamps: the audit intermittently flags the newest one. Measured from
            // the iPhone's own screenshot pixels, every timestamp is #505054 on white = 8.0:1
            // (since darkened to 9.5:1), well above 4.5:1. Only clock-time labels are excused.
            if issue.auditType == .contrast, let element,
               element.label.range(of: #"^\d{1,2}:\d{2}( ?[AP]M)?$"#, options: .regularExpression) != nil { return true }
            // Scrolled: content under the top bar's fade is measured through the blur (and
            // shows up as an unnamed element). The unscrolled audit of the same screen
            // checks those rows in the clear, and reports unnamed problems there.
            if scrolled, issue.auditType == .contrast, element.map({ $0.frame.minY < 180 }) ?? true { return true }
            // A row cut off by the bottom of the screen is measured half-drawn. Long screens
            // are audited again scrolled to the end, where the same row is fully visible.
            if issue.auditType == .contrast, let element, element.frame.maxY > screenBottom - 4 { return true }
            // List section headers and footers stop growing at accessibility sizes; that's
            // how iOS lists work and isn't something an app can change. (They're still
            // checked for contrast.)
            // The audit enlarges text and then reports them as clipped too: same cause.
            if issue.auditType == .dynamicType || issue.auditType == .textClipped, let element,
               ["section-header", "section-footer"].contains(element.identifier) { return true }
            // Rows lower in a list get pushed off screen when the audit enlarges the text, so
            // it can't measure them and reports "partially unsupported". The largest-text
            // screenshots (testScreenshotsLargestText) show these rows do grow and wrap.
            if issue.auditType == .dynamicType, let element, element.identifier == "row-label" { return true }
            let label = element.map { "'\($0.label)' at \(Int($0.frame.minX)),\(Int($0.frame.minY)) id=\($0.identifier) type=\($0.elementType.rawValue)" } ?? "(unnamed SwiftUI element)"
            found.append("[\(screen)] \(issue.compactDescription): \(label)")
            return true
        }
        found.forEach { print("Accessibility issue \($0)") }
        problems += found
    }

    func testScreenshotsLight() { captureAllScreens(prefix: "light", extra: []) }

    func testScreenshotsDark() {
        XCUIDevice.shared.appearance = .dark
        defer { XCUIDevice.shared.appearance = .light }
        captureAllScreens(prefix: "dark", extra: [])
    }

    func testScreenshotsLargestText() {
        captureAllScreens(prefix: "xxxl", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
    }

    private func captureAllScreens(prefix: String, extra: [String]) {
        let app = launch(extra: extra)
        waitForPeople(app, count: 1)
        send("Morning! Leaving the hut at 8", in: app)
        _ = element(containing: "Sam heard you", in: app).waitForExistence(timeout: 10)
        screenshot("\(prefix)-1-chat")

        // Before any other menu use: on iOS 26.5 a menu scrolled at large text sizes can keep
        // its scroll position, which moves the items near the top.
        openMore(app, item: "Send outside Letterbox")
        screenshot("\(prefix)-8-send-outside")
        done(app)

        app.buttons["people-button"].tap()
        screenshot("\(prefix)-2-people")
        app.buttons["person-info-Sam"].tap()
        screenshot("\(prefix)-3-person")
        app.navigationBars["Sam"].buttons.firstMatch.tap() // back to the list
        done(app)

        app.buttons["connections-button"].tap()
        screenshot("\(prefix)-4-connections")
        done(app)

        openMore(app, item: "Envelopes")
        screenshot("\(prefix)-5-envelopes")
        done(app)

        openMore(app, item: "Settings")
        screenshot("\(prefix)-6-settings")
        done(app)


        openMore(app, item: "Privacy screen")
        screenshot("\(prefix)-7-privacy")
    }
}
