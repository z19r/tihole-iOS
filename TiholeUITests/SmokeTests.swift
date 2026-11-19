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

        let password = app.textFields["instance.password"]
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
        // Wait for the first status fetch to settle the pill: a tap that
        // lands while it is redrawn from "unknown" to "on" is dropped.
        let pill = app.buttons["blocking.pill"]
        let settled = expectation(
            for: NSPredicate(format: "label == %@", "Blocking is on"),
            evaluatedWith: pill
        )
        wait(for: [settled], timeout: 15)
        let fiveMinutes = app.buttons["Disable for 5 minutes"]
        for _ in 0..<3 where !fiveMinutes.exists {
            pill.tap()
            _ = fiveMinutes.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(fiveMinutes.exists, "blocking sheet did not open")
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
        openTab("Queries")
        XCTAssertTrue(
            element(labelContaining: "ads.example.com").waitForExistence(timeout: 20),
            "query log did not load"
        )
        snap("06-queries")

        // Lists, then into Domains and Adlists.
        openTab("Lists")
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
        openTab("System")
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
        openTab("Settings")
        let configuration = element(labelBeginningWith: "Configuration")
        XCTAssertTrue(configuration.waitForExistence(timeout: 10))
        snap("12-settings")
        configuration.tap()
        XCTAssertTrue(
            element(labelContaining: "blocking.mode").waitForExistence(timeout: 20),
            "config tree did not load"
        )
        snap("13-config")

        // Turn blocking back on and finish on the dashboard, so the App
        // Store's dashboard shot shows blocking on.
        openTab("Dashboard")
        // The dashboard was left scrolled down, and iOS 27 hides the
        // navigation bar's items while it is, so scroll back to the top
        // until the pill is there again.
        for _ in 0..<3 where !pill.waitForExistence(timeout: 2) {
            app.swipeDown()
        }
        XCTAssertTrue(
            pill.waitForExistence(timeout: 10),
            "blocking pill did not reappear"
        )
        let enable = app.buttons["Enable blocking"]
        for _ in 0..<3 where !enable.exists {
            pill.tap()
            _ = enable.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(enable.exists, "blocking sheet did not open again")
        enable.tap()
        let back = expectation(
            for: NSPredicate(format: "label == %@", "Blocking is on"),
            evaluatedWith: pill
        )
        wait(for: [back], timeout: 15)
        XCTAssertTrue(
            element(labelContaining: "Total Queries").waitForExistence(
                timeout: 10
            )
        )
        snap("14-dashboard-final")
    }

    /// The onboarding demo button starts the in-app demo Pi-hole.
    func testDemo() throws {
        let demo = app.buttons["onboarding.demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 30), "demo button did not appear")
        demo.tap()
        XCTAssertTrue(
            element(labelContaining: "48,213").waitForExistence(timeout: 30),
            "demo dashboard did not load"
        )
    }

    // MARK: - Helpers

    /// Taps a tab. iPadOS draws its tab bar at the top, where it may not
    /// show up as a tab bar, so fall back to any button with that name.
    private func openTab(_ name: String) {
        let inTabBar = app.tabBars.buttons[name]
        (inTabBar.exists ? inTabBar : app.buttons[name].firstMatch).tap()
    }

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

    /// Pops the pushed screen. iOS 27 can report the navigation bar's back
    /// button as a plain element rather than a button, so when no button is
    /// found, swipe in from the leading edge instead.
    private func goBack() {
        let button = app.navigationBars.buttons.element(boundBy: 0)
        if button.waitForExistence(timeout: 2) {
            button.tap()
            return
        }
        let start = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)
        )
        let end = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)
        )
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
