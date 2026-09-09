import Foundation

// MARK: - Generic response wrappers matching backend JSON shapes

/// Decodes a JSON array element-by-element, dropping any element that fails to
/// decode rather than failing the whole array. Used for list-page payloads so
/// one malformed row can't blank an entire feed / notification page.
private struct _AnyDecodableSkip: Decodable {}

struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var out: [Element] = []
        if let count = container.count { out.reserveCapacity(count) }
        while !container.isAtEnd {
            if let el = try? container.decode(Element.self) {
                out.append(el)
            } else {
                _ = try? container.decode(_AnyDecodableSkip.self)   // consume the bad element
            }
        }
        elements = out
    }
}

struct PaginatedResponse<T: Decodable>: Decodable {
    let data: [T]
    let pagination: Pagination

    struct Pagination: Decodable {
        let total: Int
        let limit: Int
        let offset: Int
    }

    enum CodingKeys: String, CodingKey { case data, pagination }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = try c.decode(LossyArray<T>.self, forKey: .data).elements
        pagination = try c.decode(Pagination.self, forKey: .pagination)
    }
}

/// Keyset-cursor pagination (used for the personalized newsfeed).
/// `nextCursor` = null means there are no more pages.
struct CursorResponse<T: Decodable>: Decodable {
    let data: [T]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey { case data, nextCursor }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = try c.decode(LossyArray<T>.self, forKey: .data).elements
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
    }
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
