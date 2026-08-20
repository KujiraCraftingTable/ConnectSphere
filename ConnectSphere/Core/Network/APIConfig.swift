import Foundation

/// Single source of truth for all backend URLs.
/// Base URL đọc từ Info.plist (key `APIBaseURL`) để đổi được theo môi trường
/// (device thật/production) mà không sửa code; fallback localhost cho dev.
enum APIConfig {
    static let serverBase: String = {
        // Simulator chạy chung máy với backend → luôn dùng localhost,
        // tránh chết khi APIBaseURL trỏ IP LAN của mạng WiFi cũ.
        #if targetEnvironment(simulator)
        return "http://localhost:3000"
        #else
        return (Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "http://localhost:3000"
        #endif
    }()

    static let baseURL = "\(serverBase)/api"
}
