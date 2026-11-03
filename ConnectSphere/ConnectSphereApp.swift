//
//  ConnectSphereApp.swift
//  ConnectSphere
//
//  Created by Trị Minh on 14/5/26.
//

import SwiftUI
import GoogleSignIn

@main
struct ConnectSphereApp: App {
    @State private var appState     = AppState()
    @State private var themeManager = ThemeManager()
    /// Shared "Undo" toast presenter for the delete-recovery flow — see
    /// `UndoToastView.swift`. Rendered by `MainTabView`'s overlay.
    @State private var toastPresenter = UndoToastPresenter()
    /// Shared floating "chat head" presenter — see `FloatingChatPresenter.swift`.
    /// Rendered by `MainTabView`'s overlay, same shape as `toastPresenter`.
    @State private var floatingChatPresenter = FloatingChatPresenter()

    init() {
        RemoteImageLoader.configureCache()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(themeManager)
                .environment(toastPresenter)
                .environment(floatingChatPresenter)
                .environment(\.appBundle, appState.bundle)
                .preferredColorScheme(appState.appearanceMode.colorScheme)
                .onOpenURL { url in
                    // connectsphere://community/<id> — community share link (Phase 5).
                    // Google Sign-In uses its own reversed-client-id scheme, so branching
                    // on scheme keeps the two flows from ever colliding.
                    if url.scheme == "connectsphere", url.host == "community" {
                        if let communityId = url.pathComponents.first(where: { $0 != "/" }) {
                            appState.pendingDeepLink = .community(id: communityId)
                        } else {
                            // Matched our own scheme but the id is missing/malformed
                            // (a hand-crafted or corrupted link) — a connectsphere://
                            // URL is never a Sign-In callback, so falling through to
                            // GIDSignIn would silently do nothing. Land on the
                            // Communities tab instead of dropping the tap entirely.
                            appState.pendingAssistantNavigation = .tab(2)
                        }
                    } else {
                        GIDSignIn.sharedInstance.handle(url)
                    }
                }
                // Keep themeManager.currentMode in sync with the authoritative app mode.
                .onChange(of: appState.currentMode) { _, newMode in
                    themeManager.switchMode(newMode)
                }
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager

    var body: some View {
        Group {
            if appState.isCheckingAuth {
                // Splash screen while checking the Keychain
                ZStack {
                    AppColors.base(.light).ignoresSafeArea()
                    VStack(spacing: 16) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 54))
                            .foregroundColor(themeManager.theme.primary)
                        Text("ConnectSphere")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(AppColors.textPrimary(.light))
                        ProgressView().tint(themeManager.theme.primary)
                    }
                }
            } else if !appState.isLoggedIn {
                LoginView()
            } else if appState.needsOnboarding {
                OnboardingView()
            } else {
                MainTabView()
            }
        }
        .task { await appState.restoreSession() }
        .onAppear { KeyboardDismissal.install() }
    }
}
