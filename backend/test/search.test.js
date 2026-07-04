/**
 * Interactive search test — ConnectSphere
 * Usage: node test/search.test.js
 */

const readline = require('readline');
const BASE_URL = 'http://localhost:3000';
const LIMIT    = 20;

const SUGGESTIONS = [
  { query: 'tìm lập trình viên thích cà phê',       mode: 'colleague' },
  { query: 'designer who loves anime',               mode: 'friend'    },
  { query: 'tìm bạn chơi game online cuối tuần',    mode: 'friend'    },
  { query: 'iOS developer ở Hà Nội',                mode: 'colleague' },
  { query: 'người thích du lịch và chụp ảnh',       mode: 'friend'    },
  { query: 'React developer làm startup',            mode: 'colleague' },
];

// ── Print helpers ─────────────────────────────────────────────────────────────

const C = {
  reset:  '\x1b[0m',
  bold:   '\x1b[1m',
  dim:    '\x1b[2m',
  cyan:   '\x1b[36m',
  green:  '\x1b[32m',
  yellow: '\x1b[33m',
  red:    '\x1b[31m',
  blue:   '\x1b[34m',
};

const pad = (str, len) => {
  const s = String(str ?? '');
  return s.length >= len ? s.slice(0, len - 2) + '… ' : s.padEnd(len);
};

function printSuggestions() {
  console.log(`\n${C.bold}${C.cyan}Gợi ý query:${C.reset}`);
  SUGGESTIONS.forEach((s, i) => {
    console.log(
      `  ${C.yellow}[${i + 1}]${C.reset} ${C.bold}"${s.query}"${C.reset}` +
      `  ${C.dim}(${s.mode})${C.reset}`
    );
  });
  console.log(`  ${C.yellow}[0]${C.reset} Nhập tay\n`);
}

function printCriteria(criteria) {
  const fields = [
    ['reasoning',         criteria.reasoning],
    ['mode detected',     criteria.mode],
    ['location',          criteria.location],
    ['place_name',        criteria.place_name],
    ['entity',            criteria.entity_name ? `${criteria.entity_name} (${criteria.entity_type})` : null],
    ['entity_keywords',   criteria.entity_keywords?.length   ? criteria.entity_keywords.join(', ')  : null],
    ['interest_groups',   criteria.interest_groups?.length   ? criteria.interest_groups.map(g => `[${g.join('/')}]`).join('  ') : null],
    ['skills',            criteria.skills?.length            ? criteria.skills.join(', ')            : null],
    ['bio_keywords',      criteria.bio_keywords?.length      ? criteria.bio_keywords.join(', ')      : null],
    ['job_title_keywords',criteria.job_title_keywords?.length? criteria.job_title_keywords.join(', '): null],
    ['tips',              criteria.tips],
  ];

  console.log(`\n${C.bold}${C.blue}── Extracted criteria ──────────────────────────────────${C.reset}`);
  for (const [key, val] of fields) {
    if (!val) continue;
    console.log(`  ${C.cyan}${pad(key, 20)}${C.reset}${val}`);
  }
}

function printResults(users) {
  console.log(`\n${C.bold}${C.green}── Results (${users.length}) ─────────────────────────────────────${C.reset}`);
  if (!users.length) {
    console.log(`  ${C.dim}(no results)${C.reset}`);
    return;
  }

  console.log(
    `  ${C.dim}` +
    pad('#',   4) +
    pad('display_name', 22) +
    pad('location', 18) +
    pad('mode', 12) +
    pad('job_title', 22) +
    'score' +
    C.reset
  );
  console.log(`  ${'─'.repeat(88)}`);

  users.forEach((u, i) => {
    const score = typeof u.score === 'number' ? u.score.toFixed(4) : '—';
    const scoreColor = u.score >= 0.75 ? C.green : u.score >= 0.65 ? C.yellow : C.dim;
    console.log(
      `  ${C.bold}${pad(i + 1, 4)}${C.reset}` +
      pad(u.display_name,           22) +
      pad(u.location,               18) +
      pad(u.default_mode ?? u.mode, 12) +
      pad(u.job_title,              22) +
      `${scoreColor}${score}${C.reset}`
    );

    if (Array.isArray(u.interests) && u.interests.length) {
      console.log(`       ${C.dim}interests: ${u.interests.slice(0, 6).join(', ')}${C.reset}`);
    }
    if (Array.isArray(u.skills) && u.skills.length) {
      console.log(`       ${C.dim}skills   : ${u.skills.slice(0, 6).join(', ')}${C.reset}`);
    }
  });
}

// ── Core search ───────────────────────────────────────────────────────────────

async function search(query, mode) {
  const res = await fetch(`${BASE_URL}/api/search/ai`, {
    method:  'POST',
    headers: { 'Content-Type': 'application/json' },
    body:    JSON.stringify({ query, mode }),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${await res.text()}`);
  return res.json();
}

// ── Readline prompt ───────────────────────────────────────────────────────────

function ask(rl, question) {
  return new Promise((resolve, reject) => {
    if (rl.closed) return reject(new Error('closed'));
    rl.question(question, resolve);
    rl.once('close', () => resolve(''));
  });
}

// ── Main loop ─────────────────────────────────────────────────────────────────

async function main() {
  console.log(`\n${C.bold}${C.cyan}╔══════════════════════════════════════╗`);
  console.log(`║  ConnectSphere — AI Search Tester   ║`);
  console.log(`╚══════════════════════════════════════╝${C.reset}`);

  // Health check
  try {
    const h = await fetch(`${BASE_URL}/health`);
    if (!h.ok) throw new Error();
    console.log(`\n  ${C.green}✓${C.reset} Server reachable at ${BASE_URL}`);
  } catch {
    console.log(`\n  ${C.red}✗ Server not reachable. Run: npm run dev${C.reset}\n`);
    process.exit(1);
  }

  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });

  while (true) {
    printSuggestions();

    const choice = (await ask(rl, `${C.bold}Chọn [0-${SUGGESTIONS.length}] hoặc nhấn Enter để thoát: ${C.reset}`)).trim();

    if (!choice) break;

    let query, mode;

    const idx = parseInt(choice, 10);
    if (idx >= 1 && idx <= SUGGESTIONS.length) {
      ({ query, mode } = SUGGESTIONS[idx - 1]);
    } else if (idx === 0) {
      query = (await ask(rl, `${C.bold}Nhập query: ${C.reset}`)).trim();
      if (!query) continue;
      const modeInput = (await ask(rl, `${C.bold}Mode (friend/colleague) [friend]: ${C.reset}`)).trim();
      mode = ['friend', 'colleague'].includes(modeInput) ? modeInput : 'friend';
    } else {
      console.log(`  ${C.red}Lựa chọn không hợp lệ.${C.reset}`);
      continue;
    }

    console.log(`\n${C.bold}Searching: "${query}" — mode: ${mode}${C.reset}`);
    const start = Date.now();

    try {
      const json = await search(query, mode);
      const elapsed = Date.now() - start;
      console.log(`  ${C.dim}(${elapsed}ms)${C.reset}`);

      printCriteria(json.criteria ?? {});
      printResults((json.data ?? []).slice(0, LIMIT));
    } catch (err) {
      console.log(`\n  ${C.red}✗ Error: ${err.message}${C.reset}`);
    }

    console.log('');
  }

  rl.close();
  console.log(`\n${C.dim}Bye!${C.reset}\n`);
}

main();
