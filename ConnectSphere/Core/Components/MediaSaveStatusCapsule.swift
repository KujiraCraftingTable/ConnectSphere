import SwiftUI

extension View {
    /// Floats `MediaSaveViewModel`'s progress/result line at the top of this
    /// view, a glass capsule that fades in and out on its own.
    func mediaSaveStatus(_ viewModel: MediaSaveViewModel) -> some View {
        overlay(alignment: .top) {
            if let message = viewModel.message {
                MediaSaveStatusCapsule(message: message, isSaving: viewModel.isSaving,
                                       isError: viewModel.status == .failed || viewModel.status == .denied)
                    .padding(.top, AppSpacing.md)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: viewModel.message)
        .sensoryFeedback(trigger: viewModel.status) { _, new in
            switch new {
            case .saved: return .success
            case .failed, .denied: return .error
            default: return nil
            }
        }
    }
}

private struct MediaSaveStatusCapsule: View {
    let message: String
    let isSaving: Bool
    let isError: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isSaving {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? Color.red : Color.green)
            }
            Text(message)
                .font(.system(size: 14, weight: .semibold))
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .modifier(GlassCapsule())
        .padding(.horizontal, AppSpacing.lg)
        .accessibilityElement(children: .combine)
    }
}

private struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}
