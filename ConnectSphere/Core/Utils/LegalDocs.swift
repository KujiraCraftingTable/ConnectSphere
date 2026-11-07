import Foundation

/// Which edition of the Terms of Service and Privacy Policy (`StaticInfoView`)
/// this build shows. Bump it together with `LegalDocs.version` on the server
/// whenever those texts change in a way people must agree to again.
enum LegalDocs {
    static let version = "2026-11-07"
}
