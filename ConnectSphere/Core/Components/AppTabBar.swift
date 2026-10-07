import SwiftUI

/// Who wants the bottom bar hidden right now (e.g. a chat with its own input
/// bar). A count, not a flag, so stacked screens can each hide it.
@MainActor
@Observable
final class AppTabBarVisibility {
    fileprivate(set) var hiddenCount = 0
    var isHidden: Bool { hiddenCount > 0 }
}

extension View {
    /// Hides the app's bottom bar while this screen is on screen. Also hides
    /// the system tab bar, which iOS < 26 still uses.
    func hidesAppTabBar() -> some View {
        modifier(HidesAppTabBar())
    }
}

private struct HidesAppTabBar: ViewModifier {
    @Environment(AppTabBarVisibility.self) private var visibility: AppTabBarVisibility?

    func body(content: Content) -> some View {
        content
            .toolbar(.hidden, for: .tabBar)
            .onAppear { visibility?.hiddenCount += 1 }
            .onDisappear { visibility.map { $0.hiddenCount = max(0, $0.hiddenCount - 1) } }
    }
}

/// The bottom bar on iOS 26+: a Liquid Glass pill with the main tabs and,
/// beside it, a separate round Search button (Telegram-style). The system tab
/// bar keeps Search inside the pill on iPhone, so this draws its own.
@available(iOS 26.0, *)
struct AppTabBar: View {
    struct Item: Identifiable {
        let value: Int
        let icon: String
        let selectedIcon: String
        let title: LocalizedStringKey
        var badge = 0
        var id: Int { value }
    }

    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    /// Set on every tap, including re-tapping the current tab (resets it).
    @Binding var selection: Int
    let items: [Item]
    let searchValue: Int
    let accent: Color

    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                ForEach(items) { tabButton($0) }
            }
            .padding(6)
            .glassEffect(.regular.interactive(), in: Capsule())

            Button { selection = searchValue } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(selection == searchValue ? accent : Color.primary)
                    .frame(width: 62, height: 62)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel(Text("Search", bundle: bundle))
            .accessibilityAddTraits(selection == searchValue ? .isSelected : [])
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: selection)
    }

    private func tabButton(_ item: Item) -> some View {
        let isSelected = selection == item.value
        return Button { selection = item.value } label: {
            Image(systemName: isSelected ? item.selectedIcon : item.icon)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(isSelected ? accent : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.08))
                            .matchedGeometryEffect(id: "selected", in: highlight)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if item.badge > 0 {
                        Text(item.badge > 99 ? "99+" : "\(item.badge)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Color.red, in: Capsule())
                            .offset(x: -10, y: 2)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(item.title, bundle: bundle))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
