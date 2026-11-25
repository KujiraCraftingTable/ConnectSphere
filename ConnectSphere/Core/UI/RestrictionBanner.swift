import SwiftUI

// MARK: - Countdown text
/// Time left on a moderation restriction, to the minute: "2d 5h 12m".
/// Rounded up, so the last minute reads "0d 0h 1m" rather than nothing.
enum RestrictionCountdown {
    static func text(until: Date, now: Date = .now, bundle: Bundle) -> String {
        let minutes = max(0, Int((until.timeIntervalSince(now) / 60).rounded(.up)))
        return String(format: bundle.loc("%dd %dh %dm"), minutes / 1440, minutes % 1440 / 60, minutes % 60)
    }

    /// A restriction's length as picked: "6 hours", "1 day", "3 days".
    static func length(hours: Int, bundle: Bundle) -> String {
        if hours < 24 { return String(format: bundle.loc("%lld hours"), hours) }
        if hours == 24 { return bundle.loc("1 day") }
        return String(format: bundle.loc("%lld days"), hours / 24)
    }

    static func modeName(_ mode: AppMode, bundle: Bundle) -> String {
        bundle.loc(mode == .hobby ? "Hobby Mode" : "Work Mode")
    }
}

// MARK: - Banner
/// Shown at the top of Home while a moderation restriction runs in the
/// current mode: a red card counting down to the end, and what still works.
struct RestrictionBanner: View {
    @Environment(\.appBundle) private var bundle
    @Environment(AppState.self) private var appState

    var body: some View {
        if let until = appState.restrictedUntil {
            // Ticks every minute; the `if` inside drops the banner once it runs out.
            TimelineView(.everyMinute) { context in
                if until > context.date {
                    card(until: until, now: context.date)
                }
            }
        }
    }

    private func card(until: Date, now: Date) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 24))
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(String(format: bundle.loc("Restricted in %@"),
                            RestrictionCountdown.modeName(appState.currentMode, bundle: bundle)))
                    .font(.system(size: 13, weight: .semibold))
                    .opacity(0.9)
                Text(String(format: bundle.loc("%@ left"), RestrictionCountdown.text(until: until, now: now, bundle: bundle)))
                    .font(.system(size: 20, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(bundle.loc("Your account is read-only. You can browse, change settings, block and report, but you can't post, comment, message, react, join, sell or add friends."))
                    .font(.system(size: 14))
                    .opacity(0.9)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(Color.red.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Restricted controls
/// Greys out a control a restricted account can't use. The server refuses the
/// action anyway; this just saves a tap that would only end in an error.
private struct RestrictedControl: ViewModifier {
    @Environment(AppState.self) private var appState
    let applies: Bool

    func body(content: Content) -> some View {
        let off = applies && appState.isRestricted
        content
            .disabled(off)
            .opacity(off ? 0.4 : 1)
    }
}

/// `RestrictedControl` for a way to message someone: still greyed out, but a
/// tap says why and for how long, in a toast, instead of doing nothing.
private struct RestrictedMessagingControl: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    // Optional: a sheet without the app-wide presenter just shows no toast.
    @Environment(UndoToastPresenter.self) private var toast: UndoToastPresenter?

    func body(content: Content) -> some View {
        let off = appState.isRestricted
        content
            .disabled(off)
            .opacity(off ? 0.4 : 1)
            .overlay {
                if off {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { explain() }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(Text(message))
                }
            }
    }

    private var message: String {
        guard let until = appState.restrictedUntil else { return "" }
        return String(format: bundle.loc("You're restricted in %@ for %@, so you can't send messages."),
                      RestrictionCountdown.modeName(appState.currentMode, bundle: bundle),
                      RestrictionCountdown.text(until: until, bundle: bundle))
    }

    private func explain() {
        toast?.show(message: message, edge: .top)
    }
}

// MARK: - View modifiers
extension View {
    /// `applies: false` leaves the control alone.
    func disabledWhenRestricted(_ applies: Bool = true) -> some View { modifier(RestrictedControl(applies: applies)) }

    /// For message composers and "message them" buttons: greyed out while
    /// restricted, and a tap shows a toast with the time left.
    func messagingDisabledWhenRestricted() -> some View { modifier(RestrictedMessagingControl()) }
}
