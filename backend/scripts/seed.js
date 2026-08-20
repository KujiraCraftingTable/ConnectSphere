// Seed script — 40 user theo cụm test thiết kế (anime / coffee / sports / music
// / react / data / cloud + filler), phục vụ verify search & feed chunk-based.
//
// Bổ sung so với bản cũ: gender cố định theo persona, is_setup=TRUE, ward_id thật
// từ vn_wards, tag cho cả hobby post, bio/post tiếng Việt (test dịch EN).
//
// Dùng:
//   node scripts/seed.js                 → chỉ seed dữ liệu
//   node scripts/seed.js --build-chunks  → seed xong build luôn chunk (cần Ollama)
require('dotenv').config();
process.env.LOG_LEVEL = process.env.LOG_LEVEL || 'warn'; // giảm noise khi build chunk
const { Pool } = require('pg');
const env = require('../src/config/env');

const pool = new Pool(env.db);
const BUILD_CHUNKS = process.argv.includes('--build-chunks');

// ─── Utilities ────────────────────────────────────────────────────────────────

const pick  = (arr) => arr[Math.floor(Math.random() * arr.length)];
const pickN = (arr, n) => [...arr].sort(() => Math.random() - 0.5).slice(0, n);
const rnd   = (min, max) => Math.floor(Math.random() * (max - min + 1)) + min;
const slug  = (s) => s.normalize('NFD').replace(/[̀-ͯ]/g, '')
  .replace(/đ/gi, 'd').replace(/\s+/g, '').toLowerCase();

const AVATAR_COLORS = [
  '#1877F2','#E91E63','#4CAF50','#FF9800','#9C27B0','#00BCD4',
  '#FF5722','#607D8B','#795548','#F44336','#3F51B5','#009688',
];

// ─── Post template pools (VN) — {text, tags} ──────────────────────────────────

const ANIME_TITLES = ['Naruto', 'One Piece', 'Jujutsu Kaisen', 'Demon Slayer', 'Attack on Titan'];
const ARTISTS       = ['BLACKPINK', 'BTS', 'IU', 'Sơn Tùng M-TP'];
const PLACES        = ['Đà Lạt', 'Sa Pa', 'Hội An', 'Mộc Châu', 'Ninh Bình'];

