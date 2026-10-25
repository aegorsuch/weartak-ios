import SwiftUI

struct CompanionDeveloperPreferencesView: View {
    @ObservedObject var bridge: PhoneBridgeModel
    @State private var diagnosticsEnabled = DiagnosticsLog.shared.isEnabled
    @State private var errorText: String?
    @State private var collecting = false
    @State private var export: Export?

    private struct Export: Identifiable {
        let id = UUID()
        let url: URL
    }

    private func title(_ item: DeveloperPreference) -> String {
        String(localized: String.LocalizationValue(item.rawValue), table: "Diagnostics")
    }

    private func prepareExport(_ data: Data, watch: Bool) throws {
        export = Export(url: try DiagnosticsLog.exportFile(data, watch: watch))
    }

    var body: some View {
        List {
            ForEach(DeveloperPreference.sorted(
                [.betaFeatures, .collectWatch, .developerMode, .diagnostics, .exportDiagnostics], title: title)) { item in
                switch item {
                case .betaFeatures:
                    NavigationLink(title(item)) { CompanionBetaFeaturesView(bridge: bridge) }
                case .collectWatch:
                    Button(title(item)) {
                        collecting = true
                        Task {
                            defer { collecting = false }
                            do { try prepareExport(try await bridge.collectWatchDiagnostics(), watch: true) }
                            catch { errorText = error.localizedDescription }
                        }
                    }
                    .disabled(collecting)
                case .developerMode:
                    Toggle(title(item), isOn: $bridge.developerMode)
                case .diagnostics:
                    Toggle(title(item), isOn: Binding(get: { diagnosticsEnabled }, set: { enabled in
                        do {
                            try DiagnosticsLog.shared.setEnabled(enabled)
                            diagnosticsEnabled = enabled
                        } catch { errorText = error.localizedDescription }
                    }))
                case .exportDiagnostics:
                    Button(title(item)) {
                        do { try prepareExport(DiagnosticsLog.shared.export(), watch: false) }
                        catch { errorText = error.localizedDescription }
                    }
                default:
                    EmptyView()
                }
            }
            if DiagnosticsLog.shared.hasStorageFailure {
                Text(String(localized: "Diagnostics storage is unavailable. Check available storage and try again.", table: "Diagnostics"))
            }
        }
        .navigationTitle(String(localized: "Developer Preferences", table: "Diagnostics"))
        .sheet(item: $export) { file in
            ShareLink(item: file.url) {
                Label(String(localized: "Share Diagnostics", table: "Diagnostics"), systemImage: "square.and.arrow.up")
            }
            .padding()
        }
        .alert(String(localized: "Diagnostics", table: "Diagnostics"),
               isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button(String(localized: "OK", table: "CompanionApp"), role: .cancel) { errorText = nil }
        } message: { Text(errorText ?? "") }
    }
}
