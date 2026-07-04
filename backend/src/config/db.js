const { Pool } = require('pg');
const env = require('./env');
const logger = require('../utils/logger');

const pool = new Pool(env.db);

// Log & throw on unexpected pool errors
pool.on('error', (err) => {
  logger.error({ err }, 'Unexpected PostgreSQL pool error');
  process.exit(1);
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

module.exports = { pool, query, connectDB };
