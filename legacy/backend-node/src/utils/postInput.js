// ─── Post input normalization ────────────────────────────────────────────────
// Shared by Feed's POST /api/posts and Communities' POST /api/communities/:id/
// posts so image_urls validation never drifts between the two creation paths.

// Filters a raw image_urls array down to non-empty strings, capped at 10
// (matches Feed's existing cap). Returns null when nothing valid remains, so
// callers can pass the result straight through to the DB layer.
function normalizeImageUrls(raw) {
  if (!Array.isArray(raw)) return null;
  const urls = raw.filter((u) => typeof u === 'string' && u.trim()).slice(0, 10);
  return urls.length > 0 ? urls : null;
}

module.exports = { normalizeImageUrls };
