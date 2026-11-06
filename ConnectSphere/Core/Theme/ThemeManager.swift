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

// MARK: - ThemeManager

@Observable
final class ThemeManager {
    var currentMode: AppMode = .hobby
    var socialPaletteId: String
    var workPaletteId: String

    private let socialKey = "themeManager.socialPaletteId"
    private let workKey   = "themeManager.workPaletteId"

    init() {
        socialPaletteId = UserDefaults.standard.string(forKey: "themeManager.socialPaletteId") ?? "blue"
        workPaletteId   = UserDefaults.standard.string(forKey: "themeManager.workPaletteId")   ?? "blue"
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

    /// Persists palette selection for the current mode.
    func selectPalette(id: String) {
        switch currentMode {
        case .hobby:
            socialPaletteId = id
            UserDefaults.standard.set(id, forKey: socialKey)
        case .work:
            workPaletteId = id
            UserDefaults.standard.set(id, forKey: workKey)
        }
    }
}
