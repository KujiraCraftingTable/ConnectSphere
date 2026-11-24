import SwiftUI

extension View {
    /// Tags a settings row the assistant can point at. When the assistant's
    /// "Take me there" names this row, it flashes once in the theme colour.
    func assistantHighlightRow(_ topic: AssistantGuidanceTopic) -> some View {
        modifier(AssistantHighlightRow(topic: topic))
    }

    /// Put on a settings `List` whose rows use `assistantHighlightRow`, so the
    /// list scrolls the pointed-at row into view.
    func assistantHighlightScroll() -> some View {
        modifier(AssistantHighlightScroll())
    }
}

private struct AssistantHighlightRow: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    let topic: AssistantGuidanceTopic
    @State private var lit = false

    func body(content: Content) -> some View {
        content
            .id(topic)
            .listRowBackground(
                Color(.secondarySystemGroupedBackground)
                    .overlay(themeManager.theme.primary.opacity(lit ? 0.25 : 0))
            )
            .task(id: appState.assistantHighlight) {
                guard appState.assistantHighlight == topic else { return }
                // The list can drop and rebuild a row while it scrolls, which
                // cancels this task. Stop without clearing the highlight, so
                // the rebuilt row flashes instead of the flash being skipped.
                do {
                    try await Task.sleep(for: .milliseconds(300))
                    withAnimation(.easeInOut(duration: 0.3)) { lit = true }
                    try await Task.sleep(for: .milliseconds(1800))
                } catch {
                    lit = false
                    return
                }
                withAnimation(.easeInOut(duration: 0.5)) { lit = false }
                if appState.assistantHighlight == topic { appState.assistantHighlight = nil }
            }
    }
}

private struct AssistantHighlightScroll: ViewModifier {
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content.task(id: appState.assistantHighlight) {
                guard let topic = appState.assistantHighlight else { return }
                do {
                    try await Task.sleep(for: .milliseconds(350))
                    withAnimation { proxy.scrollTo(topic, anchor: .center) }
                    // A row that isn't shown (say, a setting the official
                    // account doesn't have) never clears it, so drop it here
                    // instead of flashing later when someone opens the screen.
                    try await Task.sleep(for: .seconds(4))
                } catch {
                    return
                }
                if appState.assistantHighlight == topic { appState.assistantHighlight = nil }
            }
        }
    }
}
