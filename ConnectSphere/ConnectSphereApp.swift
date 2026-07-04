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

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(themeManager)
                .environment(\.appBundle, appState.bundle)
                .preferredColorScheme(appState.appearanceMode.colorScheme)
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
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

    var body: some View {
        Group {
            if appState.isCheckingAuth {
                // Splash screen trong khi kiểm tra Keychain
                ZStack {
                    AppGradient.background.ignoresSafeArea()
                    VStack(spacing: 16) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 54))
                            .foregroundColor(.white)
                        Text("ConnectSphere")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.white)
                        ProgressView().tint(.white)
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
    }
}
