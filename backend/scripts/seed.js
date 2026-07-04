// Seed script — generates 100 users, 5 posts each, 6 interests & 6 skills each
require('dotenv').config();
const { Pool } = require('pg');
const env = require('../src/config/env');

const pool = new Pool(env.db);

// ─── Utilities ────────────────────────────────────────────────────────────────

const pick  = (arr) => arr[Math.floor(Math.random() * arr.length)];
const pickN = (arr, n) => [...arr].sort(() => Math.random() - 0.5).slice(0, n);
const rnd   = (min, max) => Math.floor(Math.random() * (max - min + 1)) + min;

// ─── Data Pools ───────────────────────────────────────────────────────────────

const SURNAMES = [
  'Nguyễn','Trần','Lê','Phạm','Hoàng','Huỳnh','Phan','Vũ','Võ','Đặng',
  'Bùi','Đỗ','Hồ','Ngô','Dương','Lý','Đinh','Tô','Tạ','Cao',
];

const GIVEN_NAMES = [
  'Minh','Tuấn','Hùng','Long','Phúc','Đức','Anh','Khoa','Nam','Tùng',
  'Hải','Bảo','Quân','Thịnh','Việt','Dũng','Mạnh','Kiên','Thành','Phong',
  'Linh','Hương','Thu','Lan','Mai','Ngọc','Hà','Trang','Phương','Nhung',
  'Yến','Thủy','Giang','Loan','Trinh','Hoa','Thảo','Vy','Chi','Ngân',
  'Khánh','Quỳnh','Diễm','Thi','Nhi','Bích','Như','Tiên','Duyên','Hiền',
];

const LOCATIONS = [
  'Ho Chi Minh City','Hanoi','Da Nang','Hue','Can Tho',
  'Nha Trang','Vung Tau','Bien Hoa','Hai Phong','Quy Nhon',
];

const INTERESTS = [
  'Movies','Music','Coffee','Travel','Street Food','Photography','Gaming',
  'Books','Yoga','Cooking','Art','Football','Fashion','Technology','K-drama',
  'Anime','Cycling','Swimming','Hiking','Dancing','Fitness','Meditation',
  'Painting','Podcasts','Concerts','Nature','Startups','Design','Blogging',
  'Board Games','Rock Climbing','Skateboarding','Volunteering','DIY Crafts',
];

const SKILLS = [
  'Swift','React','Node.js','Python','JavaScript','TypeScript','Go','Java',
  'Kotlin','Flutter','Vue.js','Django','FastAPI','Spring Boot',
  'UI/UX Design','Figma','Sketch','Product Management','Marketing','SEO',
  'Data Science','Machine Learning','PostgreSQL','MongoDB','Redis',
  'Docker','Kubernetes','AWS','GCP','CI/CD','Leadership','Sales',
  'Business Development','Finance','Analytics','Agile','Scrum',
];

const JOB_TITLES = [
  'Software Engineer','Senior Developer','Product Manager','UX Designer',
  'Data Scientist','Marketing Manager','Sales Executive','Business Analyst',
  'DevOps Engineer','Backend Engineer','Frontend Engineer','Mobile Developer',
  'Full Stack Developer','Creative Director','Content Manager','Growth Hacker',
  'CEO','CTO','Product Designer','QA Engineer','Data Engineer',
  'AI/ML Engineer','Cloud Architect','Cybersecurity Analyst','Tech Lead',
];

const COMPANIES = [
  'VNG','Tiki','Shopee Vietnam','Grab Vietnam','MoMo','FPT Software',
  'Zalo','KMS Technology','Sky Mavis','Be Group','VNPAY','Axon Active',
  'Saigon Technology','CMC Global','VCorp','Lazada Vietnam',
  'Gojek Vietnam','TechVN','Nashtech','Codelink','TokyoTech','Rikkeisoft',
];

