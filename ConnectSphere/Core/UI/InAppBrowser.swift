import SwiftUI
import SafariServices

/// In-app web browser for external links — the same UX Facebook/X/Instagram
/// use: tapping a link opens it inside the app (with Safari's own reader/
/// share/"Open in Safari" chrome, and "Open in [App]" for any URL a
/// universal-link-registered app claims) instead of leaving the app outright.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    var onDismiss: () -> Void = {}

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }

    /// `SFSafariViewController` doesn't dismiss itself on its own "Done" tap —
    /// per Apple's contract the delegate is responsible for that.
    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onDismiss: () -> Void
        init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onDismiss()
        }
    }
}

/// `URL` isn't `Identifiable`, so `.fullScreenCover(item:)` needs a thin wrapper.
private struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

extension View {
    /// Presents `url` full-screen in the in-app Safari browser when non-nil.
    /// Uses `.fullScreenCover(item:)` (the codebase's existing full-screen
    /// idiom — see `PostPhotoGrid`, `ChatView`, `StoriesRow`) rather than
    /// `isPresented:` with an optional unwrapped inside the closure, which has
    /// a known SwiftUI pitfall: the content closure can re-evaluate — and
    /// render blank — before the dismiss animation finishes, since the bound
    /// value is already `nil` by then. `item:` avoids that by retaining the
    /// last non-nil value through the dismiss transition.
    ///
    /// Only `http`/`https` URLs are safe here — callers should route other
    /// schemes (`mailto:`, `tel:`, a custom app link) through the system
    /// `openURL` instead, which `SFSafariViewController` can't handle.
    func inAppBrowser(url: Binding<URL?>) -> some View {
        fullScreenCover(item: Binding<IdentifiableURL?>(
            get: { url.wrappedValue.map(IdentifiableURL.init) },
            set: { url.wrappedValue = $0?.url }
        )) { item in
            SafariView(url: item.url) { url.wrappedValue = nil }
        }
    }
}
