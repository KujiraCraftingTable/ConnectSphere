import Foundation

struct PostAnalyzeDTO: Decodable {
    let suggestedMode: String   // "hobby" | "work" | "neutral"
    let confidence:    Double
    let reason:        String
    let isMismatch:    Bool
}
