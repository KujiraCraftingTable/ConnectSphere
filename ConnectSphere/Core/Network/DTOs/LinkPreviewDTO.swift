import Foundation

struct LinkPreviewDTO: Decodable {
    let url:         String
    let title:       String
    let description: String?
    let image:       String?
    let siteName:    String?
}
