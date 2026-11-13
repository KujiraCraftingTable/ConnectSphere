import SwiftUI

extension View {
    /// A spinner in the middle of the screen over a dimmed, untappable page,
    /// while something the user started (publishing a post or listing) runs.
    func processingOverlay(_ isPresented: Bool) -> some View {
        overlay {
            if isPresented {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    ProgressView()
                        .controlSize(.large)
                        .frame(width: 88, height: 88)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                }
                .transition(.opacity)
                .accessibilityAddTraits(.isModal)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isPresented)
    }
}