const POST_POOLS = {
  anime: () => {
    const t = pick(ANIME_TITLES);
    return pick([
      { text: `Vừa cày xong ${t} — arc mới đỉnh thật sự, cảm xúc vỡ oà 😭🔥`, tags: ['Anime', t] },
      { text: `Cuối tuần marathon lại ${t}, xem bao nhiêu lần cũng không chán 📺`, tags: ['Anime', t] },
      { text: `Ai đang theo ${t} mùa này không? Kiếm hội bàn luận với mình đi 🍿`, tags: ['Anime', t] },
      { text: `Mới tậu figure ${t} về, đẹp không cưỡng lại nổi 😍`, tags: ['Anime', 'Manga'] },
    ]);
  },
  coffee: () => pick([
    { text: `Sáng nay thử cold brew ở quán mới, hạt Arabica thơm dịu quá ☕`, tags: ['Coffee', 'Cafe'] },
    { text: `Cuối tuần trốn phố lên ${pick(PLACES)} săn mây, ai đi cùng không? 🌿`, tags: ['Travel', 'Nature'] },
    { text: `Bộ ảnh film chụp ở ${pick(PLACES)} vừa tráng xong, ưng cả mắt 📸`, tags: ['Photography', 'Travel'] },
    { text: `Tự pha pour over tại nhà cả tuần nay, ghiền cái vị chua thanh 🤎`, tags: ['Coffee'] },
  ]),
  sports: () => pick([
    { text: `Vừa hoàn thành 10km sáng nay, cảm giác nhẹ cả người 🏃‍♂️`, tags: ['Fitness', 'Running'] },
    { text: `Tối nay có kèo đá banh sân 7, còn thiếu 2 người, ai vào không? ⚽`, tags: ['Football', 'Sports'] },
    { text: `Chinh phục thêm cung đường đạp xe 40km cuối tuần, mệt mà đã 🚴`, tags: ['Cycling', 'Fitness'] },
    { text: `Tháng này lên được 3kg cơ nhờ tập đều với ăn sạch 💪`, tags: ['Fitness', 'Gym'] },
  ]),
  music: () => {
    const a = pick(ARTISTS);
    return pick([
      { text: `Album mới của ${a} nghe cháy quá, replay cả ngày không dứt ra được 🎧`, tags: ['Music', a] },
      { text: `Ai có vé concert ${a} pass lại mình với, năn nỉ 🥹`, tags: ['Concerts', a] },
      { text: `Cày lại hết MV của ${a}, đúng gu nhạc của mình luôn 🎵`, tags: ['Music', a] },
    ]);
  },
  react: () => pick([
    { text: `Chia sẻ cách tối ưu re-render trong React bằng useMemo và memo, giảm 40% lag 🚀`, tags: ['React', 'JavaScript'] },
    { text: `Migrate codebase sang TypeScript sau 2 tuần, type-safety đáng đồng tiền bát gạo 💪`, tags: ['TypeScript', 'React'] },
    { text: `So sánh React Query vs SWR cho data fetching — góc nhìn sau 6 tháng chạy production 🔧`, tags: ['React', 'Frontend'] },
    { text: `Vừa refactor component tree, tách logic ra custom hook cho gọn và dễ test ⚛️`, tags: ['React', 'JavaScript'] },
  ]),
  data: () => pick([
    { text: `Train xong model phân loại với Python + scikit-learn, accuracy chạm 92% rồi 📊`, tags: ['Python', 'Machine Learning'] },
    { text: `Tối ưu query PostgreSQL với index đúng, giảm thời gian từ 3s xuống 200ms ⚡`, tags: ['PostgreSQL', 'Data Science'] },
    { text: `Dựng pipeline ETL với Python, dữ liệu sạch hơn hẳn cho khâu phân tích 🧹`, tags: ['Python', 'Analytics'] },
  ]),
  cloud: () => pick([
    { text: `Dựng CI/CD với Docker + GitHub Actions, mỗi lần merge là auto deploy 🐳`, tags: ['Docker', 'CI/CD'] },
    { text: `Chia sẻ kinh nghiệm tối ưu chi phí AWS, cắt được 30% hoá đơn hàng tháng ☁️`, tags: ['AWS', 'Cloud'] },
    { text: `Chuyển hạ tầng sang Kubernetes, scale mượt hẳn lúc traffic tăng đột biến 🚢`, tags: ['Kubernetes', 'Docker'] },
  ]),
  filler_hobby: () => pick([
    { text: `Cuối tuần đọc xong một cuốn sách hay, tâm hồn được nạp đầy năng lượng 📚`, tags: ['Reading', 'Books'] },
    { text: `Thử nấu món mới theo công thức trên mạng, kết quả bất ngờ ngon 👨‍🍳`, tags: ['Cooking', 'Food'] },
    { text: `Sáng nay tập yoga bên cửa sổ, bắt đầu ngày mới thật an yên 🧘`, tags: ['Yoga', 'Wellness'] },
  ]),
  filler_work: () => pick([
    { text: `Chia sẻ quy trình review code giúp team mình giảm bug rớt production 🔍`, tags: ['Engineering', 'Teamwork'] },
    { text: `Sau vài năm làm nghề, bài học lớn nhất là biết ưu tiên đúng việc 💡`, tags: ['Career', 'Growth'] },
    { text: `Vừa hoàn thành khoá học mới, đầu tư cho bản thân chưa bao giờ lỗ 📈`, tags: ['Learning', 'Career'] },
  ]),
};

// ─── Cluster definitions ──────────────────────────────────────────────────────
// core = luôn có; extra = bốc ngẫu nhiên thêm 1–2.  gender/location gán từng member.

