/**
 * review-location-aliases.js — the data controller for user-submitted location aliases.
 *
 * When a user clarifies "landmark hcmc" → "Landmark 81" in the search warning box,
 * the backend geocodes the clarification. If it resolved, the alias auto-validates
 * (the geocoder is objective proof) and never reaches this script. Only the ones the
 * geocoder could NOT confirm land in 'pending' and wait here for a human decision.
 *
 * Only status='validated' rows are ever readable by search (venueLocationService
 * .findValidatedAlias), so nothing reviewed here can affect users until promoted.
 *
 * Usage:
 *   node scripts/review-location-aliases.js list [--all] [--suggest]
 *   node scripts/review-location-aliases.js validate <id> [--as "<corrected name>"]
 *   node scripts/review-location-aliases.js reject   <id>
 *
 * Options:
 *   --all       list: include validated/rejected rows too, not just pending
 *   --suggest   list: also fetch up to 3 Nominatim candidates per pending row
 *               ("did you mean...?"). Makes live geocode calls — slower than plain list.
 *   --as        validate: try promoting THIS text instead of the stored canonical
 *               (e.g. one of the suggestions), updating canonical to match on success.
 */

require('dotenv').config();
const { Pool } = require('pg');
const { resolveVenueToCity, searchVenueCandidates } = require('../src/services/venueLocationService');
// venueLocationService's toEnglishProvince/findValidatedAlias run through this
// shared pool (config/db.js), separate from the one below — both need closing,
// or Node hangs around for its idle-connection timeout (30s by default) instead
// of exiting once the command is done. Only relevant to this script: every other
// scripts/*.js either opens its own pool and never calls into the service layer,
// or (migrate.js/seed-entities.js) never imports config/db.js at all.
const { pool: appPool } = require('../src/config/db');

const pool = new Pool({
  host:     process.env.DB_HOST,
  port:     parseInt(process.env.DB_PORT, 10),
  database: process.env.DB_NAME,
  user:     process.env.DB_USER,
  password: process.env.DB_PASSWORD,
});

/** "did you mean...?" — shared by `list --suggest` and a failed `validate`. */
function printCandidates(candidates) {
  if (candidates.length === 0) {
    console.log('    (no suggestions found)');
    return;
  }
  candidates.forEach((c, i) => {
    console.log(`    ${i + 1}. "${c.label}"  →  ${c.provinceName}`);
  });
}

/** Pending aliases, most-submitted first — submit_count is the "how many people agree" signal. */
async function list({ all, suggest }) {
  const { rows } = await pool.query(
    `SELECT la.id, la.alias, la.canonical, la.province_name, la.status,
            la.submit_count, la.created_at, u.username AS submitted_by
       FROM location_aliases la
       LEFT JOIN users u ON u.id = la.submitted_by
      ${all ? '' : "WHERE la.status = 'pending'"}
      ORDER BY la.submit_count DESC, la.created_at DESC`
  );

  if (rows.length === 0) {
    console.log(all ? 'No location aliases yet.' : 'Nothing pending review. 🎉');
    return;
  }

  console.log(`\n${rows.length} alias${rows.length === 1 ? '' : 'es'}${all ? '' : ' pending review'}:\n`);
  for (const r of rows) {
    console.log(`  ${r.id}`);
    console.log(`    "${r.alias}"  →  "${r.canonical}"`);
    console.log(`    status: ${r.status}   submitted ${r.submit_count}×   by: ${r.submitted_by ?? '(deleted user)'}`);
    console.log(`    resolved province: ${r.province_name ?? '— none, geocoder could not confirm —'}`);
    console.log(`    first seen: ${r.created_at.toISOString().slice(0, 16).replace('T', ' ')}`);

    // Only pending rows benefit from a suggestion — a decided row doesn't need one.
    if (suggest && r.status === 'pending') {
      console.log('    did you mean:');
      printCandidates(await searchVenueCandidates(r.canonical, 3));
    }
    console.log('');
  }
  if (!all) {
    console.log('Promote with:  node scripts/review-location-aliases.js validate <id>');
    console.log('Discard with:  node scripts/review-location-aliases.js reject   <id>\n');
  }
}

/**
 * Promote a pending alias. Re-geocodes before promoting rather than trusting the
 * stored row, so validating is a verified action and not a rubber stamp — if the
 * geocoder now resolves it, we also capture the coords the original attempt lacked.
 *
 * `as`, when given, geocodes that corrected text instead of the stored `canonical`
 * and — on success — updates `canonical` to match, since the alias should keep
 * pointing at what's actually true, not the original wrong guess.
 */
async function validate(id, { as } = {}) {
  const { rows } = await pool.query('SELECT alias, canonical, status FROM location_aliases WHERE id = $1', [id]);
  const row = rows[0];
  if (!row) return console.error(`No alias with id ${id}`);
  if (row.status === 'validated') return console.log(`"${row.alias}" is already validated — nothing to do.`);

  const textToTry = as?.trim() || row.canonical;
  console.log(`Re-geocoding "${textToTry}" before promoting…`);
  const geocoded = await resolveVenueToCity(textToTry);

  if (!geocoded) {
    console.log(`\n  ⚠️  The geocoder still cannot place "${textToTry}".`);
    console.log('    did you mean:');
    printCandidates(await searchVenueCandidates(textToTry, 5));
    console.log('\n  Re-run with --as "<exact text above>" to accept one, or try your own correction.\n');
    return;
  }

  await pool.query(
    `UPDATE location_aliases
        SET status = 'validated', canonical = $2, province_name = $3, lat = $4, lng = $5, reviewed_at = NOW()
      WHERE id = $1`,
    [id, textToTry, geocoded.provinceName, geocoded.lat, geocoded.lng]
  );
  console.log(`\n  ✅ "${row.alias}" → "${textToTry}" (${geocoded.provinceName}) is now live for search.\n`);
}

async function reject(id) {
  const { rowCount } = await pool.query(
    `UPDATE location_aliases SET status = 'rejected', reviewed_at = NOW() WHERE id = $1`,
    [id]
  );
  if (rowCount === 0) return console.error(`No alias with id ${id}`);
  console.log(`\n  🚫 Rejected. It will never be used by search.\n`);
}

(async () => {
  const argv = process.argv.slice(2);
  const [command, arg] = argv;
  const all = argv.includes('--all');
  const suggest = argv.includes('--suggest');
  const asIdx = argv.indexOf('--as');
  const as = asIdx !== -1 ? argv[asIdx + 1] : undefined;

  try {
    switch (command) {
      case 'list':     await list({ all, suggest });  break;
      case 'validate':
        if (!arg) throw new Error('validate needs an id');
        await validate(arg, { as });
        break;
      case 'reject':
        if (!arg) throw new Error('reject needs an id');
        await reject(arg);
        break;
      default:
        console.log(`
Data controller for user-submitted location aliases.

  node scripts/review-location-aliases.js list [--all] [--suggest]
  node scripts/review-location-aliases.js validate <id> [--as "<corrected name>"]
  node scripts/review-location-aliases.js reject   <id>
`);
    }
  } catch (err) {
    console.error(`Error: ${err.message}`);
    process.exitCode = 1;
  } finally {
    await pool.end();
    await appPool.end();
  }
})();
