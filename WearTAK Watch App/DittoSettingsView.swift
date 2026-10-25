import SwiftUI

/// Single Ditto enable path shared by Plugins, Network Preferences, and Ditto settings.
@MainActor
enum DittoEnableControl {
    static func summary(_ settings: AppSettings) -> DittoPDLSourceSummary {
        DittoPDLSourceSummary(usesCommunity: settings.dittoIdentitySource == .community,
                              hasCustomPDL: settings.dittoCustomPDL != nil)
    }

    static func binding(settings: AppSettings, model: WatchSessionModel, error: Binding<String?>) -> Binding<Bool> {
        Binding(
            get: { settings.dittoEnabled },
            set: { enabled in
                guard summary(settings).allows(enabling: enabled) else {
                    error.wrappedValue = DittoPDLSourceSummary.missingPDLMessage
                    return
                }
                settings.dittoEnabled = enabled
                Task { await model.companionClient.updateDittoConfiguration() }
            }
        )
    }
}

struct DittoSettingsView: View {
    @ObservedObject var model: WatchSessionModel
    @ObservedObject var settings: AppSettings
    @State private var customPDLDraft = ""
    @State private var errorText: String?
    @State private var showHelp = false

    var body: some View {
        List {
            Section {
                Toggle("Enable Ditto peer-to-peer sync", isOn: enabledBinding)
                Text(model.companionClient.dittoStatus?.detail ?? "Waiting for iPhone Companion.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Identity") {
                Picker("PDL source", selection: $settings.dittoIdentitySource) {
                    Text("Community").tag(DittoIdentitySource.community)
                    Text("Custom").tag(DittoIdentitySource.custom)
                }
                .pickerStyle(.navigationLink)
                if settings.dittoIdentitySource == .community {
                    Text("Community PDL is provisioned locally for the iPhone Companion build.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Custom PDL", text: $customPDLDraft, axis: .vertical)
                        .lineLimit(1...4)
                        .accessibilityLabel("Custom Ditto PDL")
                    HStack {
                        Button("Save Custom PDL", action: saveCustomPDL)
                        Button("Clear", role: .destructive, action: clearCustomPDL)
                    }
                    if settings.dittoCustomPDL != nil {
                        Text("Custom PDL saved securely in Keychain.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No custom PDL saved.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let keychainError = settings.dittoKeychainError {
                        Text(keychainError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Button("PDL Help") { showHelp = true }
                }
            }
            Section {
                Text("Ditto runs on the paired iPhone, not watchOS. Sync pauses when Companion moves to the background; iOS does not guarantee continuous background peer-to-peer sync.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Ditto")
        .onAppear {
            customPDLDraft = settings.dittoCustomPDL ?? ""
            Task { await model.companionClient.updateDittoConfiguration() }
        }
        .onChange(of: settings.dittoIdentitySource) {
            Task { await model.companionClient.updateDittoConfiguration() }
        }
        .alert("Ditto settings", isPresented: errorPresented) {
            Button("OK", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .sheet(isPresented: $showHelp) {
            DittoPDLHelpView()
        }
    }

    private var enabledBinding: Binding<Bool> {
        DittoEnableControl.binding(settings: settings, model: model, error: $errorText)
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })
    }

    private func saveCustomPDL() {
        do {
            try settings.storeDittoCustomPDL(customPDLDraft)
            customPDLDraft = settings.dittoCustomPDL ?? ""
            Task { await model.companionClient.updateDittoConfiguration() }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func clearCustomPDL() {
        do {
            try settings.storeDittoCustomPDL("")
            customPDLDraft = ""
            // Without a custom PDL, Ditto cannot stay on with the Custom identity.
            if settings.dittoIdentitySource == .custom { settings.dittoEnabled = false }
            Task { await model.companionClient.updateDittoConfiguration() }
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct DittoPDLHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Save a Ditto PDL from a direct chat message:")
                        .font(.headline)
                    Text("1. Send only the PDL in a chat message. Do not add other text, spaces, or characters.")
                    Text("2. On the watch, press and hold the direct message containing the PDL, then tap Save as Custom Ditto PDL. A confirmation appears after the PDL is validated and saved to Keychain.")
                    Text("3. Open Settings → Tool Preferences → Plugins → Ditto, select Custom, then enable sync. The watch sends the PDL to the paired iPhone Companion.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("PDL Help")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
