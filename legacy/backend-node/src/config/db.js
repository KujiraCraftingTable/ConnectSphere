const { Pool } = require('pg');
const env = require('./env');
const logger = require('../utils/logger');

const pool = new Pool(env.db);

// An error on an *idle* pooled client (DB failover, network blip, `restart
// postgres`) must not take the whole API down — pg discards the bad client and
// the pool re-establishes connections on the next query.
pool.on('error', (err) => {
  logger.error({ err }, 'Unexpected PostgreSQL idle-client error (pool will recover)');
});

// Verify the connection is reachable at startup
async function connectDB() {
  const client = await pool.connect();
  try {
    const { rows } = await client.query('SELECT NOW() AS now');
    logger.info({ connectedAt: rows[0].now }, 'PostgreSQL connected');
  } finally {
    client.release();
  }
}

// Thin wrapper — keeps controllers free of raw pg imports
async function query(text, params) {
  const start = Date.now();
  const result = await pool.query(text, params);
  logger.debug({ query: text, duration: Date.now() - start, rows: result.rowCount }, 'DB query');
  return result;
}

// Run `fn` inside a single transaction. `fn` receives a pg client; whatever it
// returns is returned here after COMMIT. Any throw triggers ROLLBACK and
// re-throws. Use for any operation that does more than one write and must be
// all-or-nothing (counter update + row write, multi-table cleanup, fan-out).
async function withTransaction(fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    try { await client.query('ROLLBACK'); } catch (_) { /* client already unusable */ }
    throw err;
  } finally {
    client.release();
  }
}

module.exports = { pool, query, withTransaction, connectDB };
