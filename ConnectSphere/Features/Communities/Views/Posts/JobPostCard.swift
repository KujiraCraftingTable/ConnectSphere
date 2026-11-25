import SwiftUI

/// Card body for job-type posts. Shows job details and an "I'm interested"
/// toggle + a Message button that opens a chat with the poster (hidden on
/// your own post, mirroring PostCard's isSelf-gated actions).
struct JobPostCard: View {
    @Environment(AppState.self) var appState
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    @State var vm: JobViewModel

    let poster: UserProfile
    var accentColor: Color

    @State private var chatConversationId: String?
    @State private var navigateToChat = false

    private var isSelf: Bool { poster.id == appState.currentUser?.id }

    /// The pay range (VND million / month) or the poster's own text.
    private var payText: String? {
        if vm.jobData.salaryNegotiable { return bundle.loc("Negotiable") }
        switch (vm.jobData.salaryMin, vm.jobData.salaryMax) {
        case let (lo?, hi?): return String(format: bundle.loc("%lld–%lld million ₫/month"), lo, hi)
        case let (lo?, nil): return String(format: bundle.loc("From %lld million ₫/month"), lo)
        case let (nil, hi?): return String(format: bundle.loc("Up to %lld million ₫/month"), hi)
        default: return vm.jobData.salaryRange?.isEmpty == false ? vm.jobData.salaryRange : nil
        }
    }

    // MARK: - Body
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Job header row
            HStack(spacing: 10) {
                Image(systemName: "briefcase.fill")
                    .scaledFont(16, .medium)
                    .foregroundColor(accentColor)
                    .frame(width: 32, height: 32)
                    .background(accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.jobData.title)
                        .scaledFont(15, .semibold)
                        .foregroundColor(AppColors.textPrimary(colorScheme))

                    if let subtitle {
                        Text(subtitle)
                            .scaledFont(13)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                }
                Spacer()
            }

            if let location = vm.jobData.location, !location.isEmpty {
                Label(bundle.address(location), systemImage: "mappin.circle")
                    .scaledFont(13)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }

            if let pay = payText {
                Label(pay, systemImage: "dollarsign.circle")
                    .scaledFont(13)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }

            if let deadline = vm.jobData.applicationDeadline {
                Label(String(format: bundle.loc("Apply by %@"), formattedDeadline(deadline)), systemImage: "calendar.badge.clock")
                    .scaledFont(13)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }

            NavigationLink { JobDetailView(jobId: vm.jobData.id) { _ in } } label: {
                Label(bundle.loc("View job"), systemImage: "briefcase")
                    .scaledFont(13, .semibold)
            }

            // Actions
            HStack(spacing: 8) {
                interestedButton
                if !isSelf {
                    messageButton
                }
                Spacer()
                Text(String(format: bundle.loc("%d interested"), vm.jobData.interestedCount))
                    .scaledFont(12)
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }

            if let err = vm.errorMessage {
                Text(err).scaledFont(12).foregroundColor(.red)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .navigationDestination(isPresented: $navigateToChat) {
            if let convId = chatConversationId {
                ChatView(
                    conversationId: convId,
                    peer: .direct(otherUserId: poster.id, name: poster.name,
                                  avatarColor: poster.avatarColor, avatarUrl: poster.avatarUrl),
                    otherUserLocation: poster.location,
                    currentUserId: appState.currentUser?.id ?? "",
                    token: appState.authToken ?? ""
                )
            }
        }
    }

    private var subtitle: String? {
        let parts = [vm.jobData.company, vm.jobData.employmentType.map { bundle.loc($0.label) }]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Buttons
    private var interestedButton: some View {
        let isActive = vm.jobData.userInterested
        return Button {
            Task<Void, Never>(name: nil) { await vm.setInterested(!isActive) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "hand.raised")
                    .scaledFont(12)
                Text(bundle.loc(isActive ? "Interested" : "I'm interested"))
                    .scaledFont(12, .medium)
            }
            .foregroundColor(isActive ? .white : AppColors.textSecondary(colorScheme))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isActive ? accentColor : AppColors.elevated(colorScheme))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(vm.isUpdating)
    }

    private var messageButton: some View {
        Button {
            Task<Void, Never>(name: nil) {
                guard let convId = await vm.openConversation(with: poster.id, mode: appState.currentMode) else { return }
                chatConversationId = convId
                navigateToChat = true
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "message")
                    .scaledFont(12)
                Text("Message", bundle: bundle)
                    .scaledFont(12, .medium)
            }
            .foregroundColor(AppColors.textSecondary(colorScheme))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(AppColors.elevated(colorScheme))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(vm.isOpeningChat)
    }

    // MARK: - Formatting
    private func formattedDeadline(_ date: Date) -> String {
        let isVi = (AppDefaults.store.string(forKey: "appLanguage") ?? "vi") == "vi"
        let df = DateFormatter()
        df.locale = Locale(identifier: isVi ? "vi_VN" : "en_US")
        df.dateFormat = "MMM d, yyyy"
        return df.string(from: date)
    }
}
