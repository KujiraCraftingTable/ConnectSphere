import Vapor

extension Request {
    /// `?limit=` kept inside 1...`max`. Postgres rejects a negative LIMIT/OFFSET
    /// with an error (a 500), so every list route reads these through here.
    func pageLimit(default def: Int, max hi: Int) -> Int {
        PostsController.clamp(try? query.get(Int.self, at: "limit"), def, 1, hi)
    }

    /// `?offset=`, never negative.
    var pageOffset: Int {
        max((try? query.get(Int.self, at: "offset")) ?? 0, 0)
    }
}
