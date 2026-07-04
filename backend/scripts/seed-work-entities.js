/**
 * seed-work-entities.js
 *
 * Generates 002_seed_work_entities.sql — INSERT statements with embeddings for
 * work-related entity categories: company, university, programming_language,
 * framework, tool, certification, industry, job_role, professional_field, startup.
 *
 * Usage:
 *   node scripts/seed-work-entities.js
 *
 * Requires Ollama running with mxbai-embed-large pulled.
 * Output: backend/migrations/002_seed_work_entities.sql
 */

const http = require('http');
const fs   = require('fs');
const path = require('path');

const OLLAMA_URL  = 'http://localhost:11434';
const OUTPUT_FILE = path.join(__dirname, '../migrations/002_seed_work_entities.sql');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ─── Entity definitions ───────────────────────────────────────────────────────

const WORK_ENTITIES = {

  company: [
    // Global tech
    { n: 'Google',       a: ['Alphabet', 'Google LLC'] },
    { n: 'Apple',        a: ['Apple Inc'] },
    { n: 'Microsoft',    a: ['MS', 'MSFT'] },
    { n: 'Meta',         a: ['Facebook', 'Meta Platforms'] },
    { n: 'Amazon',       a: ['AWS', 'Amazon.com'] },
    { n: 'Netflix',      a: [] },
    { n: 'Spotify',      a: [] },
    { n: 'Uber',         a: [] },
    { n: 'Airbnb',       a: [] },
    { n: 'Twitter',      a: ['X', 'Twitter/X'] },
    { n: 'LinkedIn',     a: [] },
    { n: 'TikTok',       a: ['ByteDance'] },
    { n: 'Alibaba',      a: ['Alibaba Group'] },
    { n: 'Tencent',      a: [] },
    { n: 'Samsung',      a: ['Samsung Electronics'] },
    { n: 'Sony',         a: ['Sony Group'] },
    { n: 'Adobe',        a: [] },
    { n: 'Salesforce',   a: [] },
    { n: 'Oracle',       a: [] },
    { n: 'IBM',          a: ['International Business Machines'] },
    { n: 'SAP',          a: [] },
    { n: 'NVIDIA',       a: ['nVidia'] },
    { n: 'Intel',        a: [] },
    { n: 'AMD',          a: ['Advanced Micro Devices'] },
    { n: 'Shopify',      a: [] },
    { n: 'Stripe',       a: [] },
    { n: 'Figma',        a: [] },
    { n: 'Notion',       a: [] },
    { n: 'Slack',        a: [] },
    { n: 'Zoom',         a: ['Zoom Video Communications'] },
    { n: 'Atlassian',    a: ['Jira', 'Confluence'] },
    { n: 'GitHub',       a: ['GitHub Inc'] },
    { n: 'GitLab',       a: [] },
    { n: 'Grab',         a: ['Grab Holdings'] },
    { n: 'Sea Limited',  a: ['Shopee', 'Garena'] },
    { n: 'Gojek',        a: ['GoTo Group'] },
    { n: 'Tokopedia',    a: [] },
    { n: 'Lazada',       a: [] },
    // Vietnam
    { n: 'FPT',                a: ['FPT Corporation'] },
    { n: 'FPT Software',       a: ['FSOFT'] },
    { n: 'VNG Corporation',    a: ['VNG', 'Zalo'] },
    { n: 'Tiki',               a: ['Tiki.vn'] },
    { n: 'MoMo',               a: ['M_Service', 'Vi MoMo'] },
    { n: 'VinGroup',           a: ['Vingroup'] },
    { n: 'VinAI',              a: [] },
    { n: 'VNPT',               a: [] },
    { n: 'Viettel',            a: ['Viettel Group'] },
    { n: 'TMA Solutions',      a: ['TMA'] },
    { n: 'KMS Technology',     a: ['KMS'] },
    { n: 'NashTech',           a: ['Nash Tech'] },
    { n: 'Axon Active',        a: [] },
    { n: 'Orient Software',    a: [] },
    { n: 'Bosch Vietnam',      a: ['Bosch'] },
    { n: 'NTT Data Vietnam',   a: ['NTT Data'] },
    { n: 'GHN',                a: ['Giao Hàng Nhanh'] },
    { n: 'GHTK',               a: ['Giao Hàng Tiết Kiệm'] },
    { n: 'Amanotes',           a: [] },
    { n: 'Base.vn',            a: ['Base'] },
    { n: 'KiotViet',           a: [] },
    { n: 'Pancake',            a: [] },
    { n: 'ELCA Vietnam',       a: ['ELCA'] },
    { n: 'Sky Mavis',          a: ['Axie Infinity'] },
    { n: 'Coda Payments',      a: ['Coda'] },
    { n: 'Got It',             a: [] },
    { n: 'Rikkeisoft',         a: [] },
    { n: 'LogiGear',           a: [] },
    { n: 'Saigon Technology',  a: ['SGT'] },
    { n: 'Tekup',              a: [] },
  ],

  university: [
    // Global
    { n: 'MIT',                          a: ['Massachusetts Institute of Technology'] },
    { n: 'Stanford University',          a: ['Stanford'] },
    { n: 'Harvard University',           a: ['Harvard'] },
    { n: 'Carnegie Mellon University',   a: ['CMU'] },
    { n: 'UC Berkeley',                  a: ['University of California Berkeley', 'UCB'] },
    { n: 'Oxford University',            a: ['University of Oxford'] },
    { n: 'Cambridge University',         a: ['University of Cambridge'] },
    { n: 'ETH Zurich',                   a: ['Swiss Federal Institute of Technology'] },
    { n: 'National University of Singapore', a: ['NUS'] },
    { n: 'Nanyang Technological University', a: ['NTU Singapore'] },
    { n: 'University of Toronto',        a: ['UofT'] },
    { n: 'University of Waterloo',       a: ['Waterloo'] },
    { n: 'Imperial College London',      a: ['Imperial'] },
    { n: 'Seoul National University',    a: ['SNU'] },
    { n: 'Tokyo University',             a: ['University of Tokyo', 'UTokyo'] },
    // Vietnam
    { n: 'RMIT University Vietnam',      a: ['RMIT', 'RMIT Vietnam'] },
    { n: 'Vietnam National University Hanoi', a: ['ĐHQG Hà Nội', 'VNU Hanoi'] },
    { n: 'Vietnam National University Ho Chi Minh City', a: ['ĐHQG HCM', 'VNU HCM'] },
    { n: 'Ho Chi Minh City University of Technology', a: ['Bách Khoa HCM', 'HCMUT', 'BK HCM'] },
    { n: 'University of Economics and Law', a: ['UEL', 'Đại học Kinh tế Luật'] },
    { n: 'University of Information Technology', a: ['UIT', 'ĐH Công nghệ Thông tin'] },
    { n: 'FPT University',               a: ['Đại học FPT', 'FU'] },
    { n: 'Hoa Sen University',           a: ['HSU', 'Đại học Hoa Sen'] },
    { n: 'International University Vietnam', a: ['IU', 'Đại học Quốc tế'] },
    { n: 'National Economics University', a: ['NEU', 'Đại học Kinh tế Quốc dân'] },
    { n: 'Foreign Trade University',     a: ['FTU', 'Đại học Ngoại Thương'] },
    { n: 'Hanoi University of Science and Technology', a: ['HUST', 'Bách Khoa Hà Nội'] },
    { n: 'University of Science HCM',    a: ['Khoa học Tự nhiên HCM', 'HCMUS'] },
    { n: 'HCMC University of Economics', a: ['UEH', 'Đại học Kinh tế HCM'] },
    { n: 'Posts and Telecommunications Institute', a: ['PTIT', 'Học viện Bưu chính Viễn thông'] },
    { n: 'Banking University of Ho Chi Minh City', a: ['BUH', 'ĐH Ngân hàng HCM'] },
    { n: 'Ton Duc Thang University',     a: ['TDTU', 'Tôn Đức Thắng'] },
  ],

  programming_language: [
    { n: 'Python',      a: ['py'] },
    { n: 'JavaScript',  a: ['JS'] },
    { n: 'TypeScript',  a: ['TS'] },
    { n: 'Java',        a: [] },
    { n: 'Swift',       a: [] },
    { n: 'Kotlin',      a: [] },
    { n: 'Go',          a: ['Golang'] },
    { n: 'Rust',        a: [] },
    { n: 'C++',         a: ['CPP', 'C plus plus'] },
    { n: 'C#',          a: ['CSharp', 'C sharp', 'dotnet language'] },
    { n: 'C',           a: ['C language', 'C programming'] },
    { n: 'PHP',         a: [] },
    { n: 'Ruby',        a: [] },
    { n: 'R',           a: ['R language', 'R programming'] },
    { n: 'Scala',       a: [] },
    { n: 'Dart',        a: [] },
    { n: 'Lua',         a: [] },
    { n: 'Haskell',     a: [] },
    { n: 'Elixir',      a: [] },
    { n: 'Erlang',      a: [] },
    { n: 'SQL',         a: ['Structured Query Language'] },
    { n: 'Bash',        a: ['Shell', 'Shell scripting'] },
    { n: 'MATLAB',      a: [] },
    { n: 'Assembly',    a: ['ASM', 'Assembly language'] },
    { n: 'Solidity',    a: ['Ethereum smart contract'] },
  ],

  framework: [
    // Frontend
    { n: 'React',           a: ['ReactJS', 'React.js'] },
    { n: 'Vue.js',          a: ['Vue', 'VueJS'] },
    { n: 'Angular',         a: ['AngularJS'] },
    { n: 'Next.js',         a: ['NextJS', 'Next'] },
    { n: 'Nuxt.js',         a: ['NuxtJS', 'Nuxt'] },
    { n: 'Svelte',          a: ['SvelteKit'] },
    // Mobile
    { n: 'Flutter',         a: ['Flutter SDK'] },
    { n: 'React Native',    a: ['RN'] },
    { n: 'SwiftUI',         a: ['Swift UI'] },
    { n: 'Jetpack Compose', a: ['Compose'] },
    { n: 'Ionic',           a: [] },
    // Backend
    { n: 'Spring Boot',     a: ['Spring', 'SpringBoot'] },
    { n: 'Django',          a: [] },
    { n: 'FastAPI',         a: ['Fast API'] },
    { n: 'Flask',           a: [] },
    { n: 'Express.js',      a: ['Express', 'ExpressJS'] },
    { n: 'NestJS',          a: ['Nest.js'] },
    { n: 'Laravel',         a: [] },
    { n: 'Ruby on Rails',   a: ['Rails', 'RoR'] },
    { n: 'ASP.NET',         a: ['.NET Core', 'dotnet'] },
    { n: 'Gin',             a: ['Gin framework', 'Gin Gonic'] },
    { n: 'Fiber',           a: ['Fiber Go'] },
    // ML/AI
    { n: 'TensorFlow',      a: ['TF'] },
    { n: 'PyTorch',         a: ['Torch'] },
    { n: 'Keras',           a: [] },
    { n: 'scikit-learn',    a: ['sklearn'] },
    { n: 'Hugging Face',    a: ['HuggingFace', 'transformers'] },
    // CSS
    { n: 'Tailwind CSS',    a: ['Tailwind'] },
    { n: 'Bootstrap',       a: [] },
  ],

  tool: [
    // Dev tools
    { n: 'Git',           a: [] },
    { n: 'Docker',        a: ['Docker container'] },
    { n: 'Kubernetes',    a: ['K8s'] },
    { n: 'VS Code',       a: ['Visual Studio Code', 'VSCode'] },
    { n: 'IntelliJ IDEA', a: ['IntelliJ'] },
    { n: 'Xcode',         a: [] },
    { n: 'Android Studio',a: [] },
    { n: 'Postman',       a: [] },
    { n: 'GitHub Actions',a: ['GHA'] },
    { n: 'Jenkins',       a: [] },
    { n: 'Terraform',     a: [] },
    // Cloud
    { n: 'AWS',           a: ['Amazon Web Services'] },
    { n: 'Google Cloud',  a: ['GCP', 'Google Cloud Platform'] },
    { n: 'Azure',         a: ['Microsoft Azure'] },
    { n: 'Firebase',      a: ['Google Firebase'] },
    { n: 'Supabase',      a: [] },
    { n: 'Vercel',        a: [] },
    { n: 'Netlify',       a: [] },
    // DB
    { n: 'PostgreSQL',    a: ['Postgres'] },
    { n: 'MySQL',         a: [] },
    { n: 'MongoDB',       a: ['Mongo'] },
    { n: 'Redis',         a: [] },
    { n: 'Elasticsearch', a: ['Elastic', 'ELK'] },
    { n: 'Kafka',         a: ['Apache Kafka'] },
    // Design / PM
    { n: 'Figma',         a: [] },
    { n: 'Sketch',        a: [] },
    { n: 'Adobe XD',      a: ['XD'] },
    { n: 'JIRA',          a: ['Jira Software'] },
    { n: 'Confluence',    a: [] },
    { n: 'Notion',        a: [] },
    { n: 'Trello',        a: [] },
    { n: 'Linear',        a: [] },
  ],

  certification: [
    { n: 'AWS Certified Solutions Architect', a: ['AWS SAA', 'AWS Solutions Architect'] },
    { n: 'AWS Certified Developer',           a: ['AWS DVA'] },
    { n: 'Google Cloud Professional',         a: ['GCP Professional', 'Google Cloud Cert'] },
    { n: 'Azure Administrator',               a: ['AZ-104'] },
    { n: 'Azure Developer',                   a: ['AZ-204'] },
    { n: 'CFA',                               a: ['Chartered Financial Analyst'] },
    { n: 'CPA',                               a: ['Certified Public Accountant'] },
    { n: 'ACCA',                              a: ['Association of Chartered Certified Accountants'] },
    { n: 'PMP',                               a: ['Project Management Professional'] },
    { n: 'Scrum Master',                      a: ['CSM', 'Certified Scrum Master', 'PSM'] },
    { n: 'TOEIC',                             a: ['Test of English for International Communication'] },
    { n: 'IELTS',                             a: [] },
    { n: 'TOEFL',                             a: [] },
    { n: 'Google Analytics',                  a: ['GA4 Certification'] },
    { n: 'Meta Blueprint',                    a: ['Facebook Blueprint'] },
    { n: 'CompTIA Security+',                 a: ['Security Plus'] },
    { n: 'CompTIA A+',                        a: [] },
    { n: 'CISSP',                             a: ['Certified Information Systems Security Professional'] },
    { n: 'CEH',                               a: ['Certified Ethical Hacker'] },
    { n: 'Oracle Certified',                  a: ['OCA', 'OCP'] },
  ],

  industry: [
    { n: 'Fintech',         a: ['Financial Technology', 'Finance Technology'] },
    { n: 'Healthtech',      a: ['Health Technology', 'Digital Health'] },
    { n: 'Edtech',          a: ['Education Technology', 'E-learning'] },
    { n: 'E-commerce',      a: ['Ecommerce', 'Online Shopping'] },
    { n: 'Cybersecurity',   a: ['Information Security', 'InfoSec'] },
    { n: 'Artificial Intelligence', a: ['AI industry', 'Machine Learning industry'] },
    { n: 'Blockchain',      a: ['Web3', 'Crypto'] },
    { n: 'Cloud Computing', a: ['Cloud Services'] },
    { n: 'IoT',             a: ['Internet of Things'] },
    { n: 'Gaming Industry', a: ['Game Development', 'Video Game industry'] },
    { n: 'Logistics Tech',  a: ['Supply Chain Technology', 'Logtech'] },
    { n: 'Real Estate Tech',a: ['Proptech'] },
    { n: 'Insurtech',       a: ['Insurance Technology'] },
    { n: 'Legaltech',       a: ['Legal Technology'] },
    { n: 'Agritech',        a: ['Agriculture Technology'] },
    { n: 'Media & Entertainment', a: ['Media Tech', 'Entertainment Industry'] },
    { n: 'Telecommunications', a: ['Telecom'] },
    { n: 'Banking',         a: ['Banking sector', 'Financial Services'] },
    { n: 'Retail',          a: ['Retail industry'] },
    { n: 'Manufacturing',   a: ['Manufacturing industry'] },
  ],

  job_role: [
    { n: 'Software Engineer',        a: ['Software Developer', 'SWE'] },
    { n: 'Frontend Developer',       a: ['Frontend Engineer', 'UI Developer'] },
    { n: 'Backend Developer',        a: ['Backend Engineer', 'Server-side Developer'] },
    { n: 'Full-stack Developer',     a: ['Fullstack Developer', 'Full Stack Engineer'] },
    { n: 'Mobile Developer',         a: ['Mobile Engineer'] },
    { n: 'iOS Developer',            a: ['iOS Engineer', 'Swift Developer'] },
    { n: 'Android Developer',        a: ['Android Engineer', 'Kotlin Developer'] },
    { n: 'DevOps Engineer',          a: ['DevOps', 'SRE', 'Site Reliability Engineer'] },
    { n: 'Data Engineer',            a: ['Data Pipeline Engineer'] },
    { n: 'Data Scientist',           a: ['Data Science'] },
    { n: 'Machine Learning Engineer',a: ['ML Engineer', 'AI Engineer'] },
    { n: 'Product Manager',          a: ['PM', 'Product Owner', 'PO'] },
    { n: 'UX Designer',              a: ['UX', 'User Experience Designer'] },
    { n: 'UI Designer',              a: ['UI', 'User Interface Designer'] },
    { n: 'QA Engineer',              a: ['Tester', 'Quality Assurance', 'QC'] },
    { n: 'Business Analyst',         a: ['BA', 'Systems Analyst'] },
    { n: 'Project Manager',          a: ['PM', 'Project Lead'] },
    { n: 'Engineering Manager',      a: ['EM', 'Tech Lead', 'Technical Lead'] },
    { n: 'Security Engineer',        a: ['Cybersecurity Engineer', 'Pentester'] },
    { n: 'Cloud Architect',          a: ['Solutions Architect', 'Cloud Engineer'] },
    { n: 'Blockchain Developer',     a: ['Web3 Developer', 'Smart Contract Developer'] },
    { n: 'Game Developer',           a: ['Game Engineer', 'Unity Developer'] },
    { n: 'Embedded Engineer',        a: ['Embedded Systems', 'Firmware Engineer'] },
    { n: 'Database Administrator',   a: ['DBA'] },
    { n: 'Scrum Master',             a: ['Agile Coach'] },
  ],

  professional_field: [
    { n: 'Computer Science',       a: ['CS', 'Computing'] },
    { n: 'Information Technology', a: ['IT'] },
    { n: 'Software Engineering',   a: ['Software Development'] },
    { n: 'Data Science',           a: ['Data Analytics'] },
    { n: 'Artificial Intelligence',a: ['AI', 'Machine Learning'] },
    { n: 'Cybersecurity',          a: ['Information Security'] },
    { n: 'Finance',                a: ['Financial Studies'] },
    { n: 'Accounting',             a: ['Kế toán'] },
    { n: 'Banking',                a: ['Ngân hàng'] },
    { n: 'Marketing',              a: ['Digital Marketing'] },
    { n: 'Human Resources',        a: ['HR', 'Nhân sự'] },
    { n: 'Business Administration',a: ['Business', 'Quản trị kinh doanh', 'QTKD'] },
    { n: 'Economics',              a: ['Kinh tế học'] },
    { n: 'Law',                    a: ['Luật', 'Legal Studies'] },
    { n: 'Medicine',               a: ['Y khoa', 'Healthcare'] },
    { n: 'Architecture',           a: ['Kiến trúc'] },
    { n: 'Electrical Engineering', a: ['EE', 'Điện tử'] },
    { n: 'Mechanical Engineering', a: ['ME', 'Cơ khí'] },
    { n: 'Civil Engineering',      a: ['Xây dựng'] },
    { n: 'Design',                 a: ['Graphic Design', 'Visual Design', 'Thiết kế'] },
    { n: 'Journalism',             a: ['Báo chí', 'Media Studies'] },
    { n: 'Tourism',                a: ['Du lịch', 'Hospitality'] },
    { n: 'Logistics',              a: ['Supply Chain', 'Logistics Management'] },
    { n: 'International Business', a: ['Kinh doanh Quốc tế', 'KDQT'] },
    { n: 'Foreign Language',       a: ['Ngôn ngữ nước ngoài', 'Linguistics'] },
  ],

  startup: [
    // Vietnam
    { n: 'MoMo',          a: ['M_Service', 'Vi MoMo'] },
    { n: 'ZaloPay',       a: [] },
    { n: 'VNPay',         a: [] },
    { n: 'Tiki',          a: ['Tiki.vn'] },
    { n: 'Sendo',         a: [] },
    { n: 'GHN',           a: ['Giao Hàng Nhanh'] },
    { n: 'GHTK',          a: ['Giao Hàng Tiết Kiệm'] },
    { n: 'Amanotes',      a: [] },
    { n: 'Sky Mavis',     a: ['Axie Infinity', 'Ronin Network'] },
    { n: 'Got It',        a: [] },
    { n: 'KiotViet',      a: [] },
    { n: 'Base.vn',       a: ['Base'] },
    { n: 'Coda Payments', a: ['Coda'] },
    { n: 'Rikkeisoft',    a: [] },
    { n: 'Hust Edu',      a: [] },
    // Global unicorns / notable
    { n: 'Stripe',        a: [] },
    { n: 'Plaid',         a: [] },
    { n: 'Figma',         a: [] },
    { n: 'Canva',         a: [] },
    { n: 'Notion',        a: [] },
    { n: 'Linear',        a: [] },
    { n: 'Vercel',        a: [] },
    { n: 'Supabase',      a: [] },
    { n: 'PlanetScale',   a: [] },
    { n: 'Hugging Face',  a: ['HuggingFace'] },
    { n: 'Mistral AI',    a: [] },
    { n: 'Perplexity',    a: ['Perplexity AI'] },
    { n: 'Replit',        a: [] },
    { n: 'Railway',       a: [] },
    { n: 'Fly.io',        a: [] },
  ],
};

