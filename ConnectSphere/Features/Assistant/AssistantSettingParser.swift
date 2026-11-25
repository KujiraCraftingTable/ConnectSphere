import Foundation

// MARK: - Setting changes
/// A safe setting the assistant changes itself. Privacy and security
/// settings are never here: for those it only explains and opens the screen.
enum AssistantSettingChange: Equatable {
    case messageSounds(Bool)
    case aiSuggestions(Bool)
    case translations(TranslationMode)
    /// Kilometres in 5 km steps; 0 is no limit.
    case searchRadius(Int)
    /// A palette id; whether it suits the current mode is checked on apply.
    case themeColor(String)
    case appIcon(String)
}

// MARK: - Parser
/// Reads commands that carry a value, which fixed phrases can't: which way a
/// switch goes ("turn off message sounds", "tắt âm thanh"), a distance
/// ("search radius 10 km") or a name ("make my theme amber"). Runs before
/// `AssistantMatcher`; nil hands the text over to it.
enum AssistantSettingParser {
    private static let offWords: Set<String> = ["off", "disable", "mute", "silence", "stop", "tat"]
    private static let onWords: Set<String> = ["on", "enable", "unmute", "bat"]
    /// "don't turn off sounds" isn't a command to act on.
    private static let refusals: Set<String> = ["don't", "dont", "not", "never", "đừng", "không", "chưa"]

    static func parse(_ input: String) -> AssistantIntent? {
        let raw = input.lowercased()
        let rawWords = raw.components(separatedBy: .whitespacesAndNewlines.union(.punctuationCharacters).subtracting(["'"]))
        guard !rawWords.contains(where: refusals.contains) else { return nil }
        let words = AssistantMatcher.reduce(input)
        guard !words.isEmpty else { return nil }
        let text = " " + words.joined(separator: " ") + " "
        func has(_ any: String...) -> Bool { any.contains { text.contains(" \($0) ") } }

        let turnsOff = words.contains(where: offWords.contains)
        let turnsOn = !turnsOff && words.contains(where: onWords.contains)

        // Turning a theme off means the other one.
        if turnsOff, has("dark", "dark mode", "che do toi") { return .setTheme(.light) }
        if turnsOff, has("light", "light mode", "che do sang") { return .setTheme(.dark) }

        if turnsOff || turnsOn {
            if has("sound", "sounds", "am thanh") { return .changeSetting(.messageSounds(turnsOn)) }
            if has("suggestion", "suggestions", "goi y") { return .changeSetting(.aiSuggestions(turnsOn)) }
        }

        if has("radius", "distance", "ban kinh", "khoang cach") {
            if has("unlimited", "no limit", "khong gioi han", "anywhere") { return .changeSetting(.searchRadius(0)) }
            if let km = firstNumber(in: raw) { return .changeSetting(.searchRadius(RadiusScale.snapped(km))) }
        }

        if has("translation", "translations", "translate", "translated", "ban dich", "dich") {
            if has("original", "goc") { return .changeSetting(.translations(.original)) }
            if has("translated", "auto", "automatically", "always", "tu dong") || turnsOn {
                return .changeSetting(.translations(.translated))
            }
            if turnsOff { return .changeSetting(.translations(.original)) }
        }

        // A chat's own theme is set inside that chat, not app-wide.
        if has("chat", "conversation", "doan chat", "cuoc tro chuyen") { return nil }
        if has("icon", "bieu tuong"), let id = paletteId(in: text) { return .changeSetting(.appIcon(id)) }
        if has("theme", "color", "colour", "mau"), let id = paletteId(in: text) {
            return .changeSetting(.themeColor(id))
        }
        return nil
    }

    // MARK: - Palettes and numbers
    /// Every palette, each once (Blue is in both modes).
    static var palettes: [ThemePalette] {
        var seen = Set<String>()
        return (ThemePalette.socialPalettes + ThemePalette.workPalettes).filter { seen.insert($0.id).inserted }
    }

    private static func paletteId(in text: String) -> String? {
        // Longest name first, so "deep purple" isn't read as something shorter.
        palettes.sorted { $0.name.count > $1.name.count }
            .first { text.contains(" \(AssistantMatcher.fold($0.name.lowercased())) ") }?.id
    }

    private static func firstNumber(in text: String) -> Int? {
        guard let range = text.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(text[range])
    }
}
