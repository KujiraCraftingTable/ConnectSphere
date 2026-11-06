import Vapor
import AsyncHTTPClient
import NIOCore

/// POST /api/link-preview, port of `backend/src/routes/linkPreviewRoutes.js`.
/// Keeps the SSRF guard (block localhost / private / link-local / CGNAT /
/// multicast, re-check every redirect hop), oEmbed-first for known providers,
/// OG-tag scrape (≤150 KB) as fallback, and "return minimal metadata, still
/// 200" on any fetch failure.
struct LinkPreviewController {
    static let maxRedirects = 4

    static func register(routes: any RoutesBuilder) {
        routes.grouped("link-preview").grouped(AuthMiddleware()).post(use: preview)
    }

    struct Body: Content { var url: String? }
    struct PreviewResponse: Content {
        var url: String
        @NullCoded var title: String?
        @NullCoded var description: String?
        @NullCoded var image: String?
        @NullCoded var siteName: String?
    }

    static func preview(_ req: Request) async throws -> PreviewResponse {
        guard let raw = try req.content.decode(Body.self).url, !raw.isEmpty else {
            throw InlineError(.badRequest, "url is required")
        }
        guard let parsed = URLComponents(string: raw), let host = parsed.host,
              let scheme = parsed.scheme?.lowercased() else {
            throw InlineError(.badRequest, "Invalid URL")
        }
        guard scheme == "http" || scheme == "https" else {
            throw InlineError(.badRequest, "Only http/https URLs allowed")
        }
        do { try await assertPublicHost(host, on: req.eventLoop) }
        catch { throw InlineError(.badRequest, "URL not allowed") }

        let fallback = PreviewResponse(url: raw, title: host, description: nil, image: nil, siteName: host)
        do {
            let meta: Meta
            if let oembed = try await fetchOEmbed(raw, client: req.application.http.client.shared) {
                meta = oembed
            } else {
                meta = try await fetchOGTags(raw, client: req.application.http.client.shared, on: req.eventLoop)
            }
            return PreviewResponse(url: raw, title: meta.title ?? host, description: meta.description,
                                   image: meta.image, siteName: meta.siteName ?? host)
        } catch {
            req.logger.warning("Link preview failed for \(raw): \(error)")
            return fallback
        }
    }

    // MARK: SSRF guard

    struct BlockedHost: Error {}

    static func isPrivateIP(_ ip: String) -> Bool {
        if ip.contains(":") {
            let v6 = ip.lowercased()
            if v6.hasPrefix("::ffff:") { return isPrivateIP(String(v6.dropFirst(7))) }
            return v6 == "::1" || v6 == "::" || v6.hasPrefix("fe80") || v6.hasPrefix("fc") || v6.hasPrefix("fd")
        }
        let parts = ip.split(separator: ".").map { Int($0) }
        guard parts.count == 4, !parts.contains(nil) else { return true }
        let p = parts.map { $0! }
        let a = p[0], b = p[1]
        return a == 0 || a == 10 || a == 127
            || (a == 169 && b == 254)
            || (a == 172 && b >= 16 && b <= 31)
            || (a == 192 && b == 168)
            || (a == 100 && b >= 64 && b <= 127)
            || a >= 224
    }

