import SwiftUI

struct ChatCommandSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var senderUIDs = ""
    @State private var saved = false

    var body: some View {
        List {
            Section {
                Toggle("Enable Commands", isOn: $settings.commandsEnabled)
                Text("Commands change the watch profile or credentials when an allowed UID sends a direct chat over any enabled transport.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Allowed sender UIDs") {
                TextField("UIDs, comma-separated", text: $senderUIDs, axis: .vertical)
                    .accessibilityLabel("Allowed sender UIDs")
                Button("Save Allowed UIDs", action: saveUIDs)
                if saved {
                    Text("Allowed UIDs saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if settings.commandSenderUIDs.isEmpty {
                    Text("No sender is authorized until at least one UID is saved.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section("Available profile commands") {
                Text("#weartakcommandsetcallsign callsign=ODIN-2")
                Text("#weartakcommandsetteam team=Blue")
                Text(#"#weartakcommandsetrole role="Team Member""#)
                Text(#"#weartakcommandsetprofile callsign=ODIN-2 role="Team Member""#)
                Text("Profile commands: callsign, team, role, height, weight, birthyear, sex, usertype, pants, waist.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("setpdl accepts a custom PDL. usep12 accepts a hexadecimal client certificate for a configured iPhone server. Network and administrator locks apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("enrollserver and loadprofile are not supported on iOS. Other unknown commands are rejected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("UID allow-lists are not authentication. Network peers can spoof sender UIDs. Multicast listeners and shared Ditto peers may see credentials; use controlled networks and disable commands after provisioning.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Commands")
        .onAppear {
            senderUIDs = settings.commandSenderUIDs.joined(separator: ", ")
        }
    }

    private func saveUIDs() {
        settings.storeCommandSenderUIDs(senderUIDs)
        senderUIDs = settings.commandSenderUIDs.joined(separator: ", ")
        saved = true
    }
}