// ─── Embedding ────────────────────────────────────────────────────────────────

async function embedText(text) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ model: 'mxbai-embed-large', prompt: text });
    const req  = http.request(`${OLLAMA_URL}/api/embeddings`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
      timeout: 30_000,
    }, (res) => {
      let raw = '';
      res.on('data', (d) => (raw += d));
      res.on('end', () => {
        try { resolve(JSON.parse(raw).embedding); }
        catch (e) { reject(new Error(`Embed parse: ${e.message}`)); }
      });
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('Embed timeout')); });
    req.write(body);
    req.end();
  });
}

// ─── SQL helpers ──────────────────────────────────────────────────────────────

function escapeSql(str) {
  return str.replace(/'/g, "''");
}

function aliasesToPg(aliases) {
  if (!aliases || aliases.length === 0) return 'ARRAY[]::text[]';
  const escaped = aliases.map(a => `'${escapeSql(a)}'`).join(',');
  return `ARRAY[${escaped}]`;
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  const lines = [
    '-- 002_seed_work_entities.sql',
    '-- Work entity seed: company, university, programming_language, framework,',
    '--   tool, certification, industry, job_role, professional_field, startup',
    '-- Generated by scripts/seed-work-entities.js',
    '',
  ];

  let total = 0, failed = 0;

  for (const [category, entities] of Object.entries(WORK_ENTITIES)) {
    console.log(`\n▶ ${category} (${entities.length} entities)`);
    lines.push(`-- ${category}`);

    for (let i = 0; i < entities.length; i++) {
      const { n: name, a: aliases } = entities[i];
      const text = `${name} (${category})`;

      let vec;
      try {
        vec = await embedText(text);
      } catch (err) {
        console.warn(`  ⚠  embed failed "${name}": ${err.message}`);
        failed++;
        continue;
      }

      const vecLiteral = `'[${vec.join(',')}]'`;
      const aliasPg    = aliasesToPg(aliases);

      lines.push(
        `INSERT INTO interest_entities (canonical_name, category, aliases, embedding)` +
        ` VALUES ('${escapeSql(name)}', '${category}', ${aliasPg}, ${vecLiteral}::vector)` +
        ` ON CONFLICT (canonical_name, category) DO NOTHING;`
      );

      total++;
      if ((i + 1) % 10 === 0) {
        process.stdout.write(`  … ${i + 1}/${entities.length}\n`);
      }

      await sleep(40);
    }
  }

  lines.push('');
  lines.push(`-- Rebuild IVFFlat index after bulk insert`);
  lines.push(`DROP INDEX IF EXISTS idx_entities_embedding;`);
  lines.push(
    `CREATE INDEX idx_entities_embedding ON interest_entities` +
    ` USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);`
  );

  fs.writeFileSync(OUTPUT_FILE, lines.join('\n'), 'utf8');

  console.log(`\n✅ Done — ${total} entities written, ${failed} failed`);
  console.log(`📄 Output: ${OUTPUT_FILE}`);
  console.log(`\nNext: run the migration`);
  console.log(`  psql -U connectsphere_user -d connectsphere -f migrations/002_seed_work_entities.sql`);
}

main().catch((err) => {
  console.error('Fatal:', err);
  process.exit(1);
});
