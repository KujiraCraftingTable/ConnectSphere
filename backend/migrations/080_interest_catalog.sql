-- ─────────────────────────────────────────────────────────────────────────────
-- 080, Curated interest catalogue (AI_SEARCH_REVIEW.md, phase S6)
--
-- Interests used to be a hard-coded list of 13 in the app plus free text, so
-- nobody could pick "hút thuốc" or "chém gió" and search had no way to
-- recognise those words. Like Bumble's badges, Tinder's passions and Meetup's
-- topics, interests now come from this catalogue: ~140 entries in a dozen
-- categories, each with Vietnamese and English aliases. Search reads a prompt
-- against the aliases, so slang maps to an entry whatever the LLM says.
--
-- `user_interests.interest` keeps storing the English name ("Football",
-- "Gaming · Roblox"), so profile chunks and existing rows stay as they are;
-- the catalogue is joined by name, case-insensitively. A child (Football →
-- Sports) is matched by a search for its parent, never the other way round;
-- a parent may sit in another category (Karaoke, a lifestyle entry, is under
-- Singing).
--
-- Lifestyle entries (smoking, drinking…) are a section the picker shows last.
-- People can't add entries; they can suggest one, which lands in
-- `interest_suggestions` for review.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS interest_categories (
  key      VARCHAR(30) PRIMARY KEY,
  name_en  TEXT        NOT NULL,
  name_vi  TEXT        NOT NULL,
  section  VARCHAR(20) NOT NULL DEFAULT 'main' CHECK (section IN ('main', 'lifestyle'))
);

CREATE TABLE IF NOT EXISTS interest_catalog (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name_en         TEXT        NOT NULL,
  name_vi         TEXT        NOT NULL,
  category        VARCHAR(30) NOT NULL REFERENCES interest_categories(key),
  parent_id       UUID        REFERENCES interest_catalog(id) ON DELETE SET NULL,
  -- Lowercase; Vietnamese with accents, plus English variants.
  aliases         TEXT[]      NOT NULL DEFAULT '{}',
  -- Takes a "Category · specific" item (Gaming · Roblox).
  allows_specific BOOLEAN     NOT NULL DEFAULT FALSE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE UNIQUE INDEX IF NOT EXISTS interest_catalog_name_idx ON interest_catalog (LOWER(name_en));

CREATE TABLE IF NOT EXISTS interest_suggestions (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  text       VARCHAR(40) NOT NULL,
  status     VARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'added', 'rejected')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, text)
);

INSERT INTO interest_categories (key, name_en, name_vi, section) VALUES
  ('sports',    'Sports & Fitness',    'Thể thao & Rèn luyện',   'main'),
  ('outdoors',  'Outdoors & Travel',   'Du lịch & Dã ngoại',     'main'),
  ('music',     'Music',               'Âm nhạc',                'main'),
  ('film',      'Film & TV',           'Phim ảnh',               'main'),
  ('anime',     'Anime & Comics',      'Anime & Truyện tranh',   'main'),
  ('games',     'Games',               'Trò chơi',               'main'),
  ('arts',      'Arts & Making',       'Nghệ thuật & Sáng tạo',  'main'),
  ('food',      'Food & Drink',        'Ẩm thực',                'main'),
  ('learning',  'Reading & Learning',  'Đọc & Học hỏi',          'main'),
  ('tech',      'Tech & Vehicles',     'Công nghệ & Xe cộ',      'main'),
  ('social',    'Going out',           'Giao lưu & Đi chơi',     'main'),
  ('nature',    'Pets & Nature',       'Thú cưng & Thiên nhiên', 'main'),
  ('lifestyle', 'Lifestyle',           'Lối sống',               'lifestyle')
ON CONFLICT (key) DO NOTHING;

-- (name_en, name_vi, category, parent name_en, aliases, allows_specific)
CREATE TEMP TABLE seed_interests (
  name_en TEXT, name_vi TEXT, category TEXT, parent TEXT, aliases TEXT[], allows_specific BOOLEAN
) ON COMMIT DROP;

