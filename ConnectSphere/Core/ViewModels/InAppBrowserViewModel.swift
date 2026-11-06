import SwiftUI

/// State of one in-app browser page, and the hand-off to the app that owns the link.
@MainActor @Observable
final class InAppBrowserViewModel {
    var title = ""
    var progress = 0.0
    var canGoBack = false
    var canGoForward = false
    /// The page being shown now, which can differ from the link tapped (redirects, taps inside the page).
    var currentURL: URL
    var showsNoAppAlert = false

    init(url: URL) { currentURL = url }

    /// What the top bar shows when the page has no title yet.
    var host: String { currentURL.host(percentEncoded: false) ?? currentURL.absoluteString }

    /// Opens the current page in the app that claims it (YouTube, Google Maps…).
    /// `universalLinksOnly` makes iOS refuse instead of falling back to Safari,
    /// which tells us no app is installed.
    func openInApp() async {
        let opened = await UIApplication.shared.open(currentURL, options: [.universalLinksOnly: true])
        if !opened { showsNoAppAlert = true }
    }
}
