// Escape a user-supplied term for use inside a LIKE/ILIKE pattern, so a literal
// '%' or '_' in the input matches literally instead of acting as a wildcard
// (and can't force a full scan). Backslash is Postgres's default LIKE escape
// char, so no explicit ESCAPE clause is needed.
function escapeLike(term) {
  return String(term).replace(/[\\%_]/g, '\\$&');
}

module.exports = { escapeLike };