const AVATAR_COLORS = [
  '#1877F2','#E91E63','#4CAF50','#FF9800','#9C27B0','#00BCD4',
  '#FF5722','#607D8B','#795548','#F44336','#3F51B5','#009688',
  '#8BC34A','#FFC107','#673AB7','#00ACC1','#43A047','#E53935',
];

const FRIEND_BIOS = [
  'Coffee addict & travel enthusiast ☕🌍',
  'Living my best life one adventure at a time 🌟',
  'Foodie | Photographer | Dog lover 📸🐶',
  'Just a human trying to find good coffee ☕',
  'Music is my therapy 🎵 | Bookworm 📚',
  'Street food explorer & weekend hiker 🍜🏔️',
  'Art lover | Cinema nerd | Cat parent 🎬🐱',
  'Yoga instructor by day, gamer by night 🧘🎮',
  'Chasing sunsets and good vibes 🌅',
  'Making memories, not excuses ✨',
  'Amateur chef & professional napper 👨‍🍳😴',
  'K-drama addict | Bubble tea enthusiast 🧋',
  'Always planning the next trip ✈️',
  'Cycling everywhere in the city 🚴',
  'Dance like nobody\'s watching 💃',
];

const COLLEAGUE_BIOS = [
  'Building products that matter | {years}+ yrs in tech',
  'Passionate about scalable systems & clean code',
  'Turning data into decisions 📊',
  'Product thinker | User advocate | Growth mindset',
  'Helping teams ship faster with better processes 🚀',
  'Bridging the gap between tech & business',
  'Open source contributor | Speaker | Mentor',
  'Scaling startups from 0 to 1 💡',
  'Design systems enthusiast | Accessibility advocate',
  'Building the future of fintech in Vietnam 🏦',
];

// ─── Post Content Generators ──────────────────────────────────────────────────

const FRIEND_POSTS = [
  () => `Vừa xem xong ${pick(['Dune Part Two','Oppenheimer','Past Lives','The Bear','Beef'])} — đỉnh quá! Ai đã xem chưa? 🎬✨`,
  () => `Weekend này đi ${pick(['Đà Lạt','Phú Quốc','Hội An','Ninh Bình','Mũi Né'])} — ai rảnh đi cùng không? 🌿🏔️`,
  () => `Mới thử ${pick(['bánh mì Phượng','phở Thìn','bún bò Huế','cơm tấm Kiều Giang','bánh xèo miền Trung'])} — ngon hơn kỳ vọng rất nhiều 😍🍜`,
  () => `Bắt đầu thử ${pick(['cold brew','pour over','Aeropress','moka pot','siphon coffee'])} tại nhà — ai có recipe ngon share cho mình với ☕`,
  () => `Hoàn thành thử thách ${pick(['30 ngày yoga','21 ngày đọc sách','chạy 5km mỗi ngày','không dùng điện thoại trước 9h sáng'])} 💪 Cảm giác tuyệt vời!`,
  () => `Check-in ${pick(['Đà Lạt','Sa Pa','Phú Quốc','Hội An','Vũng Tàu'])} — đẹp hơn mình nghĩ nhiều! 📸`,
  () => `Ai ở ${pick(['Sài Gòn','Hà Nội','Đà Nẵng'])} recommend quán ${pick(['cà phê','ăn vặt','lẩu','nướng'])} ngon không? Đang tìm chỗ mới để khám phá 🗺️`,
  () => `Hôm nay học được cách ${pick(['pha trà sữa tại nhà','làm bánh tiramisu','nấu phở bò','tự cắt tóc'])} từ YouTube — kết quả khả quan lắm 😂`,
  () => `Mới đọc xong "${pick(['Atomic Habits','The Alchemist','Sapiens','Ikigai','The Subtle Art of Not Giving a F*ck'])}" — highly recommend cho ai chưa đọc 📚`,
  () => `Cuối tuần này có ai muốn đi ${pick(['cắm trại','leo núi','đạp xe','chèo thuyền kayak'])} không? Đang tìm team 🏕️`,
  () => `Vừa xem concert ${pick(['IU','BTS','Blackpink','Sơn Tùng M-TP','Mỹ Tâm'])} — xứng đáng từng đồng 🎵🔥`,
  () => `Bật mí bí quyết ${pick(['ngủ đủ giấc','giảm stress','tăng năng suất làm việc'])} của mình — đơn giản nhưng hiệu quả 🌙`,
  () => `Ai có kinh nghiệm du lịch ${pick(['Nhật Bản','Hàn Quốc','Châu Âu','Úc'])} solo không? Đang lên kế hoạch cho chuyến đi năm sau ✈️`,
  () => `Mới tập ${pick(['chụp ảnh film','vẽ màu nước','đánh đàn ukulele','học tiếng Nhật'])} — khó hơn tưởng nhưng vui lắm 🎨`,
  () => `Happy ${pick(['sinh nhật','kỷ niệm','Friday'])}! ${pick(['Cảm ơn mọi người đã nhớ đến mình 🥹','Cuộc sống thật tuyệt vời 🌟','Cheers to good times! 🥂'])}`,
];

