import SwiftUI

/// A section in a static content page, self-translated based on AppLanguage
/// (the content is long, so it isn't placed in .strings).
struct StaticInfoSection: Identifiable {
    let id = UUID()
    let headingEN: String
    let headingVI: String
    let bodyEN: String
    let bodyVI: String

    func heading(for lang: AppLanguage) -> String { lang == .vietnamese ? headingVI : headingEN }
    func body(for lang: AppLanguage) -> String { lang == .vietnamese ? bodyVI : bodyEN }
}

/// Static content page shared by Help / Terms / Privacy.
struct StaticInfoView: View {
    @Environment(AppState.self) var appState
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    /// Localization key for the title (already present in Localizable.strings)
    let titleKey: String
    let sections: [StaticInfoSection]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.heading(for: appState.appLanguage))
                            .scaledFont(17, .semibold)
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                        Text(section.body(for: appState.appLanguage))
                            .scaledFont(15)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(3)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppColors.base(colorScheme))
        .navigationTitle(bundle.loc(titleKey))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Content for the 3 pages (generic for the course project)

extension StaticInfoView {
    static let helpSections: [StaticInfoSection] = [
        StaticInfoSection(
            headingEN: "Two modes",
            headingVI: "Hai chế độ",
            bodyEN: "ConnectSphere has two separate spaces: Hobby mode for friends who share your interests, and Work mode for professional networking. Switch between them any time from the pill at the top of the feed or in Settings. Each mode has its own feed, profile details and conversations.",
            bodyVI: "ConnectSphere có hai không gian riêng: chế độ Sở thích để kết bạn cùng đam mê và chế độ Công việc để mở rộng quan hệ nghề nghiệp. Bạn có thể chuyển chế độ bất kỳ lúc nào bằng nút ở đầu bảng tin hoặc trong Cài đặt. Mỗi chế độ có bảng tin, hồ sơ và hội thoại riêng."
        ),
        StaticInfoSection(
            headingEN: "Finding people",
            headingVI: "Tìm người phù hợp",
            bodyEN: "Use the Search tab and describe who you want to meet in your own words. The AI reads your description and suggests the best matches with reasons for each. Set a search radius in Settings to only see people nearby.",
            bodyVI: "Vào tab Tìm kiếm và mô tả người bạn muốn gặp bằng lời của bạn, AI sẽ đọc mô tả và gợi ý những người phù hợp nhất kèm lý do. Đặt bán kính tìm kiếm trong Cài đặt nếu chỉ muốn gặp người ở gần."
        ),
        StaticInfoSection(
            headingEN: "Communities & chat",
            headingVI: "Cộng đồng & nhắn tin",
            bodyEN: "Join communities to post, run polls and host events with people who share your interests. Once connected with someone, you can message them directly, long-press a message to unsend it, and tap the chat header for per-conversation settings.",
            bodyVI: "Tham gia cộng đồng để đăng bài, tạo bình chọn và sự kiện với những người cùng sở thích. Khi đã kết nối với ai đó, bạn có thể nhắn tin trực tiếp. Nhấn giữ tin nhắn để thu hồi, chạm vào tên ở đầu đoạn chat để mở cài đặt riêng."
        ),
        StaticInfoSection(
            headingEN: "Need help?",
            headingVI: "Cần hỗ trợ?",
            bodyEN: "If something isn't working or you want to report a problem, email kujira.gwer@gmail.com. Screenshots make bugs much easier to track down.",
            bodyVI: "Nếu có gì đó không hoạt động hoặc bạn muốn báo lỗi, hãy gửi email tới kujira.gwer@gmail.com. Đính kèm ảnh chụp màn hình sẽ giúp xử lý nhanh hơn."
        ),
    ]

