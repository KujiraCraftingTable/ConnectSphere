import Foundation

/// The rules for a skill list, wherever skills are typed in: one at a time,
/// no case-insensitive duplicates, a length and a count cap (the server
/// enforces the same ones).
enum SkillList {
    static let profileLimit = 30
    static let jobLimit = 10
    static let maxLength = 50

    struct Result: Equatable {
        var skills: [String]
        /// Why something typed wasn't added, if it wasn't.
        var problem: String?
    }

    /// Adds what was typed. A comma also separates skills, so a pasted
    /// "Swift, Kotlin" becomes two.
    static func adding(_ text: String, to skills: [String], limit: Int, maxLength: Int = maxLength) -> Result {
        var list = skills
        var problem: String?
        for part in text.split(separator: ",") {
            let skill = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !skill.isEmpty else { continue }
            if skill.count > maxLength {
                problem = String(format: Bundle.app.loc("Keep each skill under %lld characters."), maxLength)
            } else if list.contains(where: { $0.caseInsensitiveCompare(skill) == .orderedSame }) {
                problem = String(format: Bundle.app.loc("You already added %@."), skill)
            } else if list.count >= limit {
                problem = String(format: Bundle.app.loc("Up to %lld skills."), limit)
                break
            } else {
                list.append(skill)
            }
        }
        return Result(skills: list, problem: problem)
    }
}
