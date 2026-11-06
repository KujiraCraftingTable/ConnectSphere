import SwiftUI

/// "About this community": opened by tapping the community's name.
struct CommunityInfoView<Members: View>: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.openURL) private var openURL
    @State private var inAppBrowserURL: URL?

    let community: Community
    /// The members the community page has loaded, for the latest-joined row.
    let roster: [CommunityMember]
    /// What "See all" opens, the only way to the full list.
    @ViewBuilder let members: () -> Members
    @State private var viewModel: CommunityInfoViewModel

    init(community: Community, roster: [CommunityMember], @ViewBuilder members: @escaping () -> Members) {
        self.community = community
        self.roster = roster
        self.members = members
        _viewModel = State(initialValue: CommunityInfoViewModel(communityId: community.id))
    }

    var body: some View {
        List {
            if let info = viewModel.info {
                aboutSection(info)
                membersSection(info)
                activitySection(info)
            } else if let error = viewModel.errorMessage {
                Text(error).foregroundColor(AppColors.danger(colorScheme))
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(community.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load(token: appState.authToken ?? "") }
        .refreshable { await viewModel.load(token: appState.authToken ?? "") }
        .inAppBrowser(url: $inAppBrowserURL)
    }

    private func aboutSection(_ info: CommunityInfo) -> some View {
        Section {
            if let about = info.about, !about.isEmpty {
                Text(info.aboutFormat == "markdown"
                     ? MarkdownFormatter.attributed(about, linkColor: themeManager.theme.primary,
                                                    quoteColor: AppColors.textSecondary(colorScheme))
                     : AttributedString(about))
                    .scaledFont(15)
                    .environment(\.openURL, OpenURLAction { url in
                        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                            inAppBrowserURL = url
                        } else {
                            openURL(url)
                        }
                        return .handled
                    })
            }
            if info.privacy == "private" {
                fact("lock.fill", bundle.loc("Private"), bundle.loc("Only members can see who's in the community and what they post."))
                fact("eye.slash", bundle.loc("Hidden"), bundle.loc("It doesn't show up in Discover or search; people join by request."))
            } else {
                fact("globe", bundle.loc("Public"), bundle.loc("Anyone can see who's in the community and what they post."))
                fact("eye", bundle.loc("Visible"), bundle.loc("Anyone can find this community."))
            }
            fact("clock", bundle.loc("History"), historyText(info))
        } header: {
            Text("About", bundle: bundle)
        }
    }

    /// One box: the admins and moderators, then your connections who joined
    /// (or the latest to join). A private community shows only who runs it.
    private func membersSection(_ info: CommunityInfo) -> some View {
        Section {
            if !info.staff.isEmpty, let line = viewModel.staffLine {
                peopleRow(Array(info.staff.prefix(5)), line)
            }
            if community.privacy != .private,
               let others = viewModel.otherMembers(roster: roster, viewerId: appState.currentUser?.id ?? "") {
                peopleRow(others.people, others.line)
            }
        } header: {
            HStack {
                Text("Members", bundle: bundle)
                Spacer()
                NavigationLink(bundle.loc("See all"), destination: members)
                    .scaledFont(14)
                .textCase(nil)
            }
        }
    }

    private func activitySection(_ info: CommunityInfo) -> some View {
        Section {
            fact("text.bubble", String(format: bundle.loc("%lld new posts today"), info.postsToday),
                 String(format: bundle.loc("%lld in the last week"), info.postsWeek))
            fact("person.2", String(format: bundle.loc("%lld members in total"), info.memberCount),
                 String(format: bundle.loc("+%lld in the last week"), info.newMembersWeek))
        } header: {
            Text("Activity", bundle: bundle)
        }
    }

    private func historyText(_ info: CommunityInfo) -> String {
        let created = String(format: bundle.loc("Created on %@."),
                             info.createdAt.formatted(date: .long, time: .omitted))
        guard let renamed = info.nameChangedAt else { return created }
        return created + " " + String(format: bundle.loc("Name last changed on %@."),
                                      renamed.formatted(date: .long, time: .omitted))
    }

    private func fact(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .scaledFont(18)
                .frame(width: 26)
                .foregroundColor(AppColors.textPrimary(colorScheme))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaledFont(15, .semibold)
                Text(detail).scaledFont(13).foregroundColor(AppColors.textSecondary(colorScheme))
            }
        }
        .padding(.vertical, 2)
    }

    private func peopleRow(_ people: [CommunityInfo.Person], _ line: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            avatarStack(people)
            Text(line).scaledFont(14).foregroundColor(AppColors.textSecondary(colorScheme))
        }
        .padding(.vertical, 4)
    }

    private func avatarStack(_ people: [CommunityInfo.Person]) -> some View {
        HStack(spacing: -10) {
            ForEach(people) { person in
                Avatar(name: person.displayName, colorHex: person.avatarColor, imageURL: person.avatarUrl, diameter: 36)
                    .overlay(Circle().stroke(AppColors.surface(colorScheme), lineWidth: 2))
            }
        }
    }
}
