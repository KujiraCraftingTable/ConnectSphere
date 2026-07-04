import Foundation

/// Domain model for a pending request to join a private community
struct JoinRequest: Identifiable {
    let id: String
    let user: JoinRequestUser
    let requestedAt: Date
    let status: String
}

/// User info embedded in a join request
struct JoinRequestUser: Identifiable {
    let id: String
    let username: String
    let displayName: String
    let avatarColor: String
}
