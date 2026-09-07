// ─── Persona SQL helpers ──────────────────────────────────────────────────────
// Each account has 2 independent display identities per mode (hobby_*/work_*
// columns on the users table). modeRef is the SQL expression for the mode: a
// parameter ('$2'), a column ('p.mode', 'c.mode'), or a literal ("'hobby'") —
// NEVER raw client input (mode is always validated as 'hobby'/'work' in the
// controller first).
//
//  • personaExpr(field): expression that picks one field by mode. display_name
//    has a COALESCE to the base column (name is never empty); bio/avatar/cover
//    have NO fallback — NULL = the persona hasn't set that field → the client
//    shows a default, so it never leaks that field from the other mode's persona.
//  • personaCols: the 4 identity columns (AS display_name/bio/avatar_url/cover_url)
//  • personaSetupClause: whether the user has set up that mode's persona yet (= has a display_name)

const personaExpr = (field, modeRef, alias = 'u') => {
  const expr = `CASE WHEN ${modeRef} = 'work' THEN ${alias}.work_${field} ELSE ${alias}.hobby_${field} END`;
  return field === 'display_name' ? `COALESCE(${expr}, ${alias}.display_name)` : expr;
};

const personaCols = (modeRef, alias = 'u') => `
    ${personaExpr('display_name', modeRef, alias)} AS display_name,
    ${personaExpr('bio', modeRef, alias)}          AS bio,
    ${personaExpr('avatar_url', modeRef, alias)}   AS avatar_url,
    ${personaExpr('cover_url', modeRef, alias)}    AS cover_url`;

const personaSetupClause = (modeRef, alias = 'u') =>
  `(CASE WHEN ${modeRef} = 'work' THEN ${alias}.work_display_name ELSE ${alias}.hobby_display_name END) IS NOT NULL`;

module.exports = { personaExpr, personaCols, personaSetupClause };
