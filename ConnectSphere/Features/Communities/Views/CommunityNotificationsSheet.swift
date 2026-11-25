import SwiftUI

/// "..." › Manage notifications: which new posts in this community notify you.
struct CommunityNotificationsSheet: View {
    @Environment(\.appBundle) private var bundle
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var themeManager

    let viewModel: CommunityDetailViewModel

    private var current: CommunityNotifyLevel { viewModel.community?.notifyLevel ?? .friends }

    // MARK: - Body
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(CommunityNotifyLevel.allCases, id: \.self) { level in
                        Button { Task { await viewModel.setNotifyLevel(level) } } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: icon(level)).frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bundle.loc(title(level))).scaledFont(16)
                                    Text(bundle.loc(detail(level)))
                                        .scaledFont(13)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if current == level {
                                    Image(systemName: "checkmark").foregroundColor(themeManager.theme.primary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Connections are the people you're connected with in this community's mode.", bundle: bundle)
                }
            }
            .navigationTitle(bundle.loc("Manage notifications"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(bundle.loc("Done")) { dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Level text
    private func icon(_ level: CommunityNotifyLevel) -> String {
        switch level {
        case .all: "bell.badge"
        case .friends: "person.2"
        case .off: "bell.slash"
        }
    }

    private func title(_ level: CommunityNotifyLevel) -> String {
        switch level {
        case .all: "All posts"
        case .friends: "Friends' posts"
        case .off: "Off"
        }
    }

    private func detail(_ level: CommunityNotifyLevel) -> String {
        switch level {
        case .all: "Every new post in this community."
        case .friends: "Only when one of your connections posts here."
        case .off: "No notifications about new posts here."
        }
    }
}
