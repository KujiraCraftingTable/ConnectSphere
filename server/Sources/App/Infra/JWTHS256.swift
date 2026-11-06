import Foundation
import Crypto

/// Hand-rolled HS256 JWT: header `{"alg":"HS256","typ":"JWT"}`, payload
/// `{"sub":…,"iat":…,"exp":…}`, base64url (no padding), `HMAC-SHA256` signature
/// keyed by `JWT_SECRET`.
enum JWTHS256 {
    struct Payload {
        var sub: String
        var iat: Int
        var exp: Int
    }

    enum JWTError: Error, Equatable {
        case malformed
        case badAlgorithm
        case badSignature
        case expired
        case missingSub
    }

    static func sign(sub: String, secret: String, expiresIn: String, now: Date = Date()) -> String {
        let iat = Int(now.timeIntervalSince1970)
        let exp = iat + seconds(from: expiresIn)
        let header = #"{"alg":"HS256","typ":"JWT"}"#
        // Key order: sub, then iat, then exp.
        let payload = #"{"sub":"\#(sub)","iat":\#(iat),"exp":\#(exp)}"#
        let signingInput = b64(Data(header.utf8)) + "." + b64(Data(payload.utf8))
        let sig = HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: .init(data: Data(secret.utf8)))
        return signingInput + "." + b64(Data(sig))
    }

    static func verify(_ token: String, secret: String, now: Date = Date()) throws -> Payload {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw JWTError.malformed }
        let signingInput = "\(parts[0]).\(parts[1])"

        guard let headerData = b64Decode(String(parts[0])),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              (header["alg"] as? String) == "HS256"
        else { throw JWTError.badAlgorithm }

        let expected = HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: .init(data: Data(secret.utf8)))
        guard let providedSig = b64Decode(String(parts[2])),
              Data(expected).count == providedSig.count,
              HMAC<SHA256>.isValidAuthenticationCode(providedSig, authenticating: Data(signingInput.utf8), using: .init(data: Data(secret.utf8)))
        else { throw JWTError.badSignature }

        guard let payloadData = b64Decode(String(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else { throw JWTError.malformed }

        guard let sub = obj["sub"] as? String, !sub.isEmpty else { throw JWTError.missingSub }
        let iat = (obj["iat"] as? Int) ?? Int((obj["iat"] as? Double) ?? 0)
        let exp = (obj["exp"] as? Int) ?? Int((obj["exp"] as? Double) ?? 0)
        if exp != 0, Double(exp) < now.timeIntervalSince1970 { throw JWTError.expired }
        return Payload(sub: sub, iat: iat, exp: exp)
    }

    /// Duration: bare number = seconds, or suffix s/m/h/d.
    static func seconds(from spec: String) -> Int {
        let s = spec.trimmingCharacters(in: .whitespaces)
        if let n = Int(s) { return n }
        guard let unit = s.last, let value = Int(s.dropLast()) else { return 90 * 86400 }
        switch unit {
        case "s": return value
        case "m": return value * 60
        case "h": return value * 3600
        case "d": return value * 86400
        default:  return 90 * 86400
        }
    }

    // MARK: base64url

    static func b64(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func b64Decode(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while str.count % 4 != 0 { str.append("=") }
        return Data(base64Encoded: str)
    }
}
