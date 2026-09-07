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
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 36))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
                Text(message)
                    .font(.system(size: 14))
                    .multilineTextAlignment(.center)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .padding(.horizontal, 32)
                Button(bundle.loc("Retry"), action: retry)
                    .font(.system(size: 14, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        default:
            if isEmpty {
                emptyState()
            } else {
                content()
            }
        }
    }
}
