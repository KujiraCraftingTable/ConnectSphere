import Foundation

struct PostAnalyzeDTO: Decodable {
    let suggestedMode: String   // "friend" | "colleague" | "neutral"
    let confidence:    Double
    let reason:        String
    let isMismatch:    Bool
}
