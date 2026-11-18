import XCTest

/// The signed-in app: the tab bar, and Settings reached from Profile.
struct MainScreen {
    let app: XCUIApplication

    /// The system tab bar has no identifiers; its buttons carry their labels
    /// (English in test mode). Liquid Glass may not report a `tabBar`, so
    /// any button with the label counts.
    func tab(_ label: String) -> XCUIElement {
        let inBar = app.tabBars.buttons[label]
        return inBar.exists ? inBar : app.buttons[label]
    }

    @discardableResult
    func waitUntilShown(timeout: TimeInterval = 20) throws -> Self {
        try tab(AXID.Tab.profile).waitToAppear(timeout: timeout)
        return self
    }

    func logOut() throws {
        try tab(AXID.Tab.profile).tapWhenReady()
        try app.buttons[AXID.Profile.settingsButton].tapWhenReady(timeout: 15)
        let row = app.buttons[AXID.Settings.logout]
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        try row.tapWhenReady()
        // The confirmation is a system alert: found by its English text.
        try app.alerts.buttons["Log out"].tapWhenReady()
    }
}
