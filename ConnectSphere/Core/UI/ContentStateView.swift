import SwiftUI

/// A screen's data-loading lifecycle. Keeps "still loading" distinct from
/// "loaded and genuinely empty" distinct from "failed" — so a network failure
/// no longer looks like an empty screen.
enum LoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)

    var errorMessage: String? {
        if case .failed(let m) = self { return m }
        return nil
    }
    var isLoading: Bool { self == .loading }
}

/// Standard wrapper for a list/content screen: shows a spinner while loading,
/// an error with a Retry button on failure, an empty-state view when there is
/// genuinely nothing, and the content otherwise.
struct ContentStateView<Content: View, Empty: View>: View {
    let state: LoadState
    let isEmpty: Bool
    let retry: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewBuilder let emptyState: () -> Empty

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appBundle) private var bundle

    var body: some View {
        switch state {
        case .loading where isEmpty:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        case .failed(let message) where isEmpty:
            EmptyStateView(
                systemImage: "wifi.exclamationmark",
                title: message,
                actionTitle: bundle.loc("Retry"),
                action: retry
            )
        default:
            if isEmpty {
                emptyState()
            } else {
                content()
            }
        }
    }
}
