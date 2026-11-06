import SwiftUI
import WebKit

/// Where every external link opens first: a full-screen web page inside the app,
/// with "Open app" to continue in the app that owns the link (YouTube, Google
/// Maps…), the way Facebook/Instagram/Messenger handle links. Nothing leaves
/// ConnectSphere until the person taps it.
struct InAppBrowserView: View {
    let onDismiss: () -> Void

    @State private var model: InAppBrowserViewModel
    @State private var handle = WebHandle()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appBundle) private var bundle
    @Environment(ThemeManager.self) private var themeManager

    init(url: URL, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        _model = State(initialValue: InAppBrowserViewModel(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ProgressView(value: model.progress)
                .tint(themeManager.theme.primary)
                .opacity(model.progress < 1 ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: model.progress)
            WebContent(startURL: model.currentURL, model: model, handle: handle)
            bottomBar
        }
        .background(AppColors.surface(colorScheme))
        .alert(Text("No app found", bundle: bundle), isPresented: $model.showsNoAppAlert) {
            Button(role: .cancel) {} label: { Text("OK", bundle: bundle) }
        } message: {
            Text("No installed app can open this link. You can keep reading it here.", bundle: bundle)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(AppColors.borderDefault(colorScheme).opacity(0.5)))
            }
            .accessibilityLabel(Text("Done", bundle: bundle))

            VStack(spacing: 1) {
                Text(model.title.isEmpty ? model.host : model.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                if !model.title.isEmpty {
                    Text(model.host)
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)

            Button { Task { await model.openInApp() } } label: {
                Label { Text("Open app", bundle: bundle) } icon: { Image(systemName: "arrow.up.forward.app") }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(themeManager.theme.primary))
            }
        }
        .foregroundColor(AppColors.textPrimary(colorScheme))
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var bottomBar: some View {
        HStack(spacing: 32) {
            Button { handle.webView?.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!model.canGoBack)
                .accessibilityLabel(Text("Back", bundle: bundle))
            Button { handle.webView?.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!model.canGoForward)
                .accessibilityLabel(Text("Forward", bundle: bundle))
            Spacer()
            ShareLink(item: model.currentURL) { Image(systemName: "square.and.arrow.up") }
        }
        .font(.system(size: 18, weight: .medium))
        .foregroundColor(AppColors.textPrimary(colorScheme))
        .padding(.horizontal, 24).padding(.vertical, 12)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Lets the SwiftUI buttons reach the web view they control.
final class WebHandle {
    weak var webView: WKWebView?
}

private struct WebContent: UIViewRepresentable {
    let startURL: URL
    let model: InAppBrowserViewModel
    let handle: WebHandle

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        handle.webView = web
        context.coordinator.observe(web)
        web.load(URLRequest(url: startURL))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let model: InAppBrowserViewModel
        private var observations: [NSKeyValueObservation] = []

        init(model: InAppBrowserViewModel) { self.model = model }

        func observe(_ web: WKWebView) {
            observations = [
                web.observe(\.estimatedProgress, options: [.new]) { [model] w, _ in
                    Task { @MainActor in model.progress = w.estimatedProgress }
                },
                web.observe(\.title, options: [.new]) { [model] w, _ in
                    Task { @MainActor in model.title = w.title ?? "" }
                },
                web.observe(\.canGoBack, options: [.new]) { [model] w, _ in
                    Task { @MainActor in model.canGoBack = w.canGoBack }
                },
                web.observe(\.canGoForward, options: [.new]) { [model] w, _ in
                    Task { @MainActor in model.canGoForward = w.canGoForward }
                },
                web.observe(\.url, options: [.new]) { [model] w, _ in
                    Task { @MainActor in if let u = w.url { model.currentURL = u } }
                },
            ]
        }

        /// Pages that try to jump straight into another app (`youtube://`, `intent:`…)
        /// stay here; the person chooses that with "Open app". A link meant for a
        /// new window loads in this one.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let scheme = action.request.url?.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" || scheme == "about" else {
                decisionHandler(.cancel); return
            }
            if action.targetFrame == nil { webView.load(action.request); decisionHandler(.cancel); return }
            decisionHandler(.allow)
        }
    }
}

/// `URL` isn't `Identifiable`, so `.fullScreenCover(item:)` needs a thin wrapper.
private struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

extension View {
    /// Presents `url` full-screen in the in-app browser when non-nil.
    /// Uses `.fullScreenCover(item:)` (the codebase's full-screen idiom) rather
    /// than `isPresented:`, which can render blank during the dismiss animation
    /// because the bound value is already `nil` by then.
    ///
    /// Only `http`/`https` URLs belong here. Callers route other schemes
    /// (`mailto:`, `tel:`) through the system `openURL`.
    func inAppBrowser(url: Binding<URL?>) -> some View {
        fullScreenCover(item: Binding<IdentifiableURL?>(
            get: { url.wrappedValue.map(IdentifiableURL.init) },
            set: { url.wrappedValue = $0?.url }
        )) { item in
            InAppBrowserView(url: item.url) { url.wrappedValue = nil }
        }
    }
}