    static let termsSections: [StaticInfoSection] = [
        StaticInfoSection(
            headingEN: "Who can use ConnectSphere",
            headingVI: "Ai được dùng ConnectSphere",
            bodyEN: "You must be 16 or older. You tell us your date of birth when you sign up; if we learn it isn't true, or that you are under 16, we may close the account.",
            bodyVI: "Bạn phải từ 16 tuổi trở lên. Bạn khai ngày sinh khi đăng ký; nếu chúng tôi biết khai không đúng, hoặc bạn chưa đủ 16 tuổi, tài khoản có thể bị đóng."
        ),
        StaticInfoSection(
            headingEN: "Agreeing to these terms",
            headingVI: "Đồng ý với điều khoản",
            bodyEN: "You agree by ticking the box when you create your account. We record which version of the Terms and Privacy Policy you agreed to and when. If we change them in a way that matters, the app asks you to agree again; if you don't, you can log out and delete your account. ConnectSphere is an academic project built for the COMP1682 course; it is provided as-is, with no promise of uptime or that data will never be lost.",
            bodyVI: "Bạn đồng ý bằng cách đánh dấu vào ô khi tạo tài khoản. Chúng tôi ghi lại bạn đã đồng ý phiên bản Điều khoản và Chính sách quyền riêng tư nào và vào lúc nào. Nếu chúng tôi thay đổi nội dung quan trọng, ứng dụng sẽ hỏi bạn đồng ý lại; nếu không đồng ý, bạn có thể đăng xuất và xoá tài khoản. ConnectSphere là sản phẩm học thuật thuộc đồ án COMP1682; dịch vụ được cung cấp nguyên trạng, không cam kết thời gian hoạt động hay dữ liệu sẽ không bao giờ mất."
        ),
        StaticInfoSection(
            headingEN: "Your conduct",
            headingVI: "Quy tắc ứng xử",
            bodyEN: "Don't post content that is illegal, hateful, sexually explicit, threatening or harassing. Don't impersonate others, spam, or share other people's private information. You can report content and block people. We may remove content and suspend or close accounts that break these rules, and we remove content that the authorities lawfully ask us to remove.",
            bodyVI: "Không đăng nội dung vi phạm pháp luật, thù ghét, khiêu dâm, đe doạ hay quấy rối. Không mạo danh, spam hoặc chia sẻ thông tin riêng tư của người khác. Bạn có thể báo cáo nội dung và chặn người khác. Chúng tôi có thể gỡ nội dung, tạm khoá hoặc đóng tài khoản vi phạm, và gỡ nội dung khi cơ quan có thẩm quyền yêu cầu theo đúng pháp luật."
        ),
        StaticInfoSection(
            headingEN: "Your content",
            headingVI: "Nội dung của bạn",
            bodyEN: "You keep ownership of what you post. You give ConnectSphere permission to store it, show it to the audience you chose (public, friends or only me), and make translated copies of it. Only post what you have the right to share.",
            bodyVI: "Bạn giữ quyền sở hữu nội dung mình đăng. Bạn cho phép ConnectSphere lưu trữ, hiển thị nội dung tới đúng phạm vi bạn chọn (công khai, bạn bè hoặc chỉ mình tôi) và tạo bản dịch. Chỉ đăng những gì bạn có quyền chia sẻ."
        ),
        StaticInfoSection(
            headingEN: "AI features",
            headingVI: "Tính năng AI",
            bodyEN: "Search, suggestions and translation use AI that runs on our own server. AI can be wrong, so check anything important. Text translated by AI is labelled, and you can switch back to the original.",
            bodyVI: "Tìm kiếm, gợi ý và dịch dùng AI chạy trên máy chủ của chúng tôi. AI có thể sai, hãy kiểm tra những điều quan trọng. Văn bản do AI dịch được ghi rõ và bạn có thể chuyển về bản gốc."
        ),
        StaticInfoSection(
            headingEN: "Marketplace and jobs",
            headingVI: "Chợ và việc làm",
            bodyEN: "Marketplace deals are between the buyer and the seller: ConnectSphere takes no payments and is not a party to any sale. Job posts come from companies and communities; ConnectSphere does not promise any job, and your application and CV go to the company you apply to. If you meet someone from the app, do it with care and in a public place.",
            bodyVI: "Giao dịch trên Chợ diễn ra giữa người mua và người bán: ConnectSphere không nhận thanh toán và không phải là một bên của giao dịch. Tin tuyển dụng do công ty và cộng đồng đăng; ConnectSphere không đảm bảo việc làm, hồ sơ và CV của bạn được gửi tới công ty bạn ứng tuyển. Nếu gặp ai đó quen qua ứng dụng, hãy cẩn thận và gặp ở nơi công cộng."
        ),
        StaticInfoSection(
            headingEN: "Your account",
            headingVI: "Tài khoản của bạn",
            bodyEN: "Keep your password safe; you are responsible for activity on your account. You can delete your account yourself in Profile › Settings › Manage account. Messages you sent stay in other people's chats under the name \"Deleted User\".",
            bodyVI: "Hãy giữ mật khẩu an toàn; bạn chịu trách nhiệm với hoạt động trên tài khoản. Bạn có thể tự xoá tài khoản trong Hồ sơ › Cài đặt › Quản lý tài khoản. Tin nhắn bạn đã gửi vẫn nằm trong cuộc trò chuyện của người khác dưới tên \"Deleted User\"."
        ),
        StaticInfoSection(
            headingEN: "Law and contact",
            headingVI: "Pháp luật và liên hệ",
            bodyEN: "These terms follow the law of Vietnam. ConnectSphere is run by the COMP1682 project team. Questions or requests: kujira.gwer@gmail.com.",
            bodyVI: "Các điều khoản này theo pháp luật Việt Nam. ConnectSphere do nhóm đồ án COMP1682 vận hành. Câu hỏi hoặc yêu cầu: kujira.gwer@gmail.com."
        ),
    ]

