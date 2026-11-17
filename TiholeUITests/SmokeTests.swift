import XCTest

/// Drives the real app against `MockPihole`: onboarding, then every tab and a
/// few pushed screens, capturing a screenshot at each stop. It proves the app
/// launches, logs in, loads, and renders; the screenshots are attached to the
/// test results for a human to look at.
final class SmokeTests: XCTestCase {
    private var server: MockPihole!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        server = try MockPihole()
        try server.start()

        app = XCUIApplication()
        // Start from a clean slate even when the simulator has run the app
        // before (see ConfigStore.reset).
        app.launchArguments = ["--reset-state"]
        app.launch()
    }

    override func tearDown() {
        server?.stop()
        server = nil
        app = nil
    }

    func testOnboardingThroughEveryTab() throws {
        // Onboarding: there is no instance yet, so the form is the first screen.
        let name = app.textFields["instance.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 30), "onboarding form did not appear")
        name.tap()
        name.typeText("home")

        let url = app.textFields["instance.url"]
        url.tap()
        url.typeText("http://127.0.0.1:\(server.port)")

        let password = app.secureTextFields["instance.password"]
        password.tap()
        password.typeText(MockPihole.password + "\n")
        snap("01-onboarding")

        let test = app.buttons["instance.test"]
        scrollUntilHittable(test)
        test.tap()
        XCTAssertTrue(
            element(labelContaining: "Connection succeeded").waitForExistence(timeout: 20),
            "test connection did not succeed"
        )

        let save = app.buttons["instance.save"]
        scrollUntilHittable(save)
        save.tap()

        // Dashboard.
        XCTAssertTrue(
            element(labelContaining: "Total Queries").waitForExistence(timeout: 30),
            "dashboard did not load"
        )
        XCTAssertTrue(element(labelContaining: "48,213").waitForExistence(timeout: 10))
        snap("02-dashboard")

        // Blocking: disable for five minutes, and the pill starts counting down.
        let pill = app.buttons["blocking.pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        print("DEBUG pill frame=\(pill.frame) hittable=\(pill.isHittable)")
        print("DEBUG navbars:\n\(app.navigationBars.debugDescription)")
        pill.tap()
        let fiveMinutes = app.buttons["Disable for 5 minutes"]
        XCTAssertTrue(fiveMinutes.waitForExistence(timeout: 10), "blocking sheet did not open")
        snap("04-blocking")
        fiveMinutes.tap()
        XCTAssertTrue(
            element(labelContaining: "Blocking is off").waitForExistence(timeout: 15),
            "blocking did not turn off"
        )
        snap("05-blocking-off")
        app.swipeUp()
        snap("03-dashboard-lower")

        // Query log.
        app.tabBars.buttons["Queries"].tap()
        XCTAssertTrue(
            element(labelContaining: "ads.example.com").waitForExistence(timeout: 20),
            "query log did not load"
        )
        snap("06-queries")

        // Lists, then into Domains and Adlists.
        app.tabBars.buttons["Lists"].tap()
        let domains = element(labelBeginningWith: "Domains")
        XCTAssertTrue(domains.waitForExistence(timeout: 10))
        snap("07-lists")
        domains.tap()
        XCTAssertTrue(
            element(labelContaining: "telemetry.example.net").waitForExistence(timeout: 20),
            "domains did not load"
        )
        snap("08-domains")
        goBack()

        let adlists = element(labelBeginningWith: "Adlists")
        XCTAssertTrue(adlists.waitForExistence(timeout: 10))
        adlists.tap()
        XCTAssertTrue(
            element(labelContaining: "StevenBlack").waitForExistence(timeout: 20),
            "adlists did not load"
        )
        snap("09-adlists")
        goBack()

        // System, then into Info.
        app.tabBars.buttons["System"].tap()
        let info = element(labelBeginningWith: "Info")
        XCTAssertTrue(info.waitForExistence(timeout: 10))
        snap("10-system")
        info.tap()
        XCTAssertTrue(
            element(labelContaining: "Raspberry Pi 4").waitForExistence(timeout: 20),
            "system info did not load"
        )
        snap("11-system-info")
        goBack()

        // Settings, then into the config tree.
        app.tabBars.buttons["Settings"].tap()
        let configuration = element(labelBeginningWith: "Configuration")
        XCTAssertTrue(configuration.waitForExistence(timeout: 10))
        snap("12-settings")
        configuration.tap()
        XCTAssertTrue(
            element(labelContaining: "blocking.mode").waitForExistence(timeout: 20),
            "config tree did not load"
        )
        snap("13-config")
    }

    // MARK: - Helpers

    /// The first element of any type whose accessibility label contains
    /// `text`. Rows combine their children into one element, so matching by
    /// exact label would miss them.
    private func element(labelContaining text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    private func element(labelBeginningWith text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", text))
            .firstMatch
    }

    /// Scrolls the form until `element` can be tapped. Form rows below the
    /// fold may not exist until they are scrolled into view.
    private func scrollUntilHittable(_ element: XCUIElement) {
        for _ in 0..<6 {
            if element.exists && element.isHittable {
                return
            }
            app.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(element) never appeared")
    }

    private func goBack() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
