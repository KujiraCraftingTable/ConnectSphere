import XCTest

/// SearchView: the field, the AI switch, the scope picker and the people results.
struct SearchScreen {
    let app: XCUIApplication

    var field: XCUIElement { app.textFields[AXID.Search.field] }
    var aiToggle: XCUIElement { app.buttons[AXID.Search.aiToggle] }
    var aiLoading: XCUIElement { app.descendants(matching: .any)[AXID.Search.aiLoading] }
    var noResults: XCUIElement { app.staticTexts["No results found"] }

    /// A scope segment, found by its English title ("People", "Posts", "Companies").
    func scope(_ title: String) -> XCUIElement { app.segmentedControls.buttons[title] }

    func row(_ userID: String) -> XCUIElement {
        app.descendants(matching: .any)[AXID.Search.row + userID]
    }

    @discardableResult
    func open() throws -> Self {
        try MainScreen(app: app).tab(AXID.Tab.search).tapWhenReady()
        try field.waitToAppear(timeout: 15)
        return self
    }

    func setAI(_ on: Bool) throws {
        guard aiToggle.isSelected != on else { return }
        try aiToggle.tapWhenReady()
        try aiToggle.waitUntilSelected(on)
    }

    /// Types `query`; Return runs an AI search when AI is on (keyword search
    /// already runs as you type).
    func search(_ query: String) throws {
        try field.enter(query + "\n")
    }
}
