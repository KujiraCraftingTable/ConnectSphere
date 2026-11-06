import Foundation

struct MockData {

    // MARK: - Current User

    /// Neutral placeholder used only as a last-resort fallback for a nil
    /// `appState.currentUser` (which shouldn't happen while logged in). It must
    /// carry NO real person's data. A nil user should never render as someone
    /// specific.
    static let currentUser = UserProfile(
        id: "", name: "You", username: "you",
        avatarColor: "#9E9E9E", bio: "",
        jobTitle: nil, company: nil,
        skills: [], interests: [],
        location: nil,
        followerCount: 0, followingCount: 0, postCount: 0
    )

    // MARK: - Users

    static let users: [UserProfile] = [
        UserProfile(id: "1", name: "Linh Nguyễn", username: "linhnguyen",
                    avatarColor: "#E91E63", bio: "Art lover & travel enthusiast 🌍",
                    jobTitle: "UX Designer", company: "Blue Harbor Studio",
                    skills: ["Figma", "UI/UX", "Prototyping", "Research"],
                    interests: ["Art", "Travel", "Photography", "Movies"],
                    location: "Hanoi",
                    followerCount: 342, followingCount: 210, postCount: 56),
        UserProfile(id: "2", name: "Minh Trần", username: "minhtran",
                    avatarColor: "#4CAF50", bio: "Full-stack dev | Music producer 🎵",
                    jobTitle: "Backend Engineer", company: "Saigon Byte",
                    skills: ["Kotlin", "PostgreSQL", "Docker", "Go"],
                    interests: ["Music", "Gaming", "Coding", "Coffee"],
                    location: "Ho Chi Minh City",
                    followerCount: 189, followingCount: 145, postCount: 32),
        UserProfile(id: "3", name: "Thu Hà", username: "thuha",
                    avatarColor: "#FF9800", bio: "Bookworm & yoga instructor 📚",
                    jobTitle: "Product Manager", company: "Lotus Market",
                    skills: ["Product Strategy", "Agile", "Analytics", "Roadmapping"],
                    interests: ["Books", "Yoga", "Cooking", "Travel"],
                    location: "Da Nang",
                    followerCount: 521, followingCount: 302, postCount: 87),
        UserProfile(id: "4", name: "Khoa Lê", username: "khoale",
                    avatarColor: "#9C27B0", bio: "Startup founder | Tech enthusiast 🚀",
                    jobTitle: "CEO", company: "TechVN Ventures",
                    skills: ["Leadership", "Fundraising", "Strategy", "Networking"],
                    interests: ["Startups", "Tech", "Football", "Investing"],
                    location: "Ho Chi Minh City",
                    followerCount: 1203, followingCount: 432, postCount: 145),
        UserProfile(id: "5", name: "Mai Phương", username: "maiphuong",
                    avatarColor: "#00BCD4", bio: "Coffee addict & street food lover ☕🍜",
                    jobTitle: "Marketing Manager", company: "Mekong Retail",
                    skills: ["Marketing", "SEO", "Content Strategy", "Analytics"],
                    interests: ["Food", "Coffee", "K-drama", "Shopping"],
                    location: "Ho Chi Minh City",
                    followerCount: 678, followingCount: 234, postCount: 92),
        UserProfile(id: "6", name: "Đức Anh", username: "ducanh",
                    avatarColor: "#FF5722", bio: "Photographer & coffee shop hopper 📷",
                    jobTitle: "Creative Director", company: "Little Crane Creative",
                    skills: ["Photography", "Branding", "Creative Direction", "Copywriting"],
                    interests: ["Photography", "Coffee", "Cinema", "Jazz"],
                    location: "Ho Chi Minh City",
                    followerCount: 892, followingCount: 156, postCount: 203),
    ]

    // MARK: - Friend Posts

