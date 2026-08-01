import SwiftUI

/// Nickel's Settings window: Launch at Login, Keep Panel on Top, and a
/// manual "Check for Updates…" row. Uses the System Settings visual idiom
/// (`.formStyle(.grouped)`) to read as native chrome rather than part of the
/// panel itself.
struct SettingsView: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var keepOnTop = PanelSettings.keepPanelOnTop
    @State private var showMenuBarIcon = PanelSettings.showMenuBarIcon

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        LaunchAtLogin.setEnabled(newValue)
                    }

                Toggle("Keep Panel on Top", isOn: $keepOnTop)
                    .onChange(of: keepOnTop) { _, newValue in
                        PanelSettings.keepPanelOnTop = newValue
                    }

                Toggle("Show Menu Bar Icon", isOn: $showMenuBarIcon)
                    .onChange(of: showMenuBarIcon) { _, newValue in
                        PanelSettings.showMenuBarIcon = newValue
                    }
            } footer: {
                Text("With the menu bar icon hidden, Nickel stays available via double-Shift and the Dock.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Version", value: appVersion)

                HStack {
                    Spacer()
                    Button("Check for Updates…") {
                        UpdateChecker.check()
                    }
                }
            } footer: {
                Text("Updates are checked against Nickel's GitHub releases.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // The ⋯ menu can flip Keep on Top while this window is open; follow
        // the shared setting so the two toggles never disagree.
        .onReceive(NotificationCenter.default.publisher(for: PanelSettings.keepOnTopDidChange)) { _ in
            keepOnTop = PanelSettings.keepPanelOnTop
        }
        .onReceive(NotificationCenter.default.publisher(for: PanelSettings.showMenuBarIconDidChange)) { _ in
            showMenuBarIcon = PanelSettings.showMenuBarIcon
        }
        .frame(width: 360)
        .fixedSize()
    }
}
