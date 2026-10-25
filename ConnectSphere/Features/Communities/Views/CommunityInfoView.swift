import SwiftUI

/// "About this community": opened by tapping the community's name.
struct CommunityInfoView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    let community: Community
    /// "See all" members — the page switches to its Members tab.
    let onSeeAllMembers: () -> Void
    @State private var viewModel: CommunityInfoViewModel

    init(community: Community, onSeeAllMembers: @escaping () -> Void) {
        self.community = community
        self.onSeeAllMembers = onSeeAllMembers
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
    }

    private func aboutSection(_ info: CommunityInfo) -> some View {
        Section {
            if let about = info.about, !about.isEmpty {
                Text(about).font(.system(size: 15))
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

    private func membersSection(_ info: CommunityInfo) -> some View {
        Section {
            if !info.friends.isEmpty, let line = viewModel.friendsLine {
                VStack(alignment: .leading, spacing: 8) {
                    avatarStack(info.friends)
                    Text(line).font(.system(size: 14)).foregroundColor(AppColors.textSecondary(colorScheme))
                }
                .padding(.vertical, 4)
            }
            if !info.staff.isEmpty, let line = viewModel.staffLine {
                VStack(alignment: .leading, spacing: 8) {
                    avatarStack(Array(info.staff.prefix(3)))
                    Text(line).font(.system(size: 14)).foregroundColor(AppColors.textSecondary(colorScheme))
                }
                .padding(.vertical, 4)
            }
            Text(String(format: bundle.loc("%lld members"), info.memberCount))
                .font(.system(size: 14))
        } header: {
            HStack {
                Text("Members", bundle: bundle)
                Spacer()
                Button(bundle.loc("See all")) {
                    onSeeAllMembers()
                    dismiss()
                }
                .font(.system(size: 14))
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
                .font(.system(size: 18))
                .frame(width: 26)
                .foregroundColor(AppColors.textPrimary(colorScheme))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundColor(AppColors.textSecondary(colorScheme))
            }
        }
        .padding(.vertical, 2)
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
