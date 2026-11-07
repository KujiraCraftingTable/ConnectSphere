import Foundation
import Observation

/// The signed-in user's chat spaces for one mode. Messages and a chat's
/// settings each own one and reload on appear, so a change made in one
/// screen shows in the other.
@MainActor
@Observable
final class SpacesViewModel {
    private(set) var spaces: [ChatSpace] = []
    private(set) var hasLoaded = false
    private(set) var isSaving = false
    var error: String?

    private let repository = SpaceRepository()

    func load(mode: String, token: String) async {
        do {
            spaces = try await repository.list(mode: mode, token: token)
            hasLoaded = true
        } catch {
            // No alert: the inbox already shows the connection error inline with
            // Retry, and an alert on top made the user dismiss it to reach Retry.
            // The spaces bar just stays empty until the next load.
            #if DEBUG
            print("Spaces load failed: \(error)")
            #endif
        }
    }

    /// Spaces this person is in, in display order.
    func spaces(containing userId: String) -> [ChatSpace] {
        spaces.filter { $0.contains(userId) }
    }

    /// Spaces this chat sits in. By its group, or by the other person.
    func spaces(for conversation: Conversation) -> [ChatSpace] {
        spaces.filter { $0.contains(conversation) }
    }

    /// Spaces this group chat is in.
    func spaces(containingGroup conversationId: String) -> [ChatSpace] {
        spaces.filter { $0.containsGroup(conversationId) }
    }

    @discardableResult
    func create(name: String, color: SpaceColor, memberIds: [String] = [], groupIds: [String] = [],
                mode: String, token: String) async -> ChatSpace? {
        await save {
            let space = try await repository.create(name: name, color: color, mode: mode, memberIds: memberIds,
                                                    groupIds: groupIds, token: token)
            spaces.append(space)
            return space
        }
    }

    func update(_ space: ChatSpace, name: String, color: SpaceColor, token: String) async -> Bool {
        let changedName = name == space.name ? nil : name
        let changedColor = color == space.color ? nil : color
        guard changedName != nil || changedColor != nil else { return true }
        return await save {
            replace(try await repository.update(space.id, name: changedName, color: changedColor, token: token))
        } != nil
    }

    func setMembers(_ space: ChatSpace, people memberIds: [String], groups groupIds: [String], token: String) async -> Bool {
        await save {
            replace(try await repository.setMembers(space.id, memberIds: memberIds, groupIds: groupIds, token: token))
        } != nil
    }

    /// Puts this person in or takes them out of one space (chat settings checklist).
    func setMembership(of userId: String, in space: ChatSpace, isMember: Bool, token: String) async {
        _ = await save {
            replace(isMember
                ? try await repository.addMember(space.id, userId: userId, token: token)
                : try await repository.removeMember(space.id, userId: userId, token: token))
        }
    }

    /// Puts this group chat in or takes it out of one space (group settings checklist).
    func setGroupMembership(of conversationId: String, in space: ChatSpace, isMember: Bool, token: String) async {
        _ = await save {
            replace(isMember
                ? try await repository.addGroup(space.id, conversationId: conversationId, token: token)
                : try await repository.removeGroup(space.id, conversationId: conversationId, token: token))
        }
    }

    func delete(_ space: ChatSpace, token: String) async {
        let before = spaces
        spaces.removeAll { $0.id == space.id }      // optimistic: it disappears at once
        do {
            try await repository.delete(space.id, token: token)
        } catch {
            spaces = before
            self.error = Self.message(for: error)
        }
    }

    // MARK: Private

    @discardableResult
    private func replace(_ updated: ChatSpace) -> ChatSpace {
        if let index = spaces.firstIndex(where: { $0.id == updated.id }) { spaces[index] = updated }
        return updated
    }

    private func save<T>(_ work: () async throws -> T) async -> T? {
        isSaving = true
        defer { isSaving = false }
        do {
            return try await work()
        } catch {
            self.error = Self.message(for: error)
            return nil
        }
    }

    /// Server reasons ("You already have a space with that name") are English
    /// keys with Vietnamese entries in the strings files.
    private static func message(for error: Error) -> String {
        Bundle.app.loc(friendlyError(error))
    }
}
