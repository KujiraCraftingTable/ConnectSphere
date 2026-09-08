import SQLKit

extension SQLQueryString {
    /// Bind a Swift `String` id and cast it to `uuid` in one step. The Node `pg`
    /// driver casts `text` → `uuid` implicitly; PostgresNIO does not, so every
    /// `<uuid column> = <String>` comparison needs the explicit `::uuid`.
    mutating func appendInterpolation(uuid value: String) {
        appendInterpolation(bind: value)
        appendLiteral("::uuid")
    }

    /// Bind an optional `String` id as `uuid` (NULL-safe).
    mutating func appendInterpolation(uuid value: String?) {
        appendInterpolation(bind: value)
        appendLiteral("::uuid")
    }
}
