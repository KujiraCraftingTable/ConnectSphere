import Foundation
import Observation

/// Backs `GroupParticipantsView`, adapted from `CommunityDetailViewModel`'s
/// member-management section (`members`/`fetchMembers`/`kickMember`/
/// `updateRole`), simplified from Communities' 3-tier admin/moderator/member
/// to this feature's 2-tier owner/member model.
@MainActor
@Observable
class GroupParticipantsViewModel {
    var members: [GroupMember] = []
    var isLoading = false
    var error: String?
    /// Set once I leave the group, `GroupParticipantsView` dismisses itself
    /// when this flips, and a `.userLeftGroupConversation` notification lets
    /// the screens underneath (`ChatSettingsView`, `ChatView`) navigate out too.
    var didLeave = false

    private let conversationId: String
    private let token: String
    private let repository = MessageRepository()

    init(conversationId: String, token: String) {
        self.conversationId = conversationId
        self.token = token
    }

    func fetchMembers() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let settings = try await repository.fetchSettings(conversationId: conversationId, token: token)
            members = settings.members
        } catch {
            self.error = friendlyError(error)
        }
    }

    /// Owner-only server-side: remove a member from the group.
    func kickMember(_ userId: String) async {
        do {
            let settings = try await repository.removeMember(conversationId: conversationId, userId: userId, token: token)
            members = settings.members
        } catch {
            self.error = friendlyError(error)
        }
    }

    /// Owner-only server-side: promote another member to owner. Transfers
    /// away my own owner role, so the confirmation lives in the view.
    func promoteToOwner(_ userId: String) async {
        do {
            let settings = try await repository.promoteOwner(conversationId: conversationId, userId: userId, token: token)
            members = settings.members
        } catch {
            self.error = friendlyError(error)
        }
    }

    /// Add members to the group (owner-only server-side).
    func addMembers(_ memberIds: [String]) async {
        do {
            let settings = try await repository.addMembers(conversationId: conversationId, memberIds: memberIds, token: token)
            members = settings.members
        } catch {
            self.error = Bundle.app.loc(friendlyError(error))
        }
    }

    /// Any member may leave. Posts `.userLeftGroupConversation` (mirroring the
    /// existing `.userBlockStatusChanged` cross-screen sync pattern) so
    /// `ChatSettingsView`/`ChatView`, still open underneath this pushed
    /// screen, navigate back out together instead of each needing a
    /// hand-threaded completion callback.
    func leaveGroup() async {
        do {
            try await repository.leaveGroup(conversationId: conversationId, token: token)
            didLeave = true
            NotificationCenter.default.post(
                name: .userLeftGroupConversation, object: nil,
                userInfo: ["conversationId": conversationId]
            )
        } catch {
            self.error = friendlyError(error)
        }
    }
}
