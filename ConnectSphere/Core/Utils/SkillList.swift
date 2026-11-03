import Foundation

/// How many skills a list may hold (the server enforces the same caps;
/// the skills themselves come from the catalogue, `SkillPickerView`).
enum SkillList {
    static let profileLimit = 30
    static let jobLimit = 10
}
