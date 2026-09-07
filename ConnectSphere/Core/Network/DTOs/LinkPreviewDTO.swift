import Foundation

struct LinkPreviewDTO: Decodable {
    let url:         String
    let title:       String
    let description: String?
    let image:       String?
    let siteName:    String?

    enum CodingKeys: String, CodingKey { case url, title, description, image, siteName }
}

// init(from:) in an extension so the memberwise initializer is still synthesized
// (tests/previews construct LinkPreviewDTO directly).
extension LinkPreviewDTO {
    // A page with no <title>/og:title returns title: null — decode leniently so
    // the link card just shows the host instead of the whole decode failing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url         = try c.decode(String.self, forKey: .url)
        title       = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description)
        image       = try c.decodeIfPresent(String.self, forKey: .image)
        siteName    = try c.decodeIfPresent(String.self, forKey: .siteName)
    }
}