const COLLEAGUE_POSTS = [
  {
    fn: () => `Chia sẻ kinh nghiệm sau ${rnd(1,3)} năm làm ${pick(JOB_TITLES)}: bài học quan trọng nhất là biết nói "không" với đúng thứ. Thread dài nhưng đáng đọc 🧵`,
    tags: () => pickN(['Career','Lessons','Growth','Mindset'], 3),
    title: () => `${rnd(1,3)} Years as a ${pick(JOB_TITLES)}: What I Wish I Knew Earlier`,
  },
  {
    fn: () => `Vừa ship feature ${pick(['real-time notifications','AI search','dark mode','offline mode'])} sau ${rnd(2,8)} tuần build. Chia sẻ một vài technical decisions mình đã làm 🚀`,
    tags: () => pickN(['Engineering','Tech','Product','Shipping'], 3),
    title: () => `How We Built ${pick(['Real-time Notifications','AI-Powered Search','Offline Mode'])} in ${rnd(2,8)} Weeks`,
  },
  {
    fn: () => `${pick(COMPANIES)} đang mở rộng team! Đang tìm kiếm ${pick(JOB_TITLES)} có kinh nghiệm ${rnd(1,5)}+ năm. DM mình hoặc apply qua link trong bio 📩`,
    tags: () => pickN(['Hiring','JobOpening','Tech','Recruitment'], 3),
    title: null,
  },
  {
    fn: () => `Case study: Làm thế nào team mình tăng ${pick(['conversion rate','user retention','DAU','revenue'])} lên ${rnd(30,200)}% trong ${rnd(2,6)} tháng. Không magic, chỉ là process đúng 📊`,
    tags: () => pickN(['CaseStudy','Growth','Analytics','Product'], 3),
    title: () => `How We Grew ${pick(['Conversion Rate','User Retention','DAU'])} by ${rnd(30,200)}% in ${rnd(2,6)} Months`,
  },
  {
    fn: () => `Framework mình dùng để ${pick(['prioritize backlog','run 1-on-1s','make tech decisions','hire engineers'])} — đơn giản nhưng hiệu quả với team ${rnd(3,20)} người 💡`,
    tags: () => pickN(['Framework','Leadership','Management','Productivity'], 3),
    title: () => `My Framework for ${pick(['Backlog Prioritization','Running 1-on-1s','Making Tech Decisions'])}`,
  },
  {
    fn: () => `Sau ${rnd(6,24)} tháng build ${pick(['startup','side project','open source project','internal tool'])}, đây là ${rnd(3,7)} bài học đau thương nhất mình rút ra được 😅`,
    tags: () => pickN(['Startup','Lessons','Building','Founder'], 3),
    title: () => `${rnd(3,7)} Hard Lessons from Building My ${pick(['Startup','Side Project','Open Source Project'])}`,
  },
  {
    fn: () => `Hội thảo "${pick(['AI in Product Development','Future of Work','Web3 & Beyond','Design Systems at Scale'])}" sẽ diễn ra tại ${pick(LOCATIONS)} vào tháng tới. Mình sẽ speaker — ai tham dự không? 🎤`,
    tags: () => pickN(['Event','Conference','Speaking','Community'], 3),
    title: null,
  },
  {
    fn: () => `${pick(['Python','TypeScript','Go','Rust','Kotlin'])} vs ${pick(['JavaScript','Java','Swift','PHP'])} cho backend năm ${new Date().getFullYear()}? Đây là góc nhìn của mình sau khi dùng cả hai trong production 🔧`,
    tags: () => pickN(['Backend','Engineering','TechDebate','Programming'], 3),
    title: () => `${pick(['Python','TypeScript','Go'])} vs ${pick(['JavaScript','Java','Swift'])} for Backend in ${new Date().getFullYear()}`,
  },
  {
    fn: () => `Excited thông báo: mình vừa join ${pick(COMPANIES)} với vai trò ${pick(JOB_TITLES)}! Hành trình mới bắt đầu — cảm ơn tất cả đã support 🙏`,
    tags: () => pickN(['NewJob','Career','Grateful','Opportunity'], 3),
    title: null,
  },
  {
    fn: () => `Nếu mình phải chọn ${rnd(3,5)} tool quan trọng nhất cho ${pick(['một developer','một product manager','một designer','một data scientist'])}, đó sẽ là... (Thread) 🛠️`,
    tags: () => pickN(['Tools','Productivity','Tech','Tips'], 3),
    title: () => `The ${rnd(3,5)} Most Important Tools for Every ${pick(['Developer','Product Manager','Designer','Data Scientist'])}`,
  },
];

