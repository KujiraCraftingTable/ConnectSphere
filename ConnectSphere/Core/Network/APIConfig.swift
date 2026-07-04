import Foundation

/// Single source of truth for all backend URLs.
/// Base URL đọc từ Info.plist (key `APIBaseURL`) để đổi được theo môi trường
/// (simulator/device/production) mà không sửa code; fallback localhost cho dev.
enum APIConfig {
    static let serverBase: String = {
        (Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "http://localhost:3000"
    }()

    static let baseURL = "\(serverBase)/api"
}