    static let privacySections: [StaticInfoSection] = [
        StaticInfoSection(
            headingEN: "Who we are",
            headingVI: "Chúng tôi là ai",
            bodyEN: "ConnectSphere is run by the COMP1682 project team (an academic project). For anything about your data, write to kujira.gwer@gmail.com.",
            bodyVI: "ConnectSphere do nhóm đồ án COMP1682 vận hành (sản phẩm học thuật). Mọi việc liên quan đến dữ liệu của bạn, hãy viết tới kujira.gwer@gmail.com."
        ),
        StaticInfoSection(
            headingEN: "What we collect",
            headingVI: "Dữ liệu chúng tôi thu thập",
            bodyEN: "• Account: username, password (stored hashed), email if you add one, Google account ID if you sign in with Google.\n• Profile: display name, date of birth, gender, province, bio, photos, interests, skills, work history and CV files you add.\n• What you create: posts, stories, comments, messages, photos, videos and voice messages. Photo location and camera data are removed before upload.\n• Marketplace (only if you sell): the item, its photos and price, and the place you pick on the map.\n• Use: likes, views, saved posts, searches and what you tap in results. This is used to rank your feed and search; it counts as sensitive behaviour data under Vietnamese law.\n• Sign-in alerts: the device name (for example iPhone · iOS) in emails.\nWe do not ask for ID documents and do not use advertising or analytics trackers.",
            bodyVI: "• Tài khoản: tên đăng nhập, mật khẩu (lưu dạng băm), email nếu bạn thêm, ID tài khoản Google nếu bạn đăng nhập bằng Google.\n• Hồ sơ: tên hiển thị, ngày sinh, giới tính, tỉnh/thành, giới thiệu, ảnh, sở thích, kỹ năng, quá trình làm việc và tệp CV bạn thêm.\n• Nội dung bạn tạo: bài viết, tin, bình luận, tin nhắn, ảnh, video, tin nhắn thoại. Vị trí và thông tin máy ảnh trong ảnh được xoá trước khi tải lên.\n• Chợ (chỉ khi bạn bán): món đồ, ảnh, giá và địa điểm bạn chọn trên bản đồ.\n• Sử dụng: lượt thích, lượt xem, bài đã lưu, lượt tìm kiếm và những gì bạn chạm vào trong kết quả. Dữ liệu này dùng để xếp hạng bảng tin và tìm kiếm; theo luật Việt Nam đây là dữ liệu hành vi nhạy cảm.\n• Cảnh báo đăng nhập: tên thiết bị (ví dụ iPhone · iOS) trong email.\nChúng tôi không yêu cầu giấy tờ tuỳ thân và không dùng công cụ theo dõi quảng cáo hay phân tích."
        ),
        StaticInfoSection(
            headingEN: "Why we use it",
            headingVI: "Mục đích sử dụng",
            bodyEN: "To run your account and the app; to show your posts to the audience you chose; to send you the codes and alerts you ask for; to suggest people, posts and jobs (your profile and posts are turned into numbers, called embeddings, that the AI compares); to translate; to keep the app safe; and to follow the law. We never sell your data.",
            bodyVI: "Để vận hành tài khoản và ứng dụng; hiển thị bài viết tới đúng đối tượng bạn chọn; gửi mã và cảnh báo bạn yêu cầu; gợi ý người, bài viết và việc làm (hồ sơ và bài viết được chuyển thành dãy số, gọi là embedding, để AI so sánh); dịch; giữ ứng dụng an toàn; và tuân thủ pháp luật. Chúng tôi không bán dữ liệu của bạn."
        ),
        StaticInfoSection(
            headingEN: "AI and your data",
            headingVI: "AI và dữ liệu của bạn",
            bodyEN: "Search, suggestions, tags and translation run on AI models on our own server, so your posts are not sent to outside AI companies for these. We do not use your content to train AI models. AI results are marked as AI when you see them (for example \"Translated by AI\"). If safety checks ever use an outside service, we will say so here first, and only the content being checked is sent.",
            bodyVI: "Tìm kiếm, gợi ý, thẻ và dịch chạy bằng mô hình AI trên máy chủ của chúng tôi, nên bài viết của bạn không được gửi cho công ty AI bên ngoài cho các việc này. Chúng tôi không dùng nội dung của bạn để huấn luyện mô hình AI. Kết quả AI được ghi rõ là AI khi bạn thấy (ví dụ \"Dịch bởi AI\"). Nếu việc kiểm tra an toàn dùng dịch vụ bên ngoài, chúng tôi sẽ nêu ở đây trước, và chỉ nội dung cần kiểm tra được gửi đi."
        ),
        StaticInfoSection(
            headingEN: "Who else receives data",
            headingVI: "Ai khác nhận dữ liệu",
            bodyEN: "• Brevo (email service): your email address and the code or sign-in alert we send.\n• Google: if you use Sign in with Google, Google checks your sign-in and gives us your name and email.\n• Apple Maps: place suggestions while you type a location come from Apple.\n• OpenStreetMap Nominatim and Wikipedia: place names and interest names from searches, to find locations and descriptions. No account information is sent.\n• Link previews: when you paste a link, our server asks that website for its title and image.\n• Hosting: our server stores your data.\nBrevo and Google process data outside Vietnam. Other people see what you share with them according to the audience you choose. Authorities can receive data when the law requires it.",
            bodyVI: "• Brevo (dịch vụ email): địa chỉ email của bạn và mã hoặc cảnh báo đăng nhập chúng tôi gửi.\n• Google: nếu bạn đăng nhập bằng Google, Google xác thực và cung cấp cho chúng tôi tên và email của bạn.\n• Apple Maps: gợi ý địa điểm khi bạn nhập vị trí do Apple cung cấp.\n• OpenStreetMap Nominatim và Wikipedia: tên địa điểm và tên sở thích từ tìm kiếm, để tìm vị trí và mô tả. Không gửi thông tin tài khoản.\n• Xem trước liên kết: khi bạn dán liên kết, máy chủ của chúng tôi hỏi trang web đó tiêu đề và ảnh.\n• Lưu trữ: máy chủ của chúng tôi lưu dữ liệu của bạn.\nBrevo và Google xử lý dữ liệu ngoài lãnh thổ Việt Nam. Người khác thấy nội dung bạn chia sẻ theo đối tượng bạn chọn. Cơ quan nhà nước có thể nhận dữ liệu khi pháp luật yêu cầu."
        ),
        StaticInfoSection(
            headingEN: "How long we keep it",
            headingVI: "Thời gian lưu trữ",
            bodyEN: "• Your account data: until you delete your account.\n• Posts and comments you delete: removed for good after 30 days.\n• Stories: removed when they expire.\n• Search history, post views and search sessions: 90 days.\n• Email codes and notifications: 90 days.\n• Messages: kept for the other people in the chat; after you delete your account they show \"Deleted User\".\n• Proof that you agreed to the Terms and Privacy Policy (user, version, date): kept after deletion.\nWe keep what the law requires us to keep longer.",
            bodyVI: "• Dữ liệu tài khoản: cho đến khi bạn xoá tài khoản.\n• Bài viết và bình luận bạn xoá: xoá hẳn sau 30 ngày.\n• Tin (story): xoá khi hết hạn.\n• Lịch sử tìm kiếm, lượt xem bài và phiên tìm kiếm: 90 ngày.\n• Mã email và thông báo: 90 ngày.\n• Tin nhắn: giữ cho những người khác trong cuộc trò chuyện; sau khi bạn xoá tài khoản sẽ hiện \"Deleted User\".\n• Bằng chứng bạn đã đồng ý Điều khoản và Chính sách quyền riêng tư (người dùng, phiên bản, ngày): giữ sau khi xoá.\nChúng tôi giữ lâu hơn những gì pháp luật yêu cầu."
        ),
        StaticInfoSection(
            headingEN: "Your rights",
            headingVI: "Quyền của bạn",
            bodyEN: "You can see and edit your profile in the app, delete your account in Profile › Settings › Manage account, block people, mute words, and choose each post's audience. You can download a copy of your data in Settings › Manage account › Download my data. You can also ask us to correct it, stop using it, or delete it: email kujira.gwer@gmail.com. We reply within 2 working days and act within 10 days (correction), 15 days (stop using) or 20 days (delete); these can be extended once for hard cases. You can withdraw your agreement at any time by deleting your account. If you think we handled your data wrongly, you can complain to the competent authority in Vietnam.",
            bodyVI: "Bạn có thể xem và sửa hồ sơ trong ứng dụng, xoá tài khoản trong Hồ sơ › Cài đặt › Quản lý tài khoản, chặn người khác, ẩn từ khoá và chọn đối tượng cho từng bài đăng. Bạn có thể tải bản sao dữ liệu trong Cài đặt › Quản lý tài khoản › Tải dữ liệu của tôi. Bạn cũng có thể yêu cầu chúng tôi sửa, ngừng sử dụng hoặc xoá dữ liệu: gửi email tới kujira.gwer@gmail.com. Chúng tôi phản hồi trong 2 ngày làm việc và xử lý trong 10 ngày (sửa), 15 ngày (ngừng sử dụng) hoặc 20 ngày (xoá); có thể gia hạn một lần với trường hợp phức tạp. Bạn có thể rút lại sự đồng ý bất cứ lúc nào bằng cách xoá tài khoản. Nếu cho rằng dữ liệu bị xử lý sai, bạn có thể khiếu nại tới cơ quan có thẩm quyền của Việt Nam."
        ),
        StaticInfoSection(
            headingEN: "Security and changes",
            headingVI: "Bảo mật và thay đổi",
            bodyEN: "Passwords are hashed with bcrypt and your sign-in token is kept in the iOS Keychain. No system is perfectly safe; if a breach affects you, we will tell you and the authorities within 72 hours as the law requires. This policy has a version; when it changes, the app asks you to read and agree again.",
            bodyVI: "Mật khẩu được băm bằng bcrypt và token đăng nhập lưu trong Keychain của iOS. Không hệ thống nào an toàn tuyệt đối; nếu có vi phạm ảnh hưởng đến bạn, chúng tôi sẽ thông báo cho bạn và cơ quan chức năng trong 72 giờ theo quy định. Chính sách này có số phiên bản; khi thay đổi, ứng dụng sẽ yêu cầu bạn đọc và đồng ý lại."
        ),
    ]

