import SwiftUI

struct ChatCommandSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var senderUIDs = ""
    @State private var editingUID = ""
    @State private var editingIndex: Int?
    @FocusState private var focusedUIDIndex: Int?
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
                ForEach(Array(settings.commandSenderUIDs.enumerated()), id: \.offset) { index, uid in
                    if editingIndex == index {
                        HStack(spacing: 10) {
                            TextField("Sender UID", text: $editingUID)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .focused($focusedUIDIndex, equals: index)
                                .onSubmit { saveEditedUID(at: index) }
                            Button(action: { saveEditedUID(at: index) }) {
                                Image(systemName: "checkmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Save sender UID")
                            Button(role: .destructive, action: { removeUID(at: index) }) {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete sender UID")
                        }
                    } else {
                        Button(action: { startEditing(uid: uid, index: index) }) {
                            HStack {
                                Text(uid)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "pencil")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Edit sender UID \(uid)")
                    }
                }
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
                Text("toggleditto on or toggleditto off sets the saved state without changing the identity. After off, use another route or the UI to enable it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("#weartakcommand enrollserver name=North url=tak.example port=8089 opens the iPhone's New Server screen with details prefilled. Enter credentials on iPhone for this form.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("enrollserver name,address,port,username,password adds or updates a TAK server through the paired iPhone, from any allowed sender on any channel. The password is everything after the fourth comma and is never stored or echoed. Locked network settings refuse it, and the server's certificate must already be trusted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("loadprofile is not supported on iOS. Network preferences and iPhone administrator or MDM locks apply to server enrollment.")
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
        .onChange(of: editingIndex) { _, index in
            focusedUIDIndex = index
        }
    }

    private func saveUIDs() {
        settings.storeCommandSenderUIDs(senderUIDs)
        editingIndex = nil
        editingUID = ""
        senderUIDs = settings.commandSenderUIDs.joined(separator: ", ")
        saved = true
    }

    private func startEditing(uid: String, index: Int) {
        editingIndex = index
        editingUID = uid
        saved = false
    }

    private func saveEditedUID(at index: Int) {
        let updated = ChatCommandAllowList.replacing(settings.commandSenderUIDs, at: index, with: editingUID)
        settings.storeCommandSenderUIDs(updated.joined(separator: ","))
        senderUIDs = settings.commandSenderUIDs.joined(separator: ", ")
        editingIndex = nil
        editingUID = ""
        saved = true
    }

    private func removeUID(at index: Int) {
        let updated = ChatCommandAllowList.removing(settings.commandSenderUIDs, at: index)
        settings.storeCommandSenderUIDs(updated.joined(separator: ","))
        senderUIDs = settings.commandSenderUIDs.joined(separator: ", ")
        editingIndex = nil
        editingUID = ""
        saved = true
    }
}
