import Foundation

/// Port of `backend/src/utils/personaSql.js`. Builds raw SQL fragments that pick
/// a user's per-mode identity column (`hobby_*` / `work_*`). `modeRef` is a
/// trusted SQL expression — a column (`u.default_mode`, `p.mode`), a bound
/// placeholder written by the caller, or a quoted literal (`'hobby'`). Never
/// raw client input (mode is validated to hobby/work in the controller first).
///
/// Inject with SQLKit's `\(unsafeRaw:)` interpolation.
enum PersonaSQL {
    /// Expression that selects one field by mode. `display_name` gets a
    /// COALESCE to the base column (name is never empty); bio/avatar/cover have
    /// NO fallback so an unset persona field never leaks the other mode's value.
    static func expr(_ field: String, modeRef: String, alias: String = "u") -> String {
        let e = "CASE WHEN \(modeRef) = 'work' THEN \(alias).work_\(field) ELSE \(alias).hobby_\(field) END"
        return field == "display_name" ? "COALESCE(\(e), \(alias).display_name)" : e
    }

    /// The 4 identity columns aliased as display_name/bio/avatar_url/cover_url.
    static func cols(modeRef: String, alias: String = "u") -> String {
        """
        \(expr("display_name", modeRef: modeRef, alias: alias)) AS display_name,
        \(expr("bio", modeRef: modeRef, alias: alias))          AS bio,
        \(expr("avatar_url", modeRef: modeRef, alias: alias))   AS avatar_url,
        \(expr("cover_url", modeRef: modeRef, alias: alias))    AS cover_url
        """
    }

    /// Whether the user has set up that mode's persona yet (has a display_name).
    static func setupClause(modeRef: String, alias: String = "u") -> String {
        "(CASE WHEN \(modeRef) = 'work' THEN \(alias).work_display_name ELSE \(alias).hobby_display_name END) IS NOT NULL"
    }
}
