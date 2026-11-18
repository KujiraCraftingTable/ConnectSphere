#if DEBUG
import SwiftUI

/// Lets a real device point at a different dev backend without an Xcode
/// rebuild, for when the built-in `.local` Bonjour hostname (`APIBaseURL`
/// in ConnectSphere-Info.plist) doesn't resolve on the current network
/// (e.g. a router that blocks mDNS multicast between clients). Only
/// compiled into DEBUG builds; APIConfig.serverBase checks this override
/// before falling back to Info.plist.
struct DevServerSettingsView: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle

    @AppStorage("devServerOverride", store: AppDefaults.store) private var devServerOverride: String = ""

    private var infoPlistDefault: String { APIConfig.builtInServerBase }

    var body: some View {
        List {
            Section {
                TextField(infoPlistDefault, text: $devServerOverride)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .tint(themeManager.theme.primary)
            } header: {
                Text("Server address override", bundle: bundle)
            } footer: {
                Text(String(format: bundle.loc("Leave empty to use the built-in default (%@). Fill in a full address like http://192.168.1.42:3000 when the built-in hostname doesn't resolve on this network. Relaunch the app after changing this so chat/realtime picks it up too."), infoPlistDefault))
            }

            if !devServerOverride.isEmpty {
                Section {
                    Button(role: .destructive) {
                        devServerOverride = ""
                    } label: {
                        Text("Clear override", bundle: bundle)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(bundle.loc("Developer"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