const CLUSTERS = [
  {
    key: 'anime', mode: 'hobby', field: 'interests',
    core: ['Anime', 'Manga'], extra: ['Naruto', 'One Piece', 'Jujutsu Kaisen', 'Gaming'],
    bios: ['Fan anime chính hiệu, cuối tuần là cắm mặt vào màn hình 🍿',
           'Otaku tập sự, mê manga và figure 😍', 'Sống để xem anime và sưu tầm truyện 📚'],
    members: [
      ['Trần', 'Minh',  'male',   'Ho Chi Minh City'],
      ['Nguyễn', 'Khoa','male',   'Ho Chi Minh City'],
      ['Lê', 'Tùng',    'male',   'Ha Noi City'],
      ['Phạm', 'Linh',  'female', 'Ho Chi Minh City'],
      ['Hoàng', 'Ngọc', 'female', 'Ho Chi Minh City'],
      ['Vũ', 'Chi',     'female', 'Da Nang City'],
    ],
  },
  {
    key: 'coffee', mode: 'hobby', field: 'interests',
    core: ['Coffee', 'Travel'], extra: ['Photography', 'Street Food', 'Hiking', 'Nature'],
    bios: ['Nghiện cà phê và mê xê dịch ☕🌍', 'Săn quán đẹp, chụp ảnh film, đi phượt 📸',
           'Cuối tuần không lên đường là không chịu được ✈️'],
    members: [
      ['Đặng', 'Hải',    'male',   'Da Nang City'],
      ['Bùi', 'Nam',     'male',   'Ho Chi Minh City'],
      ['Ngô', 'Mai',     'female', 'Ho Chi Minh City'],
      ['Dương', 'Phương','female', 'Ha Noi City'],
      ['Lý', 'Thảo',     'female', 'Da Nang City'],
    ],
  },
  {
    key: 'sports', mode: 'hobby', field: 'interests',
    core: ['Football', 'Fitness'], extra: ['Cycling', 'Swimming', 'Gym', 'Running'],
    bios: ['Sân cỏ là nhà, gym là chân lý ⚽💪', 'Chạy bộ mỗi sáng, đá banh mỗi tối 🏃',
           'Thể thao giúp mình cân bằng cuộc sống 🚴'],
    members: [
      ['Đỗ', 'Quân',   'male',   'Ho Chi Minh City'],
      ['Hồ', 'Mạnh',   'male',   'Ha Noi City'],
      ['Cao', 'Kiên',  'male',   'Ho Chi Minh City'],
      ['Tô', 'Phong',  'male',   'Hai Phong City'],
      ['Tạ', 'Vy',     'female', 'Ho Chi Minh City'],
    ],
  },
  {
    key: 'music', mode: 'hobby', field: 'interests',
    core: ['Music', 'K-drama'], extra: ['BLACKPINK', 'BTS', 'Concerts', 'Dancing'],
    bios: ['Sống nhờ nhạc và K-pop 🎧', 'Fangirl chính hiệu, cày MV cả ngày 💜',
           'Âm nhạc là liều thuốc chữa lành 🎵'],
    members: [
      ['Phan', 'Bảo',   'male',   'Ho Chi Minh City'],
      ['Đinh', 'Quỳnh', 'female', 'Ha Noi City'],
      ['Võ', 'Nhi',     'female', 'Ho Chi Minh City'],
    ],
  },
  {
    key: 'filler_hobby', mode: 'hobby', field: 'interests',
    core: [], extra: ['Reading', 'Cooking', 'Yoga', 'Photography', 'Gaming', 'Art', 'Books'],
    bios: ['Yêu những điều bình dị trong cuộc sống 🌿', 'Đọc sách, nấu ăn, sống chậm 📖',
           'Tìm niềm vui trong từng khoảnh khắc ✨'],
    members: [
      ['Huỳnh', 'Đức',   'male',   'Can Tho City'],
      ['Trịnh', 'Hương', 'female', 'Hue City'],
      ['Lương', 'Thành', 'male',   'Ha Noi City'],
    ],
  },
  {
    key: 'react', mode: 'work', field: 'skills',
    core: ['React', 'JavaScript', 'TypeScript'], extra: ['Node.js', 'Vue.js', 'Figma', 'UI/UX Design'],
    jobs: ['Frontend Engineer', 'Full Stack Developer', 'Mobile Developer'],
    companies: ['FPT Software', 'VNG', 'KMS Technology'],
    bios: ['Frontend engineer mê UI mượt và code sạch ⚛️', 'Xây sản phẩm web với React mỗi ngày 💻',
           'Đam mê tối ưu trải nghiệm người dùng 🎨'],
    members: [
      ['Nguyễn', 'Tuấn',  'male',   'Ho Chi Minh City'],
      ['Trần', 'Việt',    'male',   'Ha Noi City'],
      ['Lê', 'Dũng',      'male',   'Ho Chi Minh City'],
      ['Phạm', 'Trang',   'female', 'Ho Chi Minh City'],
      ['Hoàng', 'Nhung',  'female', 'Da Nang City'],
      ['Đỗ', 'Yến',       'female', 'Ho Chi Minh City'],
    ],
  },
  {
    key: 'data', mode: 'work', field: 'skills',
    core: ['Python', 'Machine Learning'], extra: ['PostgreSQL', 'Data Science', 'Analytics', 'MongoDB'],
    jobs: ['Data Scientist', 'Data Engineer', 'AI/ML Engineer'],
    companies: ['Tiki', 'VNPAY', 'MoMo', 'Axon Active'],
    bios: ['Biến dữ liệu thành quyết định 📊', 'Data scientist mê model và thống kê 🤖',
           'Sống trong thế giới của số liệu và insight 📈'],
    members: [
      ['Bùi', 'Thịnh',  'male',   'Ho Chi Minh City'],
      ['Ngô', 'Long',   'male',   'Ha Noi City'],
      ['Đặng', 'Loan',  'female', 'Ho Chi Minh City'],
      ['Vũ', 'Giang',   'female', 'Da Nang City'],
    ],
  },
  {
    key: 'cloud', mode: 'work', field: 'skills',
    core: ['AWS', 'Docker'], extra: ['Kubernetes', 'CI/CD', 'GCP', 'Redis'],
    jobs: ['DevOps Engineer', 'Cloud Architect', 'Backend Engineer'],
    companies: ['Grab Vietnam', 'VNG', 'Sky Mavis'],
    bios: ['DevOps, tự động hoá mọi thứ có thể ☁️', 'Dựng hạ tầng scale triệu user 🚢',
           'Ổn định và tối ưu chi phí là ưu tiên số 1 🔧'],
    members: [
      ['Hồ', 'Phúc',    'male',   'Ho Chi Minh City'],
      ['Dương', 'Hùng', 'male',   'Ha Noi City'],
      ['Cao', 'Thành',  'male',   'Ho Chi Minh City'],
      ['Lý', 'Hà',      'female', 'Ho Chi Minh City'],
    ],
  },
  {
    key: 'filler_work', mode: 'work', field: 'skills',
    core: [], extra: ['Marketing', 'SEO', 'Product Management', 'Figma', 'Leadership', 'Agile'],
    jobs: ['Product Manager', 'QA Engineer', 'Marketing Manager', 'Product Designer'],
    companies: ['Nashtech', 'Shopee Vietnam', 'Zalo', 'Tiki'],
    bios: ['Kết nối giữa công nghệ và kinh doanh 🤝', 'Tư duy sản phẩm, lấy người dùng làm gốc 💡',
           'Không ngừng học hỏi mỗi ngày 📚'],
    members: [
      ['Phan', 'Khánh',  'male',   'Can Tho City'],
      ['Tạ', 'Duyên',    'female', 'Hue City'],
      ['Đinh', 'Kiên',   'male',   'Ha Noi City'],
      ['Võ', 'Hiền',     'female', 'Ho Chi Minh City'],
    ],
  },
];

