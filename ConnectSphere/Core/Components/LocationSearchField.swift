import MapKit
import SwiftUI

/// A text field for a place, with MapKit suggestions listed under it while
/// it has focus; tapping one fills the field ("Title, subtitle"). Every typed
/// location in the app uses it. First built for the chat meeting composer.
struct LocationSearchField<Styled: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    private let placeholder: String
    @Binding private var text: String
    /// How the text box itself looks (a grey box, a plain Form row…); the
    /// suggestions sit outside it.
    private let style: (AnyView) -> Styled

    @State private var completer = LocationSearchCompleter()
    @FocusState private var hasFocus: Bool
    /// Set while a picked suggestion is written into the field, so that write
    /// doesn't search again and leave a stale list for the next focus.
    @State private var isFilling = false

    init(_ placeholder: String, text: Binding<String>, @ViewBuilder style: @escaping (AnyView) -> Styled) {
        self.placeholder = placeholder
        _text = text
        self.style = style
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            style(AnyView(
                TextField(placeholder, text: $text)
                    .focused($hasFocus)
            ))
            .onChange(of: text) { _, new in
                if isFilling { isFilling = false } else { completer.search(new) }
            }
            // Clear (not just hide) on blur, so an old list doesn't flash back
            // the moment focus returns.
            .onChange(of: hasFocus) { _, isFocused in
                if !isFocused { completer.clear() }
            }
            if hasFocus && !completer.results.isEmpty {
                suggestions
            }
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(completer.results.enumerated()), id: \.offset) { index, result in
                Button { pick(result) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                            .lineLimit(1)
                        if !result.subtitle.isEmpty {
                            Text(result.subtitle)
                                .font(.system(size: 12))
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < completer.results.count - 1 {
                    Divider().padding(.leading, 12)
                }
            }
        }
        .background(AppColors.elevated(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func pick(_ result: MKLocalSearchCompletion) {
        let place = result.subtitle.isEmpty ? result.title : "\(result.title), \(result.subtitle)"
        if place != text { isFilling = true }
        text = place
        completer.clear()
        hasFocus = false
    }
}

extension LocationSearchField where Styled == AnyView {
    /// A plain field, as in a Form row.
    init(_ placeholder: String, text: Binding<String>) {
        self.init(placeholder, text: text) { $0 }
    }
}