    static func assertPublicHost(_ hostname: String, on eventLoop: EventLoop) async throws {
        let host = hostname.lowercased()
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".internal") { throw BlockedHost() }
        if host.isIPAddress {
            if isPrivateIP(host) { throw BlockedHost() }
            return
        }
        // Synchronous getaddrinfo via NIO. Mirrors Node's `dns.lookup` (one
        // resolved address). Off the event loop.
        let resolved: SocketAddress = try await eventLoop.makeFutureWithTask {
            try SocketAddress.makeAddressResolvingHost(host, port: 80)
        }.get()
        if let ip = resolved.ipAddress, isPrivateIP(ip) { throw BlockedHost() }
    }

    // MARK: fetching

    struct Meta { var title: String?; var description: String?; var image: String?; var siteName: String? }

    static let oembedProviders: [(NSRegularExpression, (String) -> String)] = {
        func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: .caseInsensitive) }
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s }
        return [
            (re("youtube\\.com/watch|youtu\\.be/"), { "https://www.youtube.com/oembed?url=\(enc($0))&format=json" }),
            (re("vimeo\\.com/"), { "https://vimeo.com/api/oembed.json?url=\(enc($0))" }),
            (re("twitter\\.com/|x\\.com/"), { "https://publish.twitter.com/oembed?url=\(enc($0))" }),
            (re("instagram\\.com/"), { "https://api.instagram.com/oembed?url=\(enc($0))" }),
            (re("open\\.spotify\\.com/"), { "https://open.spotify.com/oembed?url=\(enc($0))" }),
            (re("soundcloud\\.com/"), { "https://soundcloud.com/oembed?format=json&url=\(enc($0))" }),
        ]
    }()

    static func fetchOEmbed(_ url: String, client: HTTPClient) async throws -> Meta? {
        guard let provider = oembedProviders.first(where: { $0.0.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil }) else {
            return nil
        }
        var request = HTTPClientRequest(url: provider.1(url))
        request.headers.add(name: "User-Agent", value: "ConnectSphere/1.0")
        do {
            let response = try await client.execute(request, timeout: .seconds(6))
            guard (200..<300).contains(Int(response.status.code)) else { return nil }
            let body = try await response.body.collect(upTo: 256 * 1024)
            struct O: Decodable { let title: String?; let thumbnail_url: String?; let provider_name: String? }
            let o = try JSONDecoder().decode(O.self, from: Data(buffer: body))
            return Meta(title: o.title, description: nil, image: o.thumbnail_url, siteName: o.provider_name)
        } catch { return nil }
    }

    static func fetchOGTags(_ startURL: String, client: HTTPClient, on eventLoop: EventLoop) async throws -> Meta {
        var url = startURL
        var html = ""
        for hop in 0...maxRedirects {
            guard let comps = URLComponents(string: url), let scheme = comps.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", let host = comps.host else {
                throw BlockedHost()
            }
            try await assertPublicHost(host, on: eventLoop)
            var request = HTTPClientRequest(url: url)
            request.headers.add(name: "User-Agent", value: "Mozilla/5.0 (compatible; ConnectSphere/1.0; +https://connectsphere.app)")
            request.headers.add(name: "Accept", value: "text/html,application/xhtml+xml")
            let response = try await client.execute(request, timeout: .seconds(8))
            let code = Int(response.status.code)
            if code >= 300 && code < 400, let loc = response.headers.first(name: "location") {
                if hop == maxRedirects { throw Abort(.badRequest, reason: "Too many redirects") }
                url = URL(string: loc, relativeTo: URL(string: url))?.absoluteString ?? loc
                continue
            }
            guard (200..<300).contains(code) else { throw Abort(.badGateway, reason: "HTTP \(code)") }
            let body = try await response.body.collect(upTo: 150_000)
            html = String(decoding: body.readableBytesView.prefix(150_000), as: UTF8.self)
            break
        }
        return parseMeta(html)
    }

    static func parseMeta(_ html: String) -> Meta {
        func firstGroup(_ pattern: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: html) else { return nil }
            return String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func og(_ prop: String) -> String? {
            firstGroup("property=[\"']\(prop)[\"'][^>]*content=[\"']([^\"']+)[\"']")
                ?? firstGroup("content=[\"']([^\"']+)[\"'][^>]*property=[\"']\(prop)[\"']")
        }
        func meta(_ name: String) -> String? {
            firstGroup("name=[\"']\(name)[\"'][^>]*content=[\"']([^\"']+)[\"']")
                ?? firstGroup("content=[\"']([^\"']+)[\"'][^>]*name=[\"']\(name)[\"']")
        }
        return Meta(
            title: og("og:title") ?? firstGroup("<title[^>]*>([^<]+)</title>"),
            description: og("og:description") ?? meta("description"),
            image: og("og:image"),
            siteName: og("og:site_name")
        )
    }
}

extension String {
    var isIPAddress: Bool {
        var a4 = in_addr(); var a6 = in6_addr()
        return withCString { inet_pton(AF_INET, $0, &a4) == 1 || inet_pton(AF_INET6, $0, &a6) == 1 }
    }
}