// ─── Ward lookup ──────────────────────────────────────────────────────────────

async function loadWardsByProvince(client) {
  const provinces = [...new Set(CLUSTERS.flatMap(c => c.members.map(m => m[3])))];
  const map = {};
  for (const prov of provinces) {
    const { rows } = await client.query(
      `SELECT id FROM vn_wards WHERE province_name_en = $1`, [prov]
    );
    map[prov] = rows.map(r => r.id);
  }
  return map;
}

// ─── Seed ─────────────────────────────────────────────────────────────────────

async function clearSeedData(client) {
  await client.query(`DELETE FROM users WHERE password_hash = 'SEED_DATA'`);
  console.log('[clear] Removed previous seed data');
}

async function seedAll(client) {
  const wardsByProvince = await loadWardsByProvince(client);
  const usedUsernames = new Set();
  const seeded = []; // { id, mode, cluster }
  const clusterMembers = {}; // cluster key → [ids] (cho connections)

  for (const cluster of CLUSTERS) {
    clusterMembers[cluster.key] = [];

    for (const [surname, given, gender, location] of cluster.members) {
      // Unique username
      let base = slug(surname + given), username = base, i = 1;
      while (usedUsernames.has(username)) username = `${base}${i++}`;
      usedUsernames.add(username);

      const wards = wardsByProvince[location] || [];
      const wardId = wards.length ? pick(wards) : null;
      const isWork = cluster.mode === 'work';

      const { rows } = await client.query(
        `INSERT INTO users
           (username, password_hash, display_name, bio, avatar_color, location, ward_id,
            gender, job_title, company, default_mode, is_setup,
            follower_count, following_count, post_count)
         VALUES ($1,'SEED_DATA',$2,$3,$4,$5,$6,$7,$8,$9,$10,TRUE,$11,$12,$13)
         RETURNING id`,
        [
          username, `${surname} ${given}`, pick(cluster.bios), pick(AVATAR_COLORS),
          location, wardId, gender,
          isWork ? pick(cluster.jobs) : null,
          isWork ? pick(cluster.companies) : null,
          cluster.mode, rnd(10, 2000), rnd(10, 500),
          0, // post_count cập nhật sau
        ]
      );
      const userId = rows[0].id;
      seeded.push({ id: userId, mode: cluster.mode, cluster: cluster.key });
      clusterMembers[cluster.key].push(userId);

      // Interests / skills: core + 1–2 extra
      const terms = [...cluster.core, ...pickN(cluster.extra, rnd(1, 2))];
      const table = cluster.field === 'skills' ? 'user_skills' : 'user_interests';
      const col   = cluster.field === 'skills' ? 'skill' : 'interest';
      for (const term of new Set(terms)) {
        await client.query(
          `INSERT INTO ${table} (user_id, ${col}) VALUES ($1,$2) ON CONFLICT DO NOTHING`,
          [userId, term]
        );
      }

      // Posts: 3–4 bài trong đúng mode của cụm, kèm tag (POST_POOLS key = cluster.key)
      const nPosts = rnd(3, 4);
      for (let p = 0; p < nPosts; p++) {
        const { text, tags } = POST_POOLS[cluster.key]();
        const { rows: pr } = await client.query(
          `INSERT INTO posts (author_id, content, mode, like_count, comment_count, share_count)
           VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
          [userId, text, cluster.mode, rnd(0, 300), rnd(0, 80), rnd(0, 50)]
        );
        const postId = pr[0].id;
        for (const tag of tags) {
          await client.query(
            `INSERT INTO post_tags (post_id, tag) VALUES ($1,$2) ON CONFLICT DO NOTHING`,
            [postId, tag]
          );
        }
      }
      await client.query(`UPDATE users SET post_count = $1 WHERE id = $2`, [nPosts, userId]);
    }
  }

  // Connections: mỗi user nối ~4 người cùng cụm + 1 ngẫu nhiên khác cụm
  const allIds = seeded.map(s => s.id);
  let connCount = 0;
  for (const s of seeded) {
    const sameCluster = clusterMembers[s.cluster].filter(id => id !== s.id);
    const targets = new Set([
      ...pickN(sameCluster, Math.min(4, sameCluster.length)),
      ...pickN(allIds.filter(id => id !== s.id), 1),
    ]);
    for (const addressee of targets) {
      await client.query(
        `INSERT INTO connections (requester_id, addressee_id, mode, status)
         VALUES ($1,$2,$3,'accepted') ON CONFLICT DO NOTHING`,
        [s.id, addressee, s.mode]
      ).then(() => connCount++).catch(() => {});
    }
  }

  console.log(`[seed] ${seeded.length} users, connections ~${connCount}`);
  return seeded;
}

// ─── Build chunks (--build-chunks) ────────────────────────────────────────────

async function buildChunks(client, seeded) {
  const { buildProfileChunk, buildPostChunk } = require('../src/services/chunkService');

  const userIds = seeded.map(s => s.id);
  const { rows: posts } = await client.query(
    `SELECT id FROM posts WHERE author_id = ANY($1::uuid[])`, [userIds]
  );

  console.log(`[chunks] Building ${userIds.length} profile + ${posts.length} post chunks (cần Ollama)...`);
  let done = 0;
  for (const id of userIds) {
    await buildProfileChunk(id).catch(e => console.warn('  profile fail', e.message));
    if (++done % 10 === 0) console.log(`  profiles: ${done}/${userIds.length}`);
  }
  done = 0;
  for (const { id } of posts) {
    await buildPostChunk(id).catch(e => console.warn('  post fail', e.message));
    if (++done % 25 === 0) console.log(`  posts: ${done}/${posts.length}`);
  }
  console.log('[chunks] Done.');
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function seed() {
  const client = await pool.connect();
  let seeded;
  try {
    await client.query('BEGIN');
    await clearSeedData(client);
    seeded = await seedAll(client);
    await client.query('COMMIT');
    console.log('✅ Seed data complete.');
  } catch (err) {
    await client.query('ROLLBACK');
    console.error('❌ Seed failed:', err.message);
    client.release();
    await pool.end();
    process.exit(1);
  }
  client.release();

  if (BUILD_CHUNKS) {
    const c2 = await pool.connect();
    try { await buildChunks(c2, seeded); }
    catch (err) { console.error('❌ Chunk build failed:', err.message); }
    finally { c2.release(); }
  }

  await pool.end();
  process.exit(0);
}

seed();
