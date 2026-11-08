// ThemeManager, owns palette selection per app mode.
// Inject at app root via .environment(themeManager).
// currentMode is synced from AppState via .onChange in ConnectSphereApp.

import Combine
import SwiftUI
import Observation

// MARK: - ThemePalette

struct ThemePalette: Identifiable {
    let id: String
    let name: String
    let primary: Color
    let secondary: Color
    let accent: Color

    var primaryGradient: LinearGradient {
        LinearGradient(colors: [primary, secondary], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var accentGradient: LinearGradient {
        LinearGradient(colors: [secondary, accent], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var softFill: Color   { primary.opacity(0.12) }
    var softBorder: Color { primary.opacity(0.25) }
    var onPrimary: Color  { .white }
}

// MARK: - Palette Definitions

extension ThemePalette {
    // Social / Friend palettes
    static let sunset     = ThemePalette(id: "sunset",      name: "Sunset",      primary: Color(hex: "#FF6B6B"), secondary: Color(hex: "#FF8E53"), accent: Color(hex: "#FFCA45"))
    static let tropical   = ThemePalette(id: "tropical",    name: "Tropical",    primary: Color(hex: "#00C9A7"), secondary: Color(hex: "#0096C7"), accent: Color(hex: "#90E0EF"))
    static let candy      = ThemePalette(id: "candy",       name: "Candy",       primary: Color(hex: "#F72585"), secondary: Color(hex: "#7209B7"), accent: Color(hex: "#C77DFF"))
    static let amber      = ThemePalette(id: "amber",       name: "Amber",       primary: Color(hex: "#F59E0B"), secondary: Color(hex: "#D97706"), accent: Color(hex: "#FDE68A"))
    static let blueShared = ThemePalette(id: "blue",        name: "Blue",        primary: Color(hex: "#3B82F6"), secondary: Color(hex: "#2563EB"), accent: Color(hex: "#93C5FD"))
    static let rose       = ThemePalette(id: "rose",        name: "Rose",        primary: Color(hex: "#F43F5E"), secondary: Color(hex: "#E11D48"), accent: Color(hex: "#FDA4AF"))

    // Work / Colleague palettes
    static let navy       = ThemePalette(id: "navy",        name: "Navy",        primary: Color(hex: "#1D4ED8"), secondary: Color(hex: "#1E40AF"), accent: Color(hex: "#93C5FD"))
    static let slate      = ThemePalette(id: "slate",       name: "Slate",       primary: Color(hex: "#475569"), secondary: Color(hex: "#334155"), accent: Color(hex: "#94A3B8"))
    static let forest     = ThemePalette(id: "forest",      name: "Forest",      primary: Color(hex: "#059669"), secondary: Color(hex: "#047857"), accent: Color(hex: "#6EE7B7"))
    static let charcoal   = ThemePalette(id: "charcoal",    name: "Charcoal",    primary: Color(hex: "#3A3A3C"), secondary: Color(hex: "#1C1C1E"), accent: Color(hex: "#AEAEB2"))
    static let deepPurple = ThemePalette(id: "deep-purple", name: "Deep Purple", primary: Color(hex: "#6D28D9"), secondary: Color(hex: "#5B21B6"), accent: Color(hex: "#A78BFA"))

    static let socialPalettes: [ThemePalette] = [.sunset, .tropical, .candy, .amber, .blueShared, .rose]
    static let workPalettes:   [ThemePalette] = [.navy, .slate, .forest, .charcoal, .blueShared, .deepPurple]
}

// MARK: - AccountTheme

/// The signed-in account's palette per mode, as the server stores it
/// (users.hobby_theme / work_theme). nil = not known yet: use this device's
/// cached copy for that account.
struct AccountTheme: Equatable {
    let userID: String
    let hobby: String?
    let work: String?
}

// MARK: - ThemeManager

/// The palette belongs to the account, not the device: AppState publishes the
/// account's `AccountTheme` and `apply` shows it. UserDefaults keeps a copy per
/// user id only so the right colour is up on the splash before the server answers.
@Observable
final class ThemeManager {
    static let defaultPaletteId = "blue"

    var currentMode: AppMode = .hobby
    private(set) var socialPaletteId: String
    private(set) var workPaletteId: String
    private var userID: String?

    private let defaults: UserDefaults
    private static let lastUserKey = "themeManager.lastUserID"
    private static func key(_ mode: AppMode, _ userID: String) -> String { "themeManager.\(userID).\(mode.rawValue)" }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let last = defaults.string(forKey: Self.lastUserKey)
        userID = last
        socialPaletteId = last.flatMap { defaults.string(forKey: Self.key(.hobby, $0)) } ?? Self.defaultPaletteId
        workPaletteId   = last.flatMap { defaults.string(forKey: Self.key(.work, $0)) } ?? Self.defaultPaletteId
    }

    /// Shows an account's palettes. A value from the server wins and is cached;
    /// a missing one falls back to this account's cached copy, then the default.
    func apply(_ account: AccountTheme) {
        userID = account.userID
        defaults.set(account.userID, forKey: Self.lastUserKey)
        socialPaletteId = resolve(account.hobby, mode: .hobby, userID: account.userID)
        workPaletteId   = resolve(account.work, mode: .work, userID: account.userID)
    }

    private func resolve(_ id: String?, mode: AppMode, userID: String) -> String {
        let key = Self.key(mode, userID)
        if let id, Self.isKnown(id, mode: mode) {
            defaults.set(id, forKey: key)
            return id
        }
        if let cached = defaults.string(forKey: key), Self.isKnown(cached, mode: mode) { return cached }
        return Self.defaultPaletteId
    }

    static func isKnown(_ id: String, mode: AppMode) -> Bool {
        (mode == .hobby ? ThemePalette.socialPalettes : ThemePalette.workPalettes).contains { $0.id == id }
    }

    func paletteId(for mode: AppMode) -> String {
        mode == .hobby ? socialPaletteId : workPaletteId
    }

    /// Active palette based on currentMode and selected id.
    var theme: ThemePalette {
        switch currentMode {
        case .hobby:
            return ThemePalette.socialPalettes.first { $0.id == socialPaletteId } ?? .blueShared
        case .work:
            return ThemePalette.workPalettes.first { $0.id == workPaletteId } ?? .blueShared
        }
    }

    /// Syncs mode from AppState. Called via .onChange in ConnectSphereApp.
    func switchMode(_ mode: AppMode) {
        currentMode = mode
    }

    /// Shows a palette for one mode at once and caches it for the signed-in
    /// account. Saving it to the account is ThemePickerViewModel's job.
    func selectPalette(id: String, for mode: AppMode) {
        guard Self.isKnown(id, mode: mode) else { return }
        switch mode {
        case .hobby: socialPaletteId = id
        case .work:  workPaletteId = id
        }
        if let userID { defaults.set(id, forKey: Self.key(mode, userID)) }
    }
}
