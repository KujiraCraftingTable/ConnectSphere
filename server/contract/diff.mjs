#!/usr/bin/env node
// Contract-test harness (skeleton). Fires the same request at the Node oracle
// and the Swift port, normalises volatile fields, and diffs status + JSON.
//
//   node server/contract/diff.mjs cases/phase0.json
//
// A case file is a JSON array of:
//   { "name": "...", "method": "GET", "path": "/health",
//     "headers": {}, "body": null,
//     "allow": ["checks.ollama"]   // dot-paths permitted to differ (see allowlist.json) }
//
// Env: ORACLE_BASE (default http://localhost:3000), PORT_BASE (default http://localhost:8080)

import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ORACLE = process.env.ORACLE_BASE || "http://localhost:3000";
const PORT = process.env.PORT_BASE || "http://localhost:8080";

const GLOBAL_ALLOW = JSON.parse(readFileSync(resolve(HERE, "allowlist.json"), "utf8"));

// Fields whose values are inherently non-deterministic — blanked before compare.
const VOLATILE_KEYS = new Set([
  "id", "created_at", "updated_at", "applied_at", "token", "iat", "exp",
  "reset_at", "computed_at", "requested_at", "reviewed_at", "expires_at",
  "RateLimit-Reset",
]);

function normalise(value) {
  if (Array.isArray(value)) return value.map(normalise);
  if (value && typeof value === "object") {
    const out = {};
    for (const [k, v] of Object.entries(value).sort(([a], [b]) => a.localeCompare(b))) {
      out[k] = VOLATILE_KEYS.has(k) ? "<volatile>" : normalise(v);
    }
    return out;
  }
  return value;
}

function pruneAllowed(a, b, allow) {
  for (const path of allow) {
    const segs = path.split(".");
    for (const obj of [a, b]) {
      let cur = obj;
      for (let i = 0; i < segs.length - 1 && cur != null; i++) cur = cur[segs[i]];
      if (cur && typeof cur === "object") delete cur[segs.at(-1)];
    }
  }
}

async function hit(base, tc) {
  const res = await fetch(base + tc.path, {
    method: tc.method || "GET",
    headers: tc.headers || {},
    body: tc.body == null ? undefined : JSON.stringify(tc.body),
  });
  let json = null;
  try { json = await res.json(); } catch { /* non-JSON */ }
  return { status: res.status, json };
}

const caseFile = process.argv[2];
if (!caseFile) {
  console.error("usage: node diff.mjs <cases.json>");
  process.exit(2);
}
const cases = JSON.parse(readFileSync(resolve(process.cwd(), caseFile), "utf8"));

let failed = 0;
for (const tc of cases) {
  const [oracle, port] = await Promise.all([hit(ORACLE, tc), hit(PORT, tc)]);
  const allow = [...GLOBAL_ALLOW, ...(tc.allow || [])];
  const a = normalise(oracle.json);
  const b = normalise(port.json);
  pruneAllowed(a, b, allow);
  const sameStatus = oracle.status === port.status;
  const sameBody = JSON.stringify(a) === JSON.stringify(b);
  if (sameStatus && sameBody) {
    console.log(`  ok   ${tc.name}`);
  } else {
    failed++;
    console.log(`  FAIL ${tc.name}`);
    if (!sameStatus) console.log(`       status: oracle=${oracle.status} port=${port.status}`);
    if (!sameBody) {
      console.log(`       oracle: ${JSON.stringify(a)}`);
      console.log(`       port:   ${JSON.stringify(b)}`);
    }
  }
}
console.log(`\n${cases.length - failed}/${cases.length} passed`);
process.exit(failed ? 1 : 0);