    static let friendPosts: [Post] = [
        Post(id: "f1", author: users[0],
             content: "Vừa xem xong Dune: Part Two, đỉnh quá! Ai đã xem chưa? 🎬✨",
             timestamp: Date().addingTimeInterval(-3600),
             mode: .hobby, likeCount: 24, commentCount: 8, shareCount: 2,
             articleTitle: nil, tags: []),
        Post(id: "f2", author: users[1],
             content: "Weekend này mình đi Đà Lạt, ai muốn đi cùng không? 🌿🏔️ Dự 3 ngày 2 đêm!",
             timestamp: Date().addingTimeInterval(-7200),
             mode: .hobby, likeCount: 47, commentCount: 15, shareCount: 5,
             articleTitle: nil, tags: []),
        Post(id: "f3", author: users[2],
             content: "Mới học được cách pha cà phê cold brew tại nhà, ngon bất ngờ 😍☕ Recipe trong comment nha!",
             timestamp: Date().addingTimeInterval(-14400),
             mode: .hobby, likeCount: 62, commentCount: 21, shareCount: 8,
             articleTitle: nil, tags: []),
        Post(id: "f4", author: users[3],
             content: "Happy birthday to me! 🎂🎉 26 tuổi nhưng vẫn cảm thấy như 16 🙈 Cảm ơn mọi người đã chúc mừng!",
             timestamp: Date().addingTimeInterval(-86400),
             mode: .hobby, likeCount: 134, commentCount: 56, shareCount: 3,
             articleTitle: nil, tags: []),
        Post(id: "f5", author: users[4],
             content: "Ai ở Sài Gòn hay ăn bánh mì Hòa Mã chưa? Ngon nhất Sài Gòn mà ít người biết 🥖 Địa chỉ: 53 Cao Thắng, Q3",
             timestamp: Date().addingTimeInterval(-172800),
             mode: .hobby, likeCount: 89, commentCount: 34, shareCount: 12,
             articleTitle: nil, tags: []),
    ]

    // MARK: - Colleague Posts

    static let colleaguePosts: [Post] = [
        Post(id: "c1", author: users[0],
             content: "Vừa hoàn thiện design system mới cho dự án. Consistency là chìa khóa để scale một sản phẩm! 💡",
             timestamp: Date().addingTimeInterval(-3600),
             mode: .work, likeCount: 45, commentCount: 12, shareCount: 7,
             articleTitle: "Building a Scalable Design System in 2024",
             tags: ["Design", "UIDesign", "ProductDesign"]),
        Post(id: "c2", author: users[1],
             content: "Chia sẻ kinh nghiệm optimize PostgreSQL query từ 8s xuống còn 120ms. Thread dài nhưng đáng đọc 🧵",
             timestamp: Date().addingTimeInterval(-7200),
             mode: .work, likeCount: 128, commentCount: 34, shareCount: 45,
             articleTitle: "PostgreSQL Query Optimization: From 8s to 120ms",
             tags: ["Backend", "PostgreSQL", "Performance"]),
        Post(id: "c3", author: users[2],
             content: "Product roadmap Q3 vừa được approve! Shipped 12/14 features đúng deadline trong Q2 🚀",
             timestamp: Date().addingTimeInterval(-14400),
             mode: .work, likeCount: 67, commentCount: 18, shareCount: 9,
             articleTitle: nil,
             tags: ["Product", "Roadmap", "AgileDelivery"]),
        Post(id: "c4", author: users[3],
             content: "Startup lesson #47: Raise money khi không cần, đừng đợi khi cần mới raise. Kinh nghiệm đau thương từ series A.",
             timestamp: Date().addingTimeInterval(-86400),
             mode: .work, likeCount: 234, commentCount: 89, shareCount: 67,
             articleTitle: "Fundraising Timing: Lessons from My Series A",
             tags: ["Startup", "Fundraising", "Leadership"]),
        Post(id: "c5", author: users[4],
             content: "Marketing không phải là spam. Framework mình dùng để xây dựng content strategy đạt 3x organic growth trong 6 tháng.",
             timestamp: Date().addingTimeInterval(-172800),
             mode: .work, likeCount: 156, commentCount: 43, shareCount: 38,
             articleTitle: "Content Strategy Framework That Drives 3x Growth",
             tags: ["Marketing", "ContentStrategy", "GrowthHacking"]),
    ]

}
