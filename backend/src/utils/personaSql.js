// ─── Persona SQL helpers ──────────────────────────────────────────────────────
// Mỗi account có 2 danh tính hiển thị độc lập theo mode (cột hobby_*/work_*
// trên bảng users). modeRef là biểu thức SQL cho mode: tham số ('$2'), cột
// ('p.mode', 'c.mode') hoặc literal ("'hobby'") — KHÔNG bao giờ là input thô
// của client (mode luôn được validate 'hobby'/'work' ở controller trước).
//
//  • personaExpr(field): biểu thức lấy 1 field theo mode. display_name có
//    COALESCE về cột gốc (tên không bao giờ trống); bio/avatar/cover KHÔNG
//    fallback — NULL = persona chưa đặt field đó → client hiển thị mặc định,
//    tránh lộ ảnh/bio của persona mode kia.
//  • personaCols: bộ 4 cột danh tính (AS display_name/bio/avatar_url/cover_url)
//  • personaSetupClause: user đã setup persona của mode chưa (= có display_name)

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
