-- ─────────────────────────────────────────────────────────────────────────────
-- 084 — Curated skill catalogue (Work mode)
--
-- Skills were free text, so "reactjs", "React" and "react.js" were three
-- different skills to search and job matching. Like LinkedIn's standard skills
-- and Upwork's skill list, Work skills now come from this catalogue, picked
-- the same way as interests (080): search, categories, and "suggest it" for a
-- missing one (`interest_suggestions.kind = 'skill'`).
--
-- `user_skills.skill` and `job_skills.skill` keep storing the English name, so
-- endorsements (keyed by the `user_skills` row) and profile chunks stay as they
-- are. Existing spellings are rewritten to the catalogue name in place below;
-- anything the catalogue doesn't know stays valid on that profile.
--
-- A child (React → JavaScript) is found by a search for its parent, never the
-- other way round.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS skill_categories (
  key      VARCHAR(30) PRIMARY KEY,
  name_en  TEXT        NOT NULL,
  name_vi  TEXT        NOT NULL
);

CREATE TABLE IF NOT EXISTS skill_catalog (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name_en    TEXT        NOT NULL,
  name_vi    TEXT        NOT NULL,
  category   VARCHAR(30) NOT NULL REFERENCES skill_categories(key),
  parent_id  UUID        REFERENCES skill_catalog(id) ON DELETE SET NULL,
  -- Lowercase; English variants plus the Vietnamese people actually type.
  aliases    TEXT[]      NOT NULL DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE UNIQUE INDEX IF NOT EXISTS skill_catalog_name_idx ON skill_catalog (LOWER(name_en));

ALTER TABLE interest_suggestions
  ADD COLUMN IF NOT EXISTS kind VARCHAR(10) NOT NULL DEFAULT 'interest' CHECK (kind IN ('interest', 'skill'));

INSERT INTO skill_categories (key, name_en, name_vi) VALUES
  ('engineering', 'Software engineering',  'Kỹ thuật phần mềm'),
  ('web',         'Web',                   'Web'),
  ('mobile',      'Mobile',                'Di động'),
  ('data',        'Data & AI',             'Dữ liệu & AI'),
  ('cloud',       'Cloud & DevOps',        'Cloud & DevOps'),
  ('design',      'Design',                'Thiết kế'),
  ('product',     'Product & Project',     'Sản phẩm & Dự án'),
  ('marketing',   'Marketing & Content',   'Marketing & Nội dung'),
  ('sales',       'Sales & Business',      'Kinh doanh & Bán hàng'),
  ('hr',          'HR & Recruiting',       'Nhân sự & Tuyển dụng'),
  ('finance',     'Finance & Accounting',  'Tài chính & Kế toán'),
  ('operations',  'Operations & Logistics','Vận hành & Logistics'),
  ('education',   'Teaching & Research',   'Giảng dạy & Nghiên cứu'),
  ('languages',   'Languages',             'Ngoại ngữ'),
  ('soft',        'Soft skills',           'Kỹ năng mềm')
ON CONFLICT (key) DO NOTHING;

-- (name_en, name_vi, category, parent name_en, aliases)
CREATE TEMP TABLE seed_skills (
  name_en TEXT, name_vi TEXT, category TEXT, parent TEXT, aliases TEXT[]
) ON COMMIT DROP;

INSERT INTO seed_skills VALUES
  -- Software engineering
  ('Python',          'Python',             'engineering', NULL,  ARRAY['python','py','python3']),
  ('Java',            'Java',               'engineering', NULL,  ARRAY['java','java core']),
  ('C',               'C',                  'engineering', NULL,  ARRAY['c language','ngôn ngữ c','c programming']),
  ('C++',             'C++',                'engineering', NULL,  ARRAY['c++','cpp','c plus plus']),
  ('C#',              'C#',                 'engineering', NULL,  ARRAY['c#','csharp','c sharp']),
  ('Go',              'Go',                 'engineering', NULL,  ARRAY['golang','go lang']),
  ('Rust',            'Rust',               'engineering', NULL,  ARRAY['rust','rustlang']),
  ('PHP',             'PHP',                'engineering', NULL,  ARRAY['php']),
  ('Ruby',            'Ruby',               'engineering', NULL,  ARRAY['ruby']),
  ('Scala',           'Scala',              'engineering', NULL,  ARRAY['scala']),
  ('Elixir',          'Elixir',             'engineering', NULL,  ARRAY['elixir']),
  ('Bash',            'Bash',               'engineering', NULL,  ARRAY['bash','shell','shell script','shell scripting']),
  ('SQL',             'SQL',                'engineering', NULL,  ARRAY['sql','truy vấn sql']),
  ('Solidity',        'Solidity',           'engineering', NULL,  ARRAY['solidity','smart contract','smart contracts','hợp đồng thông minh']),
  ('Vapor',           'Vapor',              'engineering', 'Swift', ARRAY['vapor','swift vapor','server-side swift']),
  ('Spring Boot',     'Spring Boot',        'engineering', 'Java', ARRAY['spring boot','springboot','spring']),
  ('ASP.NET',         'ASP.NET',            'engineering', 'C#',   ARRAY['asp.net','.net','.net core','dotnet']),
  ('Django',          'Django',             'engineering', 'Python', ARRAY['django']),
  ('FastAPI',         'FastAPI',            'engineering', 'Python', ARRAY['fastapi','fast api']),
  ('Flask',           'Flask',              'engineering', 'Python', ARRAY['flask']),
  ('Laravel',         'Laravel',            'engineering', 'PHP',  ARRAY['laravel']),
  ('Ruby on Rails',   'Ruby on Rails',      'engineering', 'Ruby', ARRAY['ruby on rails','rails','ror']),
  ('Gin',             'Gin',                'engineering', 'Go',   ARRAY['gin','gin gonic']),
  ('Backend development','Phát triển backend','engineering', NULL, ARRAY['backend','back-end','back end','lập trình backend','server-side']),
  ('REST API',        'REST API',           'engineering', 'Backend development', ARRAY['rest api','restful','api design','thiết kế api']),
  ('GraphQL',         'GraphQL',            'engineering', 'Backend development', ARRAY['graphql']),
  ('Microservices',   'Microservices',      'engineering', 'Backend development', ARRAY['microservices','microservice','vi dịch vụ']),
  ('System design',   'Thiết kế hệ thống',  'engineering', NULL,  ARRAY['system design','thiết kế hệ thống','software architecture','kiến trúc phần mềm']),
  ('Data structures & algorithms','Cấu trúc dữ liệu & giải thuật','engineering', NULL, ARRAY['dsa','algorithms','thuật toán','cấu trúc dữ liệu','giải thuật','leetcode']),
  ('Software testing','Kiểm thử phần mềm',  'engineering', NULL,  ARRAY['testing','kiểm thử','tester','qa','qc','quality assurance','manual testing']),
  ('Automation testing','Kiểm thử tự động', 'engineering', 'Software testing', ARRAY['automation test','automation testing','test tự động','selenium','cypress','playwright']),
  ('Unit testing',    'Unit test',          'engineering', 'Software testing', ARRAY['unit test','unit testing','tdd','xctest','jest','pytest']),
  ('Git',             'Git',                'engineering', NULL,  ARRAY['git','github','gitlab','version control']),
  ('Cybersecurity',   'An ninh mạng',       'engineering', NULL,  ARRAY['cybersecurity','an ninh mạng','bảo mật','security','information security','infosec']),
  ('Penetration testing','Kiểm thử xâm nhập','engineering','Cybersecurity', ARRAY['pentest','pentesting','penetration testing','ethical hacking','ceh']),
  ('Embedded systems','Hệ thống nhúng',     'engineering', NULL,  ARRAY['embedded','embedded systems','lập trình nhúng','firmware','arduino','iot']),
  ('Game development','Phát triển game',    'engineering', NULL,  ARRAY['game dev','game development','làm game','lập trình game']),
  ('Unity',           'Unity',              'engineering', 'Game development', ARRAY['unity','unity3d']),
  ('Unreal Engine',   'Unreal Engine',      'engineering', 'Game development', ARRAY['unreal','unreal engine','ue5']),
  ('Blockchain',      'Blockchain',         'engineering', NULL,  ARRAY['blockchain','web3','crypto']),
  ('Vibe coding',     'Vibe coding',        'engineering', NULL,  ARRAY['vibe code','vibe coding','ai-assisted coding','code với ai']),
  -- Web
  ('Web development', 'Phát triển web',     'web', NULL,          ARRAY['web dev','web development','lập trình web','làm web']),
  ('HTML & CSS',      'HTML & CSS',         'web', 'Web development', ARRAY['html','css','html5','css3','html css']),
  ('JavaScript',      'JavaScript',         'web', 'Web development', ARRAY['javascript','js','es6']),
  ('TypeScript',      'TypeScript',         'web', 'JavaScript',  ARRAY['typescript','ts']),
  ('React',           'React',              'web', 'JavaScript',  ARRAY['react','reactjs','react.js']),
  ('Next.js',         'Next.js',            'web', 'React',       ARRAY['next.js','nextjs','next js']),
  ('Vue.js',          'Vue.js',             'web', 'JavaScript',  ARRAY['vue','vue.js','vuejs']),
  ('Nuxt.js',         'Nuxt.js',            'web', 'Vue.js',      ARRAY['nuxt','nuxt.js','nuxtjs']),
  ('Angular',         'Angular',            'web', 'JavaScript',  ARRAY['angular','angularjs']),
  ('Svelte',          'Svelte',             'web', 'JavaScript',  ARRAY['svelte','sveltekit']),
  ('Node.js',         'Node.js',            'web', 'JavaScript',  ARRAY['node','node.js','nodejs']),
  ('Express.js',      'Express.js',         'web', 'Node.js',     ARRAY['express','express.js','expressjs']),
  ('NestJS',          'NestJS',             'web', 'Node.js',     ARRAY['nestjs','nest.js']),
  ('Tailwind CSS',    'Tailwind CSS',       'web', 'HTML & CSS',  ARRAY['tailwind','tailwind css','tailwindcss']),
  ('Frontend development','Phát triển frontend','web', 'Web development', ARRAY['frontend','front-end','front end','lập trình frontend']),
  ('Full-stack development','Phát triển full-stack','web', 'Web development', ARRAY['fullstack','full-stack','full stack']),
  ('WordPress',       'WordPress',          'web', 'Web development', ARRAY['wordpress','wp']),
  ('Web performance', 'Tối ưu hiệu năng web','web','Web development', ARRAY['web performance','core web vitals','lighthouse']),
  -- Mobile
  ('Mobile development','Phát triển ứng dụng di động','mobile', NULL, ARRAY['mobile','mobile dev','mobile development','lập trình di động','lập trình app']),
  ('iOS development', 'Phát triển iOS',     'mobile', 'Mobile development', ARRAY['ios','ios dev','ios development','lập trình ios']),
  ('Swift',           'Swift',              'mobile', 'iOS development', ARRAY['swift','swift lang']),
  ('SwiftUI',         'SwiftUI',            'mobile', 'Swift',    ARRAY['swiftui','swift ui']),
  ('UIKit',           'UIKit',              'mobile', 'Swift',    ARRAY['uikit']),
  ('Android development','Phát triển Android','mobile','Mobile development', ARRAY['android','android dev','android development','lập trình android']),
  ('Kotlin',          'Kotlin',             'mobile', 'Android development', ARRAY['kotlin']),
  ('Jetpack Compose', 'Jetpack Compose',    'mobile', 'Kotlin',   ARRAY['jetpack compose','compose']),
  ('Flutter',         'Flutter',            'mobile', 'Mobile development', ARRAY['flutter']),
  ('Dart',            'Dart',               'mobile', 'Flutter',  ARRAY['dart']),
  ('React Native',    'React Native',       'mobile', 'Mobile development', ARRAY['react native','rn']),
  ('Firebase',        'Firebase',           'mobile', NULL,       ARRAY['firebase','firestore']),
  ('App Store optimization','Tối ưu App Store','mobile', NULL,    ARRAY['aso','app store optimization']),
  -- Data & AI
  ('Data analysis',   'Phân tích dữ liệu',  'data', NULL,         ARRAY['data analysis','data analytics','phân tích dữ liệu','analytics','data analyst']),
  ('Excel',           'Excel',              'data', 'Data analysis', ARRAY['excel','microsoft excel','pivot table','vlookup']),
  ('Power BI',        'Power BI',           'data', 'Data analysis', ARRAY['power bi','powerbi']),
  ('Tableau',         'Tableau',            'data', 'Data analysis', ARRAY['tableau']),
  ('Data visualization','Trực quan hoá dữ liệu','data','Data analysis', ARRAY['data visualization','data viz','trực quan hoá dữ liệu','dashboard']),
  ('Statistics',      'Thống kê',           'data', NULL,         ARRAY['statistics','thống kê','xác suất thống kê']),
  ('R',               'R',                  'data', 'Statistics', ARRAY['r language','r programming','ngôn ngữ r']),
  ('Data engineering','Kỹ thuật dữ liệu',   'data', NULL,         ARRAY['data engineering','data engineer','etl','data pipeline']),
  ('Apache Spark',    'Apache Spark',       'data', 'Data engineering', ARRAY['spark','pyspark','apache spark']),
  ('Kafka',           'Kafka',              'data', 'Data engineering', ARRAY['kafka','apache kafka']),
  ('Airflow',         'Airflow',            'data', 'Data engineering', ARRAY['airflow','apache airflow']),
  ('PostgreSQL',      'PostgreSQL',         'data', 'SQL',        ARRAY['postgresql','postgres','psql']),
  ('MySQL',           'MySQL',              'data', 'SQL',        ARRAY['mysql']),
  ('MongoDB',         'MongoDB',            'data', NULL,         ARRAY['mongodb','mongo']),
  ('Redis',           'Redis',              'data', NULL,         ARRAY['redis']),
  ('Elasticsearch',   'Elasticsearch',      'data', NULL,         ARRAY['elasticsearch','elastic','elk']),
  ('Machine Learning','Học máy',            'data', NULL,         ARRAY['machine learning','ml','học máy']),
  ('Deep learning',   'Học sâu',            'data', 'Machine Learning', ARRAY['deep learning','học sâu','neural networks']),
  ('PyTorch',         'PyTorch',            'data', 'Deep learning', ARRAY['pytorch','torch']),
  ('TensorFlow',      'TensorFlow',         'data', 'Deep learning', ARRAY['tensorflow','tf','keras']),
  ('scikit-learn',    'scikit-learn',       'data', 'Machine Learning', ARRAY['scikit-learn','sklearn']),
  ('Computer vision', 'Thị giác máy tính',  'data', 'Machine Learning', ARRAY['computer vision','thị giác máy tính','opencv']),
  ('NLP',             'Xử lý ngôn ngữ tự nhiên','data','Machine Learning', ARRAY['nlp','natural language processing','xử lý ngôn ngữ tự nhiên']),
  ('Generative AI',   'AI tạo sinh',        'data', 'Machine Learning', ARRAY['generative ai','genai','ai tạo sinh','llm','large language models']),
  ('Prompt engineering','Prompt engineering','data','Generative AI', ARRAY['prompt engineering','viết prompt','prompting']),
  ('RAG',             'RAG',                'data', 'Generative AI', ARRAY['rag','retrieval augmented generation','vector database','vector search']),
  ('Pandas',          'Pandas',             'data', 'Python',     ARRAY['pandas','numpy']),
  -- Cloud & DevOps
  ('DevOps',          'DevOps',             'cloud', NULL,        ARRAY['devops','sre','site reliability']),
  ('CI/CD',           'CI/CD',              'cloud', 'DevOps',    ARRAY['ci/cd','cicd','ci cd','continuous integration','github actions','jenkins','gitlab ci']),
  ('Docker',          'Docker',             'cloud', 'DevOps',    ARRAY['docker','container','containers']),
  ('Kubernetes',      'Kubernetes',         'cloud', 'DevOps',    ARRAY['kubernetes','k8s']),
  ('Terraform',       'Terraform',          'cloud', 'DevOps',    ARRAY['terraform','infrastructure as code','iac']),
  ('Linux',           'Linux',              'cloud', NULL,        ARRAY['linux','ubuntu','unix','quản trị linux']),
  ('Cloud computing', 'Điện toán đám mây',  'cloud', NULL,        ARRAY['cloud','cloud computing','điện toán đám mây']),
  ('AWS',             'AWS',                'cloud', 'Cloud computing', ARRAY['aws','amazon web services','ec2','s3','lambda']),
  ('GCP',             'Google Cloud',       'cloud', 'Cloud computing', ARRAY['gcp','google cloud','google cloud platform']),
  ('Azure',           'Azure',              'cloud', 'Cloud computing', ARRAY['azure','microsoft azure']),
  ('Networking',      'Mạng máy tính',      'cloud', NULL,        ARRAY['networking','mạng máy tính','ccna','network admin']),
  ('Monitoring',      'Giám sát hệ thống',  'cloud', 'DevOps',    ARRAY['monitoring','observability','grafana','prometheus']),
  -- Design
  ('UI/UX Design',    'Thiết kế UI/UX',     'design', NULL,       ARRAY['ui/ux','ui ux','uiux','ui/ux design','thiết kế ui/ux']),
  ('UI design',       'Thiết kế giao diện', 'design', 'UI/UX Design', ARRAY['ui design','thiết kế giao diện','visual design']),
  ('UX research',     'Nghiên cứu UX',      'design', 'UI/UX Design', ARRAY['ux research','user research','nghiên cứu người dùng','usability testing']),
  ('Interaction design','Thiết kế tương tác','design','UI/UX Design', ARRAY['interaction design','ixd','prototyping']),
  ('Design systems',  'Design system',      'design', 'UI/UX Design', ARRAY['design system','design systems']),
  ('Figma',           'Figma',              'design', NULL,       ARRAY['figma','figjam']),
  ('Graphic design',  'Thiết kế đồ hoạ',    'design', NULL,       ARRAY['graphic design','thiết kế đồ hoạ','thiết kế đồ họa','đồ hoạ','đồ họa']),
  ('Adobe Photoshop', 'Photoshop',          'design', 'Graphic design', ARRAY['photoshop','adobe photoshop']),
  ('Adobe Illustrator','Illustrator',       'design', 'Graphic design', ARRAY['illustrator','adobe illustrator']),
  ('Branding',        'Xây dựng thương hiệu','design','Graphic design', ARRAY['branding','brand identity','nhận diện thương hiệu','logo design']),
  ('Motion graphics', 'Motion graphics',    'design', NULL,       ARRAY['motion graphics','motion design','after effects']),
  ('Video editing',   'Dựng video',         'design', NULL,       ARRAY['video editing','dựng video','edit video','premiere','capcut','final cut']),
  ('3D modeling',     'Dựng 3D',            'design', NULL,       ARRAY['3d modeling','blender','dựng 3d']),
  ('Canva',           'Canva',              'design', NULL,       ARRAY['canva']),
  ('Product photography','Chụp ảnh sản phẩm','design', NULL,      ARRAY['product photography','chụp ảnh sản phẩm','commercial photography']),
  -- Product & Project
  ('Product Management','Quản lý sản phẩm', 'product', NULL,      ARRAY['product management','quản lý sản phẩm','product manager','product owner']),
  ('Product strategy','Chiến lược sản phẩm','product', 'Product Management', ARRAY['product strategy','roadmap','product roadmap']),
  ('Product discovery','Product discovery', 'product', 'Product Management', ARRAY['product discovery','user interviews','jobs to be done','jtbd']),
  ('Project management','Quản lý dự án',    'product', NULL,      ARRAY['project management','quản lý dự án','project manager']),
  ('Agile',           'Agile',              'product', 'Project management', ARRAY['agile','agile methodology']),
  ('Scrum',           'Scrum',              'product', 'Agile',   ARRAY['scrum','scrum master','sprint planning']),
  ('Kanban',          'Kanban',             'product', 'Agile',   ARRAY['kanban']),
  ('Jira',            'Jira',               'product', 'Project management', ARRAY['jira','confluence']),
  ('Business analysis','Phân tích nghiệp vụ','product', NULL,     ARRAY['business analysis','business analyst','phân tích nghiệp vụ','requirements']),
  ('PMP',             'PMP',                'product', 'Project management', ARRAY['pmp','project management professional']),
  -- Marketing & Content
  ('Marketing',       'Marketing',          'marketing', NULL,    ARRAY['marketing','tiếp thị']),
  ('Digital marketing','Marketing số',      'marketing', 'Marketing', ARRAY['digital marketing','marketing online','marketing số']),
  ('SEO',             'SEO',                'marketing', 'Digital marketing', ARRAY['seo','search engine optimization','tối ưu công cụ tìm kiếm']),
  ('Google Ads',      'Google Ads',         'marketing', 'Digital marketing', ARRAY['google ads','adwords','sem','ppc']),
  ('Facebook Ads',    'Facebook Ads',       'marketing', 'Digital marketing', ARRAY['facebook ads','meta ads','chạy ads','chạy quảng cáo','fb ads']),
  ('TikTok marketing','TikTok marketing',   'marketing', 'Digital marketing', ARRAY['tiktok ads','tiktok marketing','tiktok shop']),
  ('Social media marketing','Marketing mạng xã hội','marketing','Digital marketing', ARRAY['social media','social media marketing','smm','quản lý fanpage']),
  ('Content marketing','Content marketing', 'marketing', 'Marketing', ARRAY['content marketing','viết content','làm content']),
  ('Copywriting',     'Copywriting',        'marketing', 'Content marketing', ARRAY['copywriting','copywriter','viết quảng cáo']),
  ('Email marketing', 'Email marketing',    'marketing', 'Digital marketing', ARRAY['email marketing','newsletter','mailchimp']),
  ('Brand management','Quản lý thương hiệu','marketing', 'Marketing', ARRAY['brand management','brand marketing','quản lý thương hiệu']),
  ('Market research', 'Nghiên cứu thị trường','marketing','Marketing', ARRAY['market research','nghiên cứu thị trường','consumer insight']),
  ('Growth hacking',  'Growth hacking',     'marketing', 'Marketing', ARRAY['growth hacking','growth marketing']),
  ('Google Analytics','Google Analytics',   'marketing', 'Digital marketing', ARRAY['google analytics','ga4']),
  ('Public relations','Quan hệ công chúng', 'marketing', NULL,    ARRAY['public relations','quan hệ công chúng','truyền thông']),
  ('Event planning',  'Tổ chức sự kiện',    'marketing', NULL,    ARRAY['event planning','event management','tổ chức sự kiện']),
  ('Translation',     'Biên phiên dịch',    'marketing', NULL,    ARRAY['translation','dịch thuật','biên dịch','phiên dịch','interpreting']),
  -- Sales & Business
  ('Sales',           'Bán hàng',           'sales', NULL,        ARRAY['sales','bán hàng','sale']),
  ('B2B sales',       'Bán hàng B2B',       'sales', 'Sales',     ARRAY['b2b','b2b sales','enterprise sales']),
  ('Account management','Quản lý khách hàng','sales','Sales',     ARRAY['account management','key account']),
  ('Customer service','Chăm sóc khách hàng','sales', NULL,        ARRAY['customer service','chăm sóc khách hàng','cskh','customer support','customer success']),
  ('CRM',             'CRM',                'sales', 'Sales',     ARRAY['crm','salesforce','hubspot']),
  ('Business development','Phát triển kinh doanh','sales', NULL,  ARRAY['business development','biz dev','phát triển kinh doanh']),
  ('E-commerce',      'Thương mại điện tử', 'sales', NULL,        ARRAY['e-commerce','ecommerce','thương mại điện tử','shopee','lazada']),
  ('Negotiation',     'Đàm phán',           'sales', NULL,        ARRAY['negotiation','đàm phán','thương lượng']),
  ('Entrepreneurship','Khởi nghiệp',        'sales', NULL,        ARRAY['entrepreneurship','startup','khởi nghiệp','founder']),
  ('Fundraising',     'Gọi vốn',            'sales', 'Entrepreneurship', ARRAY['fundraising','gọi vốn','pitching','pitch deck','investor relations']),
  ('Business strategy','Chiến lược kinh doanh','sales', NULL,     ARRAY['business strategy','chiến lược kinh doanh']),
  -- HR & Recruiting
  ('Human resources', 'Nhân sự',            'hr', NULL,           ARRAY['hr','human resources','nhân sự','hành chính nhân sự']),
  ('Recruiting',      'Tuyển dụng',         'hr', 'Human resources', ARRAY['recruiting','recruitment','tuyển dụng','recruiter','talent acquisition']),
  ('Technical recruiting','Tuyển dụng IT',  'hr', 'Recruiting',   ARRAY['tech recruiting','it recruiter','technical recruiting','tuyển dụng it']),
  ('Headhunting',     'Săn đầu người',      'hr', 'Recruiting',   ARRAY['headhunt','headhunting','headhunter','săn đầu người']),
  ('Employer branding','Thương hiệu tuyển dụng','hr','Recruiting', ARRAY['employer branding','thương hiệu tuyển dụng']),
  ('Interviewing',    'Phỏng vấn',          'hr', 'Recruiting',   ARRAY['interviewing','phỏng vấn','screening','sàng lọc hồ sơ']),
  ('Onboarding',      'Hội nhập nhân viên', 'hr', 'Human resources', ARRAY['onboarding','hội nhập']),
  ('Compensation & benefits','Lương thưởng & phúc lợi','hr','Human resources', ARRAY['c&b','compensation','benefits','payroll','tính lương','lương thưởng']),
  ('Learning & development','Đào tạo & phát triển','hr','Human resources', ARRAY['l&d','training','đào tạo','learning and development']),
  ('Employee relations','Quan hệ lao động', 'hr', 'Human resources', ARRAY['employee relations','labor law','luật lao động','quan hệ lao động']),
  ('People analytics','Phân tích nhân sự',  'hr', 'Human resources', ARRAY['people analytics','hr analytics']),
  ('Performance management','Quản lý hiệu suất','hr','Human resources', ARRAY['performance management','kpi','okr','đánh giá hiệu suất']),
  -- Finance & Accounting
  ('Accounting',      'Kế toán',            'finance', NULL,      ARRAY['accounting','kế toán','accountant']),
  ('Bookkeeping',     'Ghi sổ kế toán',     'finance', 'Accounting', ARRAY['bookkeeping','ghi sổ']),
  ('Auditing',        'Kiểm toán',          'finance', 'Accounting', ARRAY['audit','auditing','kiểm toán']),
  ('Taxation',        'Thuế',               'finance', 'Accounting', ARRAY['tax','taxation','thuế','kế toán thuế']),
  ('Financial analysis','Phân tích tài chính','finance', NULL,    ARRAY['financial analysis','phân tích tài chính','financial modeling','fp&a']),
  ('Corporate finance','Tài chính doanh nghiệp','finance','Financial analysis', ARRAY['corporate finance','tài chính doanh nghiệp']),
  ('Investment',      'Đầu tư',             'finance', NULL,      ARRAY['investment','đầu tư','investing','chứng khoán','stocks']),
  ('Banking',         'Ngân hàng',          'finance', NULL,      ARRAY['banking','ngân hàng','tín dụng']),
  ('ACCA',            'ACCA',               'finance', 'Accounting', ARRAY['acca']),
  ('CFA',             'CFA',                'finance', 'Investment', ARRAY['cfa']),
  ('MISA',            'MISA',               'finance', 'Accounting', ARRAY['misa','phần mềm misa']),
  -- Operations & Logistics
  ('Operations management','Quản lý vận hành','operations', NULL, ARRAY['operations','operations management','vận hành','quản lý vận hành']),
  ('Supply chain',    'Chuỗi cung ứng',     'operations', NULL,   ARRAY['supply chain','chuỗi cung ứng','scm']),
  ('Logistics',       'Logistics',          'operations', 'Supply chain', ARRAY['logistics','vận tải','giao nhận','xuất nhập khẩu','import export']),
  ('Procurement',     'Mua hàng',           'operations', 'Supply chain', ARRAY['procurement','purchasing','mua hàng','thu mua']),
  ('Inventory management','Quản lý kho',    'operations', 'Supply chain', ARRAY['inventory','warehouse','quản lý kho','kho vận']),
  ('Quality management','Quản lý chất lượng','operations', NULL,  ARRAY['quality management','qms','iso 9001','quản lý chất lượng']),
  ('Lean & Six Sigma','Lean & Six Sigma',   'operations', 'Operations management', ARRAY['lean','six sigma','kaizen']),
  ('Office administration','Hành chính văn phòng','operations', NULL, ARRAY['office admin','hành chính văn phòng','thư ký']),
  -- Teaching & Research
  ('Teaching',        'Giảng dạy',          'education', NULL,    ARRAY['teaching','giảng dạy','dạy học','giáo viên','teacher','tutor','gia sư']),
  ('English teaching','Dạy tiếng Anh',      'education', 'Teaching', ARRAY['tesol','tefl','dạy tiếng anh','english teacher']),
  ('Curriculum design','Thiết kế chương trình học','education','Teaching', ARRAY['curriculum design','instructional design','thiết kế bài giảng']),
  ('Research',        'Nghiên cứu',         'education', NULL,    ARRAY['research','nghiên cứu','academic research','nghiên cứu khoa học']),
  ('Academic writing','Viết học thuật',     'education', 'Research', ARRAY['academic writing','scientific writing','viết bài báo khoa học']),
  -- Languages
  ('English',         'Tiếng Anh',          'languages', NULL,    ARRAY['english','tiếng anh','tieng anh']),
  ('IELTS',           'IELTS',              'languages', 'English', ARRAY['ielts']),
  ('TOEIC',           'TOEIC',              'languages', 'English', ARRAY['toeic']),
  ('Business English','Tiếng Anh thương mại','languages','English', ARRAY['business english','tiếng anh thương mại']),
  ('Japanese',        'Tiếng Nhật',         'languages', NULL,    ARRAY['japanese','tiếng nhật','jlpt']),
  ('Korean',          'Tiếng Hàn',          'languages', NULL,    ARRAY['korean','tiếng hàn','topik']),
  ('Chinese',         'Tiếng Trung',        'languages', NULL,    ARRAY['chinese','tiếng trung','mandarin','hsk']),
  ('French',          'Tiếng Pháp',         'languages', NULL,    ARRAY['french','tiếng pháp','delf']),
  ('German',          'Tiếng Đức',          'languages', NULL,    ARRAY['german','tiếng đức']),
  -- Soft skills
  ('Leadership',      'Lãnh đạo',           'soft', NULL,         ARRAY['leadership','lãnh đạo','leading teams','team lead']),
  ('People management','Quản lý đội nhóm',  'soft', 'Leadership', ARRAY['people management','team management','quản lý đội nhóm']),
  ('Mentoring',       'Kèm cặp',            'soft', 'Leadership', ARRAY['mentoring','mentor','coaching','kèm cặp']),
  ('Communication',   'Giao tiếp',          'soft', NULL,         ARRAY['communication','giao tiếp','kỹ năng giao tiếp']),
  ('Public speaking', 'Thuyết trình',       'soft', 'Communication', ARRAY['public speaking','thuyết trình','presentation']),
  ('Teamwork',        'Làm việc nhóm',      'soft', NULL,         ARRAY['teamwork','làm việc nhóm','collaboration']),
  ('Problem solving', 'Giải quyết vấn đề',  'soft', NULL,         ARRAY['problem solving','giải quyết vấn đề']),
  ('Critical thinking','Tư duy phản biện',  'soft', NULL,         ARRAY['critical thinking','tư duy phản biện']),
  ('Time management', 'Quản lý thời gian',  'soft', NULL,         ARRAY['time management','quản lý thời gian']),
  ('Adaptability',    'Thích nghi',         'soft', NULL,         ARRAY['adaptability','thích nghi','flexibility']),
  ('Creativity',      'Sáng tạo',           'soft', NULL,         ARRAY['creativity','sáng tạo','creative thinking']),
  ('Self-learning',   'Tự học',             'soft', NULL,         ARRAY['self-learning','self learning','tự học','continuous learning']),
  ('Remote work',     'Làm việc từ xa',     'soft', NULL,         ARRAY['remote work','làm việc từ xa','wfh']);

INSERT INTO skill_catalog (name_en, name_vi, category, aliases)
SELECT name_en, name_vi, category, aliases FROM seed_skills
ON CONFLICT (LOWER(name_en)) DO NOTHING;

UPDATE skill_catalog c SET parent_id = p.id
FROM seed_skills s JOIN skill_catalog p ON LOWER(p.name_en) = LOWER(s.parent)
WHERE LOWER(c.name_en) = LOWER(s.name_en) AND c.parent_id IS NULL;

-- Existing spellings → the catalogue name, in place so endorsements survive.
-- One row per (person, catalogue name) is renamed; where the person already
-- holds the catalogue spelling, the other spelling stays (still valid on that
-- profile) rather than breaking the unique key.
WITH matched AS (
  SELECT DISTINCT ON (us.id) us.id, us.user_id, c.name_en
  FROM user_skills us
  JOIN skill_catalog c ON LOWER(us.skill) = LOWER(c.name_en) OR LOWER(us.skill) = ANY(c.aliases)
  WHERE us.skill <> c.name_en
  ORDER BY us.id, (LOWER(us.skill) = LOWER(c.name_en)) DESC
), renamed AS (
  SELECT DISTINCT ON (m.user_id, m.name_en) m.id, m.name_en
  FROM matched m
  WHERE NOT EXISTS (SELECT 1 FROM user_skills d WHERE d.user_id = m.user_id AND d.skill = m.name_en)
  ORDER BY m.user_id, m.name_en, m.id
)
UPDATE user_skills us SET skill = r.name_en FROM renamed r WHERE us.id = r.id;

WITH matched AS (
  SELECT DISTINCT ON (js.job_id, js.skill) js.job_id, js.skill, c.name_en
  FROM job_skills js
  JOIN skill_catalog c ON LOWER(js.skill) = LOWER(c.name_en) OR LOWER(js.skill) = ANY(c.aliases)
  WHERE js.skill <> c.name_en
  ORDER BY js.job_id, js.skill, (LOWER(js.skill) = LOWER(c.name_en)) DESC
), renamed AS (
  SELECT DISTINCT ON (m.job_id, m.name_en) m.job_id, m.skill, m.name_en
  FROM matched m
  WHERE NOT EXISTS (SELECT 1 FROM job_skills d WHERE d.job_id = m.job_id AND d.skill = m.name_en)
  ORDER BY m.job_id, m.name_en, m.skill
)
UPDATE job_skills js SET skill = r.name_en FROM renamed r WHERE js.job_id = r.job_id AND js.skill = r.skill;
