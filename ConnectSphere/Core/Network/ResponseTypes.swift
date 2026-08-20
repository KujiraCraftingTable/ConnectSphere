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

/// Phân trang bằng keyset cursor (dùng cho personalized newsfeed).
/// `nextCursor` = null nghĩa là hết trang.
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
