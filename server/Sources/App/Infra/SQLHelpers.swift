import SQLKit
import Foundation

/// Postgres SQLSTATE checks. PostgresNIO's error type has churned across
/// versions; matching the SQLSTATE in the error's description is version-proof
/// and good enough for the "map a known DB error to an HTTP status" cases the
/// Node backend handles (`23505` → 409, etc.).
enum PGError {
    static func sqlState(_ error: any Error, is code: String) -> Bool {
        let s = String(reflecting: error)
        return s.contains("sqlState: \(code)")
            || s.contains("sqlState: \"\(code)\"")
            || s.contains("(code) \(code)")
    }
    static func isUniqueViolation(_ error: any Error) -> Bool { sqlState(error, is: "23505") }
}

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
