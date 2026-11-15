import XCTest

/// Tests that only make sense on a real iPhone: the real app (not test mode), real
/// network and mobile-radio readings, and real Bluetooth. Skipped in the simulator.
///
/// The Mac test needs the Letterbox Mac app running nearby. Enable it with
/// `TEST_RUNNER_EXPECT_MAC_PEER=1 xcodebuild test …`.
@MainActor
final class DeviceTests: XCTestCase {
    override func setUp() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Real-device only")
        #endif
        continueAfterFailure = true
    }

    private func launchRealApp() -> XCUIApplication {
        // Accept the system's Bluetooth or location prompts if they appear.
        addUIInterruptionMonitor(withDescription: "Permission prompts") { alert in
            for title in ["Allow", "OK", "Allow While Using App"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
        let app = XCUIApplication()
        app.launchArguments = [] // the real app, with real adapters
        app.launch()
        app.tap() // lets the interruption monitor handle a prompt shown at launch
        return app
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A row's spoken text, scrolling down to it first: lists only load rows on screen.
    private func status(of kind: String, in app: XCUIApplication) -> String {
        let row = app.descendants(matching: .any).matching(identifier: "connection-\(kind)").firstMatch
        var swipes = 0
        while !row.exists, swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        return row.exists ? row.label : ""
    }

    func testRealConnectionsOnDevice() {
        let app = launchRealApp()
        XCTAssertTrue(app.buttons["connections-button"].waitForExistence(timeout: 10))
        app.buttons["connections-button"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "connection-bluetooth").firstMatch.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 3) // let the real monitors report

        var report: [String] = []
        for kind in ["bluetooth", "internet", "wifi", "mobile", "satellite", "location", "relays", "envelopes"] {
            let label = status(of: kind, in: app)
            report.append("\(kind): \(label)")
            XCTAssertFalse(label.isEmpty, "\(kind) row is missing")
            XCTAssertFalse(label.contains("Checking"), "\(kind) never reported: \(label)")
        }
        print("REAL DEVICE CONNECTIONS\n" + report.joined(separator: "\n"))
        let text = XCTAttachment(string: report.joined(separator: "\n"))
        text.name = "real-connections.txt"
        text.lifetime = .keepAlways
        add(text)

        XCTAssertTrue(status(of: "satellite", in: app).contains("Apps can't check this"))
        XCTAssertTrue(status(of: "mobile", in: app).contains("Signal") || status(of: "mobile", in: app).contains("No mobile signal"),
                      "Mobile row should come from CoreTelephony on an iPhone")
        attachScreenshot("device-connections-bottom")
    }

    func testRealBluetoothWithMac() throws {
        guard ProcessInfo.processInfo.environment["EXPECT_MAC_PEER"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_EXPECT_MAC_PEER=1 with the Mac app running nearby")
        }
        let app = launchRealApp()
        let people = app.buttons["people-button"]
        XCTAssertTrue(people.waitForExistence(timeout: 10))
        // The Mac should appear as a nearby person over real Bluetooth.
        let found = NSPredicate(format: "NOT (label BEGINSWITH '0 ')")
        expectation(for: found, evaluatedWith: people)
        waitForExpectations(timeout: 90)
        attachScreenshot("device-mac-found")

        let stamp = Date().formatted(date: .omitted, time: .standard)
        let text = "hello from the iPhone test \(stamp)"
        let field = app.descendants(matching: .any).matching(identifier: "composer").firstMatch
        field.tap()
        field.typeText(text)
        app.buttons["send-button"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
            .waitForExistence(timeout: 5))
        print("REAL MESH MESSAGE SENT: \(text)")
        attachScreenshot("device-message-sent")
    }
}