// ─── Seed Functions ───────────────────────────────────────────────────────────

async function clearSeedData(client) {
  // Remove seed users (identified by password_hash = 'SEED_DATA')
  await client.query(`
    DELETE FROM users WHERE password_hash = 'SEED_DATA'
  `);
  console.log('[clear] Removed previous seed data');
}

async function seedUsers(client) {
  const users = [];
  const usedUsernames = new Set();

  for (let i = 0; i < 100; i++) {
    const surname   = pick(SURNAMES);
    const givenName = pick(GIVEN_NAMES);
    const displayName = `${surname} ${givenName}`;

    // Unique username: lowercase, no diacritics, + index suffix
    let base = (surname + givenName)
      .normalize('NFD').replace(/[̀-ͯ]/g, '')
      .replace(/đ/gi, 'd').replace(/\s+/g, '').toLowerCase();
    let username = base;
    let suffix = 1;
    while (usedUsernames.has(username)) {
      username = `${base}${suffix++}`;
    }
    usedUsernames.add(username);

    const mode = i < 40 ? 'friend' : i < 70 ? 'colleague' : 'friend'; // varied distribution
    const jobTitle  = pick(JOB_TITLES);
    const company   = pick(COMPANIES);
    const location  = pick(LOCATIONS);
    const bio = mode === 'friend'
      ? pick(FRIEND_BIOS)
      : pick(COLLEAGUE_BIOS).replace('{years}', rnd(2, 8));

    users.push({
      username,
      display_name:    displayName,
      bio,
      avatar_color:    pick(AVATAR_COLORS),
      location,
      job_title:       jobTitle,
      company,
      default_mode:    mode,
      friend_theme:    pick(['blue','sunset','teal']),
      colleague_theme: pick(['blue','navy','slate']),
      follower_count:  rnd(10, 2000),
      following_count: rnd(10, 500),
      post_count:      5,
    });
  }

  // Batch insert
  const ids = [];
  for (const u of users) {
    const { rows } = await client.query(
      `INSERT INTO users
         (username, password_hash, display_name, bio, avatar_color, location,
          job_title, company, default_mode, friend_theme, colleague_theme,
          follower_count, following_count, post_count)
       VALUES ($1,'SEED_DATA',$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)
       RETURNING id`,
      [
        u.username, u.display_name, u.bio, u.avatar_color, u.location,
        u.job_title, u.company, u.default_mode, u.friend_theme, u.colleague_theme,
        u.follower_count, u.following_count, u.post_count,
      ]
    );
    ids.push({ id: rows[0].id, mode: u.default_mode });
  }

  console.log(`[seed] Inserted ${ids.length} users`);
  return ids;
}

