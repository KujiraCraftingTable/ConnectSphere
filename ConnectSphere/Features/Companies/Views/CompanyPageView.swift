import SwiftUI

/// A company's official page: cover, logo, name (✓ Official once verified),
/// what it is, Follow, then About | Jobs | People. Its admins get Edit.
struct CompanyPageView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @State private var browserURL: URL?

    @State private var viewModel: CompanyPageViewModel
    @State private var tab: Tab = .about
    @State private var showEditor = false
    @State private var showReport = false
    var onChanged: ((Company) -> Void)? = nil

    enum Tab: Hashable { case about, jobs, people }

    init(companyId: String, preloaded: Company? = nil, onChanged: ((Company) -> Void)? = nil) {
        _viewModel = State(initialValue: CompanyPageViewModel(companyId: companyId, preloaded: preloaded))
        self.onChanged = onChanged
    }

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        ScrollView {
            if let company = viewModel.company {
                VStack(alignment: .leading, spacing: 0) {
                    header(company)
                    Picker("", selection: $tab) {
                        Text("About", bundle: bundle).tag(Tab.about)
                        Text("Jobs", bundle: bundle).tag(Tab.jobs)
                        Text("People", bundle: bundle).tag(Tab.people)
                    }
                    .pickerStyle(.segmented)
                    .padding(16)
                    switch tab {
                    case .about: about(company)
                    case .jobs:
                        CompanyJobsList(companyId: company.id)
                    case .people:
                        CompanyPeopleList(companyId: company.id)
                    }
                }
            } else if viewModel.isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 300)
            } else if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .frame(maxWidth: .infinity, minHeight: 300)
            }
        }
        .background(AppColors.base(colorScheme))
        .navigationTitle(viewModel.company?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if viewModel.company?.isAdmin == true {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(bundle.loc("Edit")) { showEditor = true }
                }
            } else if viewModel.company != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showReport = true } label: {
                            Label(bundle.loc("Report page"), systemImage: "flag")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
        }
        .sheet(isPresented: $showReport) {
            if let company = viewModel.company {
                ReportSheet(subject: .content(.company, id: company.id))
                    .environment(themeManager)
            }
        }
        .sheet(isPresented: $showEditor) {
            CompanyEditorView(editing: viewModel.company) { saved in
                viewModel.replace(with: saved)
                onChanged?(saved)
            }
        }
        .task { await viewModel.load(token: token) }
        .inAppBrowser(url: $browserURL)
    }

    private func header(_ company: Company) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let cover = company.coverUrl.flatMap(APIConfig.mediaURL) {
                        RemoteImage(url: cover) { phase in
                            if let image = phase.image { image.resizable().scaledToFill() }
                            else { coverFallback }
                        }
                    } else {
                        coverFallback
                    }
                }
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .clipped()

                Avatar(name: company.name, imageURL: company.logoUrl, diameter: 84, shape: .roundedSquare)
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppColors.surface(colorScheme), lineWidth: 4))
                    .offset(x: 16, y: 42)
            }
            .padding(.bottom, 42)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(company.name)
                        .scaledFont(22, .bold)
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                    if company.isVerified { OfficialBadge() }
                }
                let summary = company.summary { String(format: bundle.loc("%@ employees"), $0) }
                if !summary.isEmpty {
                    Text(summary)
                        .scaledFont(14)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                Text(String(format: bundle.loc(company.followerCount == 1 ? "%lld follower" : "%lld followers"),
                            company.followerCount))
                    .scaledFont(13)
                    .foregroundColor(AppColors.textTertiary(colorScheme))

                Button {
                    Task { await viewModel.toggleFollow(token: token) }
                } label: {
                    Label(bundle.loc(company.isFollowing ? "Following" : "Follow"),
                          systemImage: company.isFollowing ? "checkmark" : "plus")
                        .scaledFont(15, .semibold)
                        .foregroundColor(company.isFollowing ? AppColors.textPrimary(colorScheme) : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(company.isFollowing ? AnyShapeStyle(AppColors.elevated(colorScheme))
                                                        : AnyShapeStyle(themeManager.theme.primary),
                                    in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 4)
        .background(AppColors.surface(colorScheme))
    }

    private var coverFallback: some View {
        LinearGradient(colors: [themeManager.theme.primary.opacity(0.55), themeManager.theme.primary.opacity(0.2)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func about(_ company: Company) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let about = company.about {
                Text(about)
                    .scaledFont(15)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let site = company.website, let url = URL(string: site) {
                detail("globe", bundle.loc("Website")) {
                    Button(url.host ?? site) { browserURL = url }
                        .foregroundColor(themeManager.theme.primary)
                }
            }
            if let industry = company.industry { detail("building.2", bundle.loc("Industry")) { Text(industry) } }
            if let size = company.size {
                detail("person.3", bundle.loc("Company size")) { Text(String(format: bundle.loc("%@ employees"), size)) }
            }
            if let hq = company.headquarters { detail("mappin.and.ellipse", bundle.loc("Headquarters")) { Text(hq) } }
            if let year = company.foundedYear { detail("calendar", bundle.loc("Founded")) { Text(String(year)) } }
            if company.about == nil && company.website == nil && company.industry == nil
                && company.size == nil && company.headquarters == nil && company.foundedYear == nil {
                Text("No details yet.", bundle: bundle)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
    }

    private func detail<V: View>(_ icon: String, _ label: String, @ViewBuilder value: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundColor(AppColors.textTertiary(colorScheme))
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .scaledFont(12)
                    .foregroundColor(AppColors.textTertiary(colorScheme))
                value()
                    .scaledFont(15)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
            }
        }
    }

    private func emptyTab(icon: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .scaledFont(30)
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text(text)
                .scaledFont(14)
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

/// "✓ Official" next to a verified company's name, and next to the official
/// @connectsphere account wherever its name appears.
struct OfficialBadge: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    var compact = false

    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.system(size: compact ? 13 : 17))
            .foregroundStyle(.white, themeManager.theme.primary)
            .accessibilityLabel(Text(bundle.loc("Official")))
    }
}

/// A company in a list: logo, name (✓), what it is, followers.
struct CompanyRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appBundle) private var bundle
    let company: Company

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: company.name, imageURL: company.logoUrl, size: .lg, shape: .roundedSquare)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(company.name)
                        .scaledFont(16, .semibold)
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .lineLimit(1)
                    if company.isVerified { OfficialBadge(compact: true) }
                }
                let summary = company.summary { String(format: bundle.loc("%@ employees"), $0) }
                if !summary.isEmpty {
                    Text(summary)
                        .scaledFont(13)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                        .lineLimit(1)
                }
                Text(String(format: bundle.loc(company.followerCount == 1 ? "%lld follower" : "%lld followers"),
                            company.followerCount))
                    .scaledFont(12)
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: 14))
    }
}
