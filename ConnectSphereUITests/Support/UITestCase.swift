import XCTest

/// Base for every UI test. Each test gets its own run id; the accounts it
/// makes are `qa_ui_<run>_<n>` and are deleted in teardown, pass or fail.
/// (A crashed run is caught by `seed-demo wipe` and `scripts/uitest.sh`.)
class UITestCase: XCTestCase {
    let server = TestServer.shared
    private(set) var run = ""
    private(set) var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true // helpers throw to stop a test; see UIStepFailed
        run = String(UUID().uuidString.lowercased().filter { $0.isHexDigit }.prefix(8))
        let run = run
        let server = server
        addTeardownBlock { try await server.deleteRun(run) }
        addUIInterruptionMonitor(withDescription: "System alerts") { alert in
            for label in ["Not Now", "Don’t Allow", "Don't Allow", "Cancel"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    /// Starts the app in test mode, signed out, or signed in as `account`.
    @discardableResult
    func launch(signedInAs account: TestServer.Account? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-uiTestingReset",
                               "-uiTestingServer", server.serverURL,
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if let account { app.launchArguments += ["-uiTestingToken", account.token] }
        app.launch()
        self.app = app
        return app
    }

    /// The next free account number in this run, for sign-ups made in the UI.
    func username(_ n: Int) -> String { "qa_ui_\(run)_\(n)" }
    func email(_ n: Int) -> String { "qa_ui_\(run)_\(n)@example.test" }
}

// MARK: - Waiting (never sleep)

/// A UI step that didn't happen. Helpers throw it instead of asserting with
/// `continueAfterFailure = true // helpers throw to stop a test; see UIStepFailed`: that raises an exception, which hangs an
/// async test forever instead of failing it.
struct UIStepFailed: Error, CustomStringConvertible {
    let description: String
}

private func waitFor(_ format: String, on element: XCUIElement, timeout: TimeInterval) -> Bool {
    let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
    return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
}

extension XCUIElement {
    @discardableResult
    func waitToAppear(timeout: TimeInterval = 10) throws -> XCUIElement {
        guard waitForExistence(timeout: timeout) else { throw UIStepFailed(description: "\(self) did not appear") }
        return self
    }

    func waitToDisappear(timeout: TimeInterval = 10) throws {
        guard waitFor("exists == false", on: self, timeout: timeout) else {
            throw UIStepFailed(description: "\(self) did not go away")
        }
    }

    /// Waits until it can be tapped (on screen, enabled), then taps. Hides
    /// the keyboard or scrolls first when either is what keeps it out of reach.
    func tapWhenReady(timeout: TimeInterval = 10) throws {
        guard waitForExistence(timeout: timeout) else { throw UIStepFailed(description: "\(self) did not appear") }
        hideKeyboardIfCovering()
        let app = XCUIApplication()
        // A row that was just inserted can still be sliding in with no frame;
        // reading `isHittable` then fails the test ("activation point invalid")
        // instead of returning false.
        let laidOut = XCTNSPredicateExpectation(predicate: NSPredicate { element, _ in
            !((element as? XCUIElement)?.frame.isEmpty ?? true)
        }, object: self)
        guard XCTWaiter().wait(for: [laidOut], timeout: timeout) == .completed else {
            throw UIStepFailed(description: "\(self) never got a frame")
        }
        for _ in 0..<4 where !isHittable {
            if frame.minY < app.frame.midY { app.swipeDown() } else { app.swipeUp() }
        }
        guard waitFor("hittable == true AND enabled == true", on: self, timeout: timeout) else {
            throw UIStepFailed(description: "\(self) never became tappable")
        }
        tap()
    }

    /// Taps the field until it has the keyboard, then types into it. One tap
    /// isn't always enough: right after a secure field, focus can stay put.
    func enter(_ text: String) throws {
        // Already typing here (a composer that focuses itself): no tap needed.
        if waitForExistence(timeout: 10), hasFocus {
            typeText(text)
            return
        }
        let keyboard = XCUIApplication().keyboards.firstMatch
        for _ in 0..<3 {
            let keyboardWasUp = keyboard.exists
            try tapWhenReady()
            // Some editors (the report sheet's) never report focus; there, the
            // keyboard coming up for this tap is the sign it took.
            if waitFor("hasKeyboardFocus == true", on: self, timeout: 2)
                || (!keyboardWasUp && keyboard.exists) {
                typeText(text)
                return
            }
        }
        throw UIStepFailed(description: "\(self) never took the keyboard")
    }

    /// `hasKeyboardFocus` is only public as a predicate key, so read it by key.
    private var hasFocus: Bool { (value(forKey: "hasKeyboardFocus") as? Bool) ?? false }

    /// The keyboard and its AutoFill bar ("Suggested User Name") can sit over
    /// the next field while still counting it as hittable, so the tap lands
    /// on the bar. A tap near the top (the screen title) hides the keyboard:
    /// the app's `KeyboardDismissal` treats it as a tap outside the field.
    /// Fields only: a button just above the keyboard (a chat's Send) is fine,
    /// and on some screens the top is not inert (a chat's title opens its settings).
    private func hideKeyboardIfCovering() {
        guard [.textField, .secureTextField, .textView].contains(elementType) else { return }
        let app = XCUIApplication()
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists, !hasFocus, frame.maxY > keyboard.frame.minY - 60 else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        _ = keyboard.waitForNonExistence(timeout: 3)
    }
}

extension XCUIElementQuery {
    /// The one that can be tapped now, for screens that keep every page in
    /// the tree (the onboarding carousel has a Continue on each page).
    func hittable(timeout: TimeInterval = 10, scrolling: Bool = true) throws -> XCUIElement {
        // `hittable` can't go in a query predicate, so look at each match.
        // Past the first second, scroll: a long page (onboarding's interests)
        // keeps its button below the fold.
        let start = Date()
        var swipes = 0
        repeat {
            if let match = allElementsBoundByIndex.first(where: { $0.isHittable && $0.isEnabled }) { return match }
            if scrolling, Date().timeIntervalSince(start) > 1, swipes < 6 {
                XCUIApplication().swipeUp()
                swipes += 1
            } else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            }
        } while Date().timeIntervalSince(start) < timeout
        throw UIStepFailed(description: "nothing hittable in \(self)")
    }

    /// Elements whose identifier starts with `prefix` (list rows: `AXID.…Row.<id>`).
    func withIDPrefix(_ prefix: String) -> XCUIElementQuery {
        matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
    }
}
