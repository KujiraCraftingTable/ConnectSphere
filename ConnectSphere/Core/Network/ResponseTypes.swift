import Foundation

// MARK: - Generic response wrappers matching backend JSON shapes

struct PaginatedResponse<T: Decodable>: Decodable {
    let data: [T]
    let pagination: Pagination

    struct Pagination: Decodable {
        let total: Int
        let limit: Int
        let offset: Int
    }
}

/// Keyset-cursor pagination (used for the personalized newsfeed).
/// `nextCursor` = null means there are no more pages.
struct CursorResponse<T: Decodable>: Decodable {
    let data: [T]
    let nextCursor: String?
}

struct SingleResponse<T: Decodable>: Decodable {
    let data: T
}

struct DataListResponse<T: Decodable>: Decodable {
    let data: [T]
}

struct DataResponse<T: Decodable>: Decodable {
    let data: T
}

struct OKResponse: Decodable {
    let status: String
}

struct ErrorResponse: Decodable {
    let message: String
}