    /// Open-source notices (Apache License 2.0 asks that the licence and notices travel with the app).
    static let acknowledgementSections: [StaticInfoSection] = [
        StaticInfoSection(
            headingEN: "Open-source software",
            headingVI: "Phần mềm mã nguồn mở",
            bodyEN: "ConnectSphere includes the following open-source software. Each is used under the Apache License, Version 2.0 (apache.org/licenses/LICENSE-2.0), and remains the property of its authors.",
            bodyVI: "ConnectSphere có sử dụng các phần mềm mã nguồn mở sau. Mỗi thành phần được dùng theo Giấy phép Apache, Phiên bản 2.0 (apache.org/licenses/LICENSE-2.0) và vẫn thuộc về tác giả của nó."
        ),
        StaticInfoSection(
            headingEN: "Sign in with Google",
            headingVI: "Đăng nhập bằng Google",
            bodyEN: "GoogleSignIn-iOS, AppAuth-iOS, GTMAppAuth, GTMSessionFetcher, GoogleUtilities, App Check and Promises: Copyright Google LLC and the OpenID Foundation contributors. Licensed under the Apache License, Version 2.0.",
            bodyVI: "GoogleSignIn-iOS, AppAuth-iOS, GTMAppAuth, GTMSessionFetcher, GoogleUtilities, App Check và Promises: Bản quyền Google LLC và những người đóng góp của OpenID Foundation. Cấp phép theo Giấy phép Apache, Phiên bản 2.0."
        ),
        StaticInfoSection(
            headingEN: "AI models",
            headingVI: "Mô hình AI",
            bodyEN: "Search, suggestions and translation run on open models on our own server, each under the Apache License, Version 2.0: Qwen2.5 and Qwen3 (Alibaba Cloud, Qwen team) and mxbai-embed-large (Mixedbread). They are run with Ollama (MIT licence).",
            bodyVI: "Tìm kiếm, gợi ý và dịch chạy bằng các mô hình mở trên máy chủ của chúng tôi, mỗi mô hình theo Giấy phép Apache, Phiên bản 2.0: Qwen2.5 và Qwen3 (Alibaba Cloud, nhóm Qwen) và mxbai-embed-large (Mixedbread). Các mô hình được chạy bằng Ollama (giấy phép MIT)."
        ),
        StaticInfoSection(
            headingEN: "Maps and places",
            headingVI: "Bản đồ và địa điểm",
            bodyEN: "Place search uses Apple Maps. Some place names come from OpenStreetMap contributors (openstreetmap.org/copyright, ODbL) and Wikipedia (CC BY-SA).",
            bodyVI: "Tìm địa điểm dùng Apple Maps. Một số tên địa điểm lấy từ những người đóng góp OpenStreetMap (openstreetmap.org/copyright, ODbL) và Wikipedia (CC BY-SA)."
        ),
    ]
}
