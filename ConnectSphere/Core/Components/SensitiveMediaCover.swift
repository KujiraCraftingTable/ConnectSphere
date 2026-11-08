import SwiftUI

/// Photos and videos from someone who hasn't been accepted yet (a message
/// request in Waiting) arrive blurred, with "Tap to view": the usual first move
/// of unwanted nude photos is a stranger's first message. Like Instagram's
/// sensitive-content screens, one tap shows it.
struct SensitiveMediaCover: ViewModifier {
    @Environment(\.appBundle) private var bundle

    let isCovered: Bool
    let onReveal: () -> Void

    func body(content: Content) -> some View {
        if isCovered {
            content
                .blur(radius: 30)
                .allowsHitTesting(false)
                .overlay {
                    Button(action: onReveal) {
                        VStack(spacing: 6) {
                            Image(systemName: "eye.slash.fill").font(.system(size: 22))
                            Text("Tap to view", bundle: bundle).font(.system(size: 13, weight: .semibold))
                            Text("From someone you haven't accepted yet", bundle: bundle)
                                .font(.system(size: 11))
                                .multilineTextAlignment(.center)
                        }
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.4), radius: 4)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(.plain)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
        } else {
            content
        }
    }
}

extension View {
    func sensitiveMediaCover(_ isCovered: Bool, onReveal: @escaping () -> Void) -> some View {
        modifier(SensitiveMediaCover(isCovered: isCovered, onReveal: onReveal))
    }
}