async function seedSkillsAndInterests(client, userIds) {
  let skillRows = 0, interestRows = 0;

  for (const { id } of userIds) {
    const interests = pickN(INTERESTS, 6);
    const skills    = pickN(SKILLS, 6);

    for (const interest of interests) {
      await client.query(
        'INSERT INTO user_interests (user_id, interest) VALUES ($1,$2) ON CONFLICT DO NOTHING',
        [id, interest]
      );
      interestRows++;
    }
    for (const skill of skills) {
      await client.query(
        'INSERT INTO user_skills (user_id, skill) VALUES ($1,$2) ON CONFLICT DO NOTHING',
        [id, skill]
      );
      skillRows++;
    }
  }

  console.log(`[seed] Inserted ${interestRows} interests, ${skillRows} skills`);
}

async function seedPosts(client, userIds) {
  let postCount = 0, tagCount = 0;

  for (const { id: authorId, mode } of userIds) {
    // 3 posts in primary mode, 2 in secondary
    const primaryMode   = mode;
    const secondaryMode = mode === 'friend' ? 'colleague' : 'friend';
    const postModes     = [primaryMode, primaryMode, primaryMode, secondaryMode, secondaryMode];

    for (const postMode of postModes) {
      let content, articleTitle = null, tags = [];

      if (postMode === 'friend') {
        content = pick(FRIEND_POSTS)();
      } else {
        const template = pick(COLLEAGUE_POSTS);
        content      = template.fn();
        articleTitle = template.title ? template.title() : null;
        tags         = template.tags();
      }

      const { rows } = await client.query(
        `INSERT INTO posts (author_id, content, mode, article_title, like_count, comment_count, share_count)
         VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id`,
        [authorId, content, postMode, articleTitle, rnd(0,300), rnd(0,80), rnd(0,50)]
      );
      postCount++;

      const postId = rows[0].id;
      for (const tag of tags) {
        await client.query(
          'INSERT INTO post_tags (post_id, tag) VALUES ($1,$2) ON CONFLICT DO NOTHING',
          [postId, tag]
        );
        tagCount++;
      }
    }
  }

  console.log(`[seed] Inserted ${postCount} posts, ${tagCount} tags`);
}

async function seedConnections(client, userIds) {
  const ids = userIds.map((u) => u.id);
  let count = 0;

  // Each user connects with ~8 random others
  for (const { id: requesterId } of userIds) {
    const targets = pickN(ids.filter((id) => id !== requesterId), 8);
    for (const addresseeId of targets) {
      const mode   = pick(['friend', 'colleague']);
      const status = pick(['accepted','accepted','accepted','pending','pending']);
      try {
        await client.query(
          `INSERT INTO connections (requester_id, addressee_id, mode, status)
           VALUES ($1,$2,$3,$4) ON CONFLICT DO NOTHING`,
          [requesterId, addresseeId, mode, status]
        );
        count++;
      } catch (_) { /* skip duplicates */ }
    }
  }

  console.log(`[seed] Inserted ~${count} connections`);
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function seed() {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    await clearSeedData(client);
    const userIds = await seedUsers(client);
    await seedSkillsAndInterests(client, userIds);
    await seedPosts(client, userIds);
    await seedConnections(client, userIds);

    await client.query('COMMIT');
    console.log('\n✅ Seed complete.');
  } catch (err) {
    await client.query('ROLLBACK');
    console.error('❌ Seed failed:', err.message);
    process.exit(1);
  } finally {
    client.release();
    await pool.end();
  }
}

seed();
