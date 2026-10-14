import Foundation

/// A Hobby profile highlight: titled photos that stay until removed one by one.
struct Highlight: Identifiable, Decodable, Hashable {
    let id: String
    let title: String
    let coverUrl: String
    let items: [Item]

    struct Item: Identifiable, Decodable, Hashable {
        let id: String
        let imageUrl: String
        let createdAt: Date
        enum CodingKeys: String, CodingKey {
            case id
            case imageUrl = "image_url"
            case createdAt = "created_at"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, title, items
        case coverUrl = "cover_url"
    }

    static let titleLimit = 30
}
