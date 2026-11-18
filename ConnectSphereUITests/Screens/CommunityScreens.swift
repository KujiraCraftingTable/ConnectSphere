import XCTest

/// The Community tab (Hobby): My communities, Discover and Marketplace.
struct CommunityScreen {
    let app: XCUIApplication

    func segment(_ title: String) -> XCUIElement { app.segmentedControls.buttons[title] }
    func row(_ communityID: String) -> XCUIElement { app.descendants(matching: .any)[AXID.Community.row + communityID] }

    @discardableResult
    func open() throws -> Self {
        try MainScreen(app: app).tab(AXID.Tab.community).tapWhenReady()
        try segment("Discover").waitToAppear(timeout: 15)
        return self
    }
}

/// The system photo picker, presented over the app. Its photos are labelled
/// "Photo, <date>"; the simulator ships with sample ones.
struct PhotoPicker {
    let app: XCUIApplication

    func pickFirst() throws {
        // "Photo," with the comma: the app's own "photo" symbol is labelled "Photo".
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH %@", "Photo,")).firstMatch
        // The picker runs out of process; its grid has taken over 20 s to fill
        // while the dev server and Ollama share the machine.
        try photo.waitToAppear(timeout: 45)
        photo.tap()
        // Multi-select pickers wait for Add; single-select ones close on the tap.
        let add = app.buttons["Add"]
        if add.waitForExistence(timeout: 3) { add.tap() }
    }
}

/// Scrolls the current list up until `element` exists (lazy lists only build
/// rows near the screen).
func scrollUntilExists(_ element: XCUIElement, app: XCUIApplication, swipes: Int = 12) throws {
    for _ in 0..<swipes where !element.waitForExistence(timeout: 2) { app.swipeUp() }
    try element.waitToAppear(timeout: 5)
}