INSERT INTO seed_interests VALUES
  -- Sports & Fitness
  ('Sports',          'Thể thao',             'sports', NULL,      ARRAY['thể thao','chơi thể thao','sport','sports'], FALSE),
  ('Football',        'Bóng đá',              'sports', 'Sports',  ARRAY['bóng đá','đá banh','đá bóng','soccer','football','futsal'], FALSE),
  ('Basketball',      'Bóng rổ',              'sports', 'Sports',  ARRAY['bóng rổ','basketball'], FALSE),
  ('Volleyball',      'Bóng chuyền',          'sports', 'Sports',  ARRAY['bóng chuyền','volleyball'], FALSE),
  ('Badminton',       'Cầu lông',             'sports', 'Sports',  ARRAY['cầu lông','đánh cầu lông','badminton'], FALSE),
  ('Tennis',          'Quần vợt',             'sports', 'Sports',  ARRAY['quần vợt','tennis'], FALSE),
  ('Pickleball',      'Pickleball',           'sports', 'Sports',  ARRAY['pickleball'], FALSE),
  ('Table tennis',    'Bóng bàn',             'sports', 'Sports',  ARRAY['bóng bàn','ping pong','table tennis'], FALSE),
  ('Swimming',        'Bơi lội',              'sports', 'Sports',  ARRAY['bơi lội','đi bơi','bơi','swimming','swim'], FALSE),
  ('Running',         'Chạy bộ',              'sports', 'Sports',  ARRAY['chạy bộ','chạy marathon','running','jogging','marathon'], FALSE),
  ('Cycling',         'Đạp xe',               'sports', 'Sports',  ARRAY['đạp xe','xe đạp','cycling','biking'], FALSE),
  ('Martial arts',    'Võ thuật',             'sports', 'Sports',  ARRAY['võ thuật','martial arts','karate','taekwondo','vovinam','judo'], FALSE),
  ('Boxing',          'Đấm bốc',              'sports', 'Sports',  ARRAY['đấm bốc','quyền anh','boxing'], FALSE),
  ('Golf',            'Golf',                 'sports', 'Sports',  ARRAY['đánh golf','golf'], FALSE),
  ('Skateboarding',   'Trượt ván',            'sports', 'Sports',  ARRAY['trượt ván','skateboard','skateboarding'], FALSE),
  ('Rock climbing',   'Leo vách đá',          'sports', 'Sports',  ARRAY['leo vách','leo vách đá','rock climbing','bouldering'], FALSE),
  ('Fitness',         'Rèn luyện thể hình',   'sports', NULL,      ARRAY['thể hình','rèn luyện sức khỏe','tập thể dục','fitness'], FALSE),
  ('Gym',             'Tập gym',              'sports', 'Fitness', ARRAY['tập gym','đi gym','tập tạ','gym','weightlifting'], FALSE),
  ('Yoga',            'Yoga',                 'sports', 'Fitness', ARRAY['tập yoga','yoga'], FALSE),
  ('Meditation',      'Thiền',                'sports', NULL,      ARRAY['thiền','ngồi thiền','meditation','mindfulness'], FALSE),
  -- Outdoors & Travel
  ('Travel',          'Du lịch',              'outdoors', NULL,     ARRAY['du lịch','đi du lịch','travel','traveling','travelling'], FALSE),
  ('Backpacking',     'Đi phượt',             'outdoors', 'Travel', ARRAY['đi phượt','phượt','backpacking'], FALSE),
  ('Beach trips',     'Đi biển',              'outdoors', 'Travel', ARRAY['đi biển','beach'], FALSE),
  ('Hiking',          'Leo núi',              'outdoors', NULL,     ARRAY['leo núi','đi bộ đường dài','trekking','hiking','trek'], FALSE),
  ('Camping',         'Cắm trại',             'outdoors', NULL,     ARRAY['cắm trại','camping'], FALSE),
  ('Fishing',         'Câu cá',               'outdoors', NULL,     ARRAY['câu cá','đi câu','fishing'], FALSE),
  -- Music
  ('Music',           'Âm nhạc',              'music', NULL,    ARRAY['âm nhạc','nghe nhạc','music'], TRUE),
  ('K-pop',           'K-pop',                'music', 'Music', ARRAY['nhạc hàn','kpop','k-pop'], FALSE),
  ('BTS',             'BTS',                  'music', 'K-pop', ARRAY['bts'], FALSE),
  ('BLACKPINK',       'BLACKPINK',            'music', 'K-pop', ARRAY['blackpink'], FALSE),
  ('V-pop',           'V-pop',                'music', 'Music', ARRAY['nhạc việt','vpop','v-pop'], FALSE),
  ('US-UK music',     'Nhạc US-UK',           'music', 'Music', ARRAY['nhạc âu mỹ','nhạc us-uk','us-uk','us uk'], FALSE),
  ('Rap & Hip-hop',   'Rap & Hip-hop',        'music', 'Music', ARRAY['nhạc rap','rap','hip hop','hiphop','hip-hop'], FALSE),
  ('Rock',            'Rock',                 'music', 'Music', ARRAY['nhạc rock','rock music','rock'], FALSE),
  ('Indie',           'Nhạc indie',           'music', 'Music', ARRAY['nhạc indie','indie'], FALSE),
  ('EDM',             'EDM',                  'music', 'Music', ARRAY['nhạc điện tử','edm','electronic music'], FALSE),
  ('Jazz',            'Jazz',                 'music', 'Music', ARRAY['nhạc jazz','jazz'], FALSE),
  ('Classical music', 'Nhạc cổ điển',         'music', 'Music', ARRAY['nhạc cổ điển','classical music'], FALSE),
  ('Concerts',        'Đi concert',           'music', 'Music', ARRAY['đi concert','xem ca nhạc','concert','concerts','live show','liveshow'], FALSE),
  ('Singing',         'Ca hát',               'music', NULL,    ARRAY['ca hát','hát','singing'], FALSE),
  ('Playing instruments','Chơi nhạc cụ',      'music', NULL,    ARRAY['nhạc cụ','chơi nhạc cụ','chơi đàn','instruments'], FALSE),
  ('Guitar',          'Đàn guitar',           'music', 'Playing instruments', ARRAY['đàn guitar','ghi ta','ghita','guitar'], FALSE),
  ('Piano',           'Đàn piano',            'music', 'Playing instruments', ARRAY['đàn piano','dương cầm','piano'], FALSE),
  -- Film & TV
  ('Movies',          'Xem phim',             'film', NULL,     ARRAY['xem phim','phim','phim ảnh','phim rạp','movies','movie','film','cinema'], TRUE),
  ('K-drama',         'Phim Hàn',             'film', 'Movies', ARRAY['phim hàn','phim hàn quốc','k-drama','kdrama'], FALSE),
  ('C-drama',         'Phim Trung',           'film', 'Movies', ARRAY['phim trung','phim trung quốc','c-drama','cdrama'], FALSE),
  ('Horror movies',   'Phim kinh dị',         'film', 'Movies', ARRAY['phim kinh dị','phim ma','horror','horror movies'], FALSE),
  ('Superhero movies','Phim siêu anh hùng',   'film', 'Movies', ARRAY['siêu anh hùng','phim siêu anh hùng','marvel','superhero','superheroes'], FALSE),
  ('Documentaries',   'Phim tài liệu',        'film', 'Movies', ARRAY['phim tài liệu','documentary','documentaries'], FALSE),
  ('TV series',       'Phim bộ',              'film', 'Movies', ARRAY['phim bộ','tv series','tv shows','tv show'], FALSE),
  ('Stand-up comedy', 'Hài độc thoại',        'film', NULL,     ARRAY['hài độc thoại','stand-up','standup','stand up comedy'], FALSE),
  ('Podcasts',        'Podcast',              'film', NULL,     ARRAY['nghe podcast','podcast','podcasts'], FALSE),
  -- Anime & Comics
  ('Anime',           'Anime',                'anime', NULL,    ARRAY['xem anime','hoạt hình nhật','anime'], TRUE),
  ('Naruto',          'Naruto',               'anime', 'Anime', ARRAY['naruto'], FALSE),
  ('One Piece',       'One Piece',            'anime', 'Anime', ARRAY['đảo hải tặc','one piece'], FALSE),
  ('Jujutsu Kaisen',  'Jujutsu Kaisen',       'anime', 'Anime', ARRAY['chú thuật hồi chiến','jujutsu kaisen'], FALSE),
  ('Manga',           'Manga',                'anime', 'Comics',    ARRAY['đọc manga','truyện tranh nhật','manga'], FALSE),
  ('Comics',          'Truyện tranh',         'anime', NULL,    ARRAY['truyện tranh','đọc truyện tranh','comics','comic'], FALSE),
  ('Webtoon',         'Webtoon',              'anime', 'Comics',ARRAY['truyện tranh hàn','webtoon','manhwa'], FALSE),
  ('Cosplay',         'Cosplay',              'anime', NULL,    ARRAY['cosplay'], FALSE),
  ('Figures',         'Sưu tầm figure',       'anime', NULL,    ARRAY['sưu tầm figure','mô hình','figure','figures'], FALSE),
  -- Games
  ('Gaming',          'Chơi game',            'games', NULL,     ARRAY['chơi game','trò chơi điện tử','game','games','gaming','video games'], TRUE),
  ('Esports',         'Thể thao điện tử',     'games', 'Gaming', ARRAY['thể thao điện tử','esports','e-sports'], FALSE),
  ('Mobile games',    'Game mobile',          'games', 'Gaming', ARRAY['game mobile','game điện thoại','mobile games','mobile game'], FALSE),
  ('PC & console games','Game PC & console',  'games', 'Gaming', ARRAY['game pc','pc games','console','playstation','ps5','xbox','nintendo'], FALSE),
  ('League of Legends','Liên Minh Huyền Thoại','games', 'Gaming', ARRAY['liên minh huyền thoại','liên minh','lmht','league of legends'], FALSE),
  ('Roblox',          'Roblox',               'games', 'Gaming', ARRAY['roblox'], FALSE),
  ('Minecraft',       'Minecraft',            'games', 'Gaming', ARRAY['minecraft'], FALSE),
  ('Chess',           'Cờ vua',               'games', NULL,     ARRAY['cờ vua','đánh cờ','chơi cờ','chess'], FALSE),
  ('Board games',     'Board game',           'games', NULL,     ARRAY['ma sói','board game','board games','boardgame','werewolf'], FALSE),
  ('Rubik',           'Rubik',                'games', NULL,     ARRAY['rubik','rubik''s cube'], FALSE),
  -- Arts & Making
  ('Art',             'Nghệ thuật',           'arts', NULL,          ARRAY['nghệ thuật','art','arts'], FALSE),
  ('Drawing',         'Vẽ',                   'arts', 'Art',         ARRAY['vẽ','vẽ tranh','hội họa','drawing','painting','sketching'], FALSE),
  ('Digital art',     'Vẽ kỹ thuật số',       'arts', 'Art',         ARRAY['vẽ digital','digital art','illustration'], FALSE),
  ('Photography',     'Chụp ảnh',             'arts', NULL,          ARRAY['chụp ảnh','chụp hình','nhiếp ảnh','photography','photo','photos'], FALSE),
  ('Film photography','Chụp ảnh film',        'arts', 'Photography', ARRAY['chụp ảnh film','chụp film','máy film','film photography','analog photography'], FALSE),
  ('Videography',     'Quay video',           'arts', NULL,          ARRAY['quay video','quay phim','dựng video','edit video','videography','video editing'], FALSE),
  ('Content creation','Sáng tạo nội dung',    'arts', NULL,          ARRAY['sáng tạo nội dung','làm content','content creator','tiktok','youtube','vlog','vlogging'], FALSE),
  ('Writing',         'Viết lách',            'arts', NULL,          ARRAY['viết lách','viết truyện','làm thơ','thơ','writing','creative writing','poetry'], FALSE),
  ('Design',          'Thiết kế',             'arts', NULL,          ARRAY['thiết kế','thiết kế đồ họa','design','graphic design'], FALSE),
  ('Fashion',         'Thời trang',           'arts', NULL,          ARRAY['thời trang','phối đồ','fashion','outfit'], FALSE),
  ('Makeup',          'Trang điểm',           'arts', NULL,          ARRAY['trang điểm','làm đẹp','makeup','make up','beauty'], FALSE),
  ('Crafts & DIY',    'Đồ thủ công',          'arts', NULL,          ARRAY['thủ công','đồ handmade','móc len','đan len','handmade','diy','crafts','crochet'], FALSE),
  ('Dancing',         'Nhảy múa',             'arts', NULL,          ARRAY['nhảy','nhảy múa','khiêu vũ','dance','dancing'], FALSE),
  ('Theatre',         'Kịch & sân khấu',      'arts', NULL,          ARRAY['kịch','sân khấu','theatre','theater','musicals'], FALSE),
  -- Food & Drink
  ('Cooking',         'Nấu ăn',               'food', NULL,      ARRAY['nấu ăn','nấu nướng','cooking','cook'], FALSE),
  ('Baking',          'Làm bánh',             'food', 'Cooking', ARRAY['làm bánh','baking','bake'], FALSE),
  ('Food hunting',    'Săn quán ngon',        'food', NULL,      ARRAY['săn quán','săn đồ ăn','review đồ ăn','ẩm thực','foodie','food'], FALSE),
  ('Street food',     'Ăn vặt & đồ ăn đường phố','food', 'Food hunting',   ARRAY['ăn vặt','đồ ăn đường phố','quán vỉa hè','street food'], FALSE),
  ('Coffee',          'Cà phê',               'food', NULL,      ARRAY['cà phê','coffee','cafe','café'], FALSE),
  ('Tea',             'Trà',                  'food', NULL,      ARRAY['trà','trà đạo','tea'], FALSE),
  ('Vegetarian',      'Ăn chay',              'food', NULL,      ARRAY['ăn chay','thuần chay','vegetarian','vegan'], FALSE),
  -- Reading & Learning
  ('Books',           'Sách',                 'learning', 'Reading',        ARRAY['sách','mọt sách','books','book'], TRUE),
  ('Reading',         'Đọc sách',             'learning', NULL,        ARRAY['đọc sách','reading'], FALSE),
  ('Novels',          'Tiểu thuyết',          'learning', 'Books',     ARRAY['tiểu thuyết','light novel','novel','novels'], FALSE),
  ('Self-help',       'Phát triển bản thân',  'learning', 'Books',     ARRAY['phát triển bản thân','self-help','self help'], FALSE),
  ('Languages',       'Học ngoại ngữ',        'learning', NULL,        ARRAY['ngoại ngữ','học ngoại ngữ','học tiếng','languages','language learning'], FALSE),
  ('English',         'Tiếng Anh',            'learning', 'Languages', ARRAY['tiếng anh','english','ielts','toeic'], FALSE),
  ('Japanese',        'Tiếng Nhật',           'learning', 'Languages', ARRAY['tiếng nhật','japanese','jlpt'], FALSE),
  ('Korean',          'Tiếng Hàn',            'learning', 'Languages', ARRAY['tiếng hàn','korean','topik'], FALSE),
  ('Chinese',         'Tiếng Trung',          'learning', 'Languages', ARRAY['tiếng trung','chinese','hsk'], FALSE),
  ('History',         'Lịch sử',              'learning', NULL,        ARRAY['lịch sử','history'], FALSE),
  ('Science',         'Khoa học',             'learning', NULL,        ARRAY['khoa học','thiên văn','science','astronomy','physics'], FALSE),
  ('Psychology',      'Tâm lý học',           'learning', NULL,        ARRAY['tâm lý học','psychology'], FALSE),
  ('Philosophy',      'Triết học',            'learning', NULL,        ARRAY['triết học','philosophy'], FALSE),
  ('Investing',       'Đầu tư',               'learning', NULL,        ARRAY['đầu tư','chứng khoán','tài chính cá nhân','investing','stocks','crypto','personal finance'], FALSE),
  ('Entrepreneurship','Khởi nghiệp',          'learning', NULL,        ARRAY['khởi nghiệp','kinh doanh','entrepreneurship','startup'], FALSE),
  ('Debate',          'Tranh biện',           'learning', NULL,        ARRAY['tranh biện','hùng biện','debate','public speaking'], FALSE),
  -- Tech & Vehicles
  ('Technology',      'Công nghệ',            'tech', NULL,         ARRAY['công nghệ','technology','tech'], FALSE),
  ('Coding',          'Lập trình',            'tech', 'Technology', ARRAY['lập trình','coding','programming'], FALSE),
  ('Artificial intelligence','Trí tuệ nhân tạo','tech','Technology',ARRAY['trí tuệ nhân tạo','artificial intelligence','machine learning','chatgpt'], FALSE),
  ('Gadgets',         'Đồ công nghệ',         'tech', 'Technology', ARRAY['đồ công nghệ','gadgets','smartphone','iphone'], FALSE),
  ('Robotics',        'Robot',                'tech', 'Technology', ARRAY['lắp robot','robot','robotics'], FALSE),
  ('Cars',            'Xe hơi',               'tech', NULL,         ARRAY['xe hơi','ô tô','cars','car'], FALSE),
  ('Motorbikes',      'Xe máy',               'tech', NULL,         ARRAY['xe máy','xe phân khối lớn','motorbike','motorbikes','moto'], FALSE),
  -- Going out
  ('Shopping',        'Mua sắm',              'social', NULL,       ARRAY['mua sắm','đi shopping','shopping'], FALSE),
  ('Window shopping', 'Dạo phố ngắm đồ',      'social', 'Shopping', ARRAY['dạo phố','đi dạo phố','window shopping','windowshopping','windowshoping'], FALSE),
  ('Festivals',       'Lễ hội & sự kiện',     'social', NULL,       ARRAY['lễ hội','sự kiện','festival','festivals'], FALSE),
  ('Volunteering',    'Tình nguyện',          'social', NULL,       ARRAY['tình nguyện','thiện nguyện','từ thiện','volunteer','volunteering','charity'], FALSE),
  -- Pets & Nature
  ('Pets',            'Thú cưng',             'nature', NULL,     ARRAY['thú cưng','pets','pet'], FALSE),
  ('Dogs',            'Chó',                  'nature', 'Pets',   ARRAY['chó','nuôi chó','cún','dog','dogs'], FALSE),
  ('Cats',            'Mèo',                  'nature', 'Pets',   ARRAY['mèo','nuôi mèo','cat','cats'], FALSE),
  ('Nature',          'Thiên nhiên',          'nature', NULL,     ARRAY['thiên nhiên','nature'], FALSE),
  ('Gardening',       'Làm vườn',             'nature', 'Nature', ARRAY['làm vườn','trồng cây','cây cảnh','gardening','plants'], FALSE),
  ('Environment',     'Sống xanh',            'nature', 'Nature', ARRAY['môi trường','bảo vệ môi trường','sống xanh','environment','sustainability'], FALSE),
  -- Lifestyle (shown last)
  ('Smoking',         'Hút thuốc',            'lifestyle', NULL,      ARRAY['hút thuốc','hút thuốc lá','thuốc lá','smoking','smoke','smoker'], FALSE),
  ('Vaping',          'Hút vape',             'lifestyle', 'Smoking', ARRAY['thuốc lá điện tử','vape','vaping'], FALSE),
  ('Shisha',          'Shisha',               'lifestyle', 'Smoking', ARRAY['shisha','hookah'], FALSE),
  ('Drinking / Beer', 'Nhậu & bia',           'lifestyle', NULL,      ARRAY['nhậu','đi nhậu','bia','uống bia','rượu','beer','drinking'], FALSE),
  ('Wine',            'Rượu vang',            'lifestyle', 'Drinking / Beer', ARRAY['rượu vang','wine'], FALSE),
  ('Cocktails',       'Cocktail',             'lifestyle', 'Drinking / Beer', ARRAY['cocktail','cocktails'], FALSE),
  ('Chatting / Banter','Chém gió',            'lifestyle', NULL,      ARRAY['chém gió','tám chuyện','buôn dưa lê','nói chuyện phiếm','chit-chat','chit chat','banter','chatting'], FALSE),
  ('Karaoke',         'Karaoke',              'lifestyle', 'Singing',      ARRAY['hát karaoke','karaoke'], FALSE),
  ('Night life',      'Đi bar & tiệc đêm',    'lifestyle', NULL,      ARRAY['đi bar','đi club','quẩy','tiệc tùng','bar','club','nightlife','night life','party'], FALSE),
  ('Bubble tea',      'Trà sữa',              'lifestyle', 'Tea',      ARRAY['trà sữa','bubble tea','milk tea'], FALSE),
  ('Café hopping',    'Đi cà phê',            'lifestyle', 'Coffee',  ARRAY['cà phê chill','cafe hopping','café hopping'], FALSE);

INSERT INTO interest_catalog (name_en, name_vi, category, aliases, allows_specific)
SELECT name_en, name_vi, category, aliases, allows_specific FROM seed_interests
ON CONFLICT (LOWER(name_en)) DO NOTHING;

UPDATE interest_catalog c SET parent_id = p.id
FROM seed_interests s JOIN interest_catalog p ON LOWER(p.name_en) = LOWER(s.parent)
WHERE LOWER(c.name_en) = LOWER(s.name_en) AND c.parent_id IS NULL;
