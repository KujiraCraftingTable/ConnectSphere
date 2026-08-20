import SwiftUI

struct AISearchLoadingView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    // Cycling messages (resolved lazily using bundle)
    private var messages: [String] {
        [
            bundle.loc("Kujira is reading your description~"),
            bundle.loc("Analyzing your description"),
            bundle.loc("Making a list, checking it twice"),
            bundle.loc("Almost there"),
            bundle.loc("There are so many people"),
            bundle.loc("The world turns, we swim"),
            bundle.loc("What to eat this afternoon"),
        ]
    }
    @State private var messageIndex = 0
    @State private var messageOpacity = 1.0

    // Orbiting dots
    @State private var orbitAngle: Double = 0

    @State private var messageTimer: Timer?

    var body: some View {
        ZStack {
            // Blurred background
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 32) {
                // ── Icon + orbit ───────────────────────────────────────────
                ZStack {
                    // Outer glow ring
                    Circle()
                        .stroke(themeManager.theme.primary.opacity(0.15), lineWidth: 1.5)
                        .frame(width: 110, height: 110)

                    // Orbiting dot
                    Circle()
                        .fill(themeManager.theme.primary)
                        .frame(width: 8, height: 8)
                        .offset(x: 55)
                        .rotationEffect(.degrees(orbitAngle))
                        .animation(
                            .linear(duration: 2).repeatForever(autoreverses: false),
                            value: orbitAngle
                        )

                    // Second orbiting dot (offset 180°)
                    Circle()
                        .fill(themeManager.theme.primary.opacity(0.4))
                        .frame(width: 5, height: 5)
                        .offset(x: 55)
                        .rotationEffect(.degrees(orbitAngle + 180))
                        .animation(
                            .linear(duration: 2).repeatForever(autoreverses: false),
                            value: orbitAngle
                        )

                    // Center circle
                    Circle()
                        .fill(themeManager.theme.primary.opacity(0.12))
                        .frame(width: 80, height: 80)

                    // Sparkles icon — SF Symbol animation
                    Image(systemName: "sparkles")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundColor(themeManager.theme.primary)
                        .symbolEffect(
                            .variableColor.iterative.dimInactiveLayers,
                            options: .repeating
                        )
                }

                // ── Cycling text ───────────────────────────────────────────
                VStack(spacing: 8) {
                    Text("Kujira")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(AppColors.textPrimary(colorScheme))

                    Text(messages[messageIndex])
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                        .opacity(messageOpacity)
                        .animation(.easeInOut(duration: 0.4), value: messageOpacity)
                }
            }
        }
        .onAppear {
            // Start orbit
            orbitAngle = 360

            // Cycle messages every 2s
            cycleMessages()
        }
        .onDisappear {
            messageTimer?.invalidate()
            messageTimer = nil
        }
    }

    private func cycleMessages() {
        messageTimer?.invalidate()
        messageTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { timer in
            withAnimation { messageOpacity = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                messageIndex = (messageIndex + 1) % messages.count
                withAnimation { messageOpacity = 1 }
            }
        }
    }
}

#Preview {
    AISearchLoadingView()
        .environment(AppState())
}
