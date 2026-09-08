import Foundation

/// Node's `JSON.stringify` keeps `"key": null`; Swift's `JSONEncoder` drops nil
/// Optionals. Wrapping an optional response field in `@NullCoded` forces the key
/// to be emitted as `null`, so response bodies match the Node contract.
///
/// Decoding is tolerant: an absent key OR an explicit null both yield `nil`
/// (so the same wrapper is safe on structs that also decode SQL rows).
@propertyWrapper
struct NullCoded<T: Codable & Sendable>: Codable, Sendable {
    var wrappedValue: T?
    init(wrappedValue: T?) { self.wrappedValue = wrappedValue }

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        wrappedValue = c.decodeNil() ? nil : try? c.decode(T.self)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        if let v = wrappedValue { try c.encode(v) } else { try c.encodeNil() }
    }
}

extension KeyedDecodingContainer {
    /// A `@NullCoded` property is non-optional, so the synthesized decoder calls
    /// `decode(_:forKey:)` and throws on an absent key. This makes an absent key
    /// decode as `NullCoded(nil)` too.
    func decode<T>(_ type: NullCoded<T>.Type, forKey key: Key) throws -> NullCoded<T> {
        try decodeIfPresent(type, forKey: key) ?? NullCoded<T>(wrappedValue: nil)
    }
}
