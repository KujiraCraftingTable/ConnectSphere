// Runs all .sql files in /migrations in filename order
require('dotenv').config();
const fs = require('fs');
const path = require('path');
const { Pool } = require('pg');
const env = require('../src/config/env');

async function migrate() {
  const pool = new Pool(env.db);

  // Track applied migrations in a dedicated table
  await pool.query(`
    CREATE TABLE IF NOT EXISTS schema_migrations (
      filename   VARCHAR(255) PRIMARY KEY,
      applied_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
    )
  `);

  const { rows: applied } = await pool.query(
    'SELECT filename FROM schema_migrations'
  );
  const appliedSet = new Set(applied.map((r) => r.filename));

  const migrationsDir = path.join(__dirname, '../migrations');
  const files = fs.readdirSync(migrationsDir)
    .filter((f) => f.endsWith('.sql'))
    .sort();

  for (const file of files) {
    if (appliedSet.has(file)) {
      console.log(`[skip]  ${file}`);
      continue;
    }

    const sql = fs.readFileSync(path.join(migrationsDir, file), 'utf8');
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      await client.query(sql);
      await client.query(
        'INSERT INTO schema_migrations (filename) VALUES ($1)',
        [file]
      );
      await client.query('COMMIT');
      console.log(`[apply] ${file}`);
    } catch (err) {
      await client.query('ROLLBACK');
      console.error(`[error] ${file}:`, err.message);
      process.exit(1);
    } finally {
      client.release();
    }
  }

  await pool.end();
  console.log('Migrations complete.');
}

migrate();
