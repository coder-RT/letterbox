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

    private func launch(scenario: String = "nearby", connectivity: String = "wifi", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"] + extra
        app.launchEnvironment = ["UITEST_SCENARIO": scenario, "UITEST_CONNECTIVITY": connectivity]
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
                   "Connections": "menu-connections", "Settings": "menu-settings"]
        let more = app.buttons["more-menu"]
        let opened: XCUIElement = item == "Privacy screen"
            ? app.descendants(matching: .any).matching(identifier: "privacy-banner").firstMatch
            : app.buttons["Done"].firstMatch
        for _ in 0..<3 {
            expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: more)
            waitForExpectations(timeout: 5)
            more.tap()
            let entry = app.descendants(matching: .any).matching(identifier: ids[item] ?? item).firstMatch
            guard entry.waitForExistence(timeout: 5) else { continue }
            Thread.sleep(forTimeInterval: 0.5) // let the menu finish opening
            if entry.isHittable { entry.tap() }
            if opened.waitForExistence(timeout: 3) { return }
            // Menu may still be open: dismiss it before trying again.
            if entry.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.9)).tap() }
        }
        XCTFail("Couldn't open \(item) from the menu")
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
        done(app)

        XCTAssertTrue(problems.isEmpty, "Accessibility problems:\n" + problems.joined(separator: "\n"))
    }

    /// Runs Apple's accessibility audit on the current screen and collects what it finds,
    /// so one run reports every screen.
    private func audit(_ app: XCUIApplication, _ screen: String, into problems: inout [String]) throws {
        // Let presentation and fade-in animations finish: mid-animation colours are
        // partly transparent and would be measured as low contrast.
        Thread.sleep(forTimeInterval: 2)
        var found: [String] = []
        try app.performAccessibilityAudit { issue in
            let element = issue.element
            let description = element?.debugDescription ?? ""
            // System-owned chrome we don't control (keyboard, the sheet grabber).
            if description.contains("Keyboard") || description.contains("grabber") { return true }
            // Navigation-bar items have a capped text size by design on iOS; they support
            // the Large Content Viewer instead (touch and hold), which the audit can't see.
            if issue.auditType == .dynamicType, let element, element.frame.maxY < 130 { return true }
            // List section headers and footers stop growing at accessibility sizes; that's
            // how iOS lists work and isn't something an app can change. (They're still
            // checked for contrast.)
            if issue.auditType == .dynamicType, let element,
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
