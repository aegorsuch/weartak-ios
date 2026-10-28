import Foundation

@main
struct PluginPreferenceChecks {
    static func main() throws {
        let suite = "WearTAK.PluginPreferenceChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(MOPPStatus.allCases.map(\.rawValue) == [-1, 0, 1, 2, 3, 4])
        precondition(MOPPStatus.load(from: defaults) == .none)
        for status in MOPPStatus.allCases {
            status.save(to: defaults)
            precondition(MOPPStatus.load(from: UserDefaults(suiteName: suite)!) == status)
        }
        for invalid in [99, -2, "invalid"] as [Any] {
            defaults.set(invalid, forKey: MOPPStatus.storageKey)
            precondition(MOPPStatus.load(from: defaults) == .none)
        }
        var gate = DataSyncRequestGate()
        let original = gate.revision
        precondition(gate.accepts(original, enabled: true))
        precondition(!gate.accepts(original, enabled: false))
        gate.invalidate()
        precondition(!gate.accepts(original, enabled: true))
        let disabledRevision = gate.revision
        gate.invalidate()
        precondition(!gate.accepts(disabledRevision, enabled: true))
        precondition(gate.accepts(gate.revision, enabled: true))
        let mopp = try String(contentsOfFile: "WearTAK Watch App/MOPPView.swift", encoding: .utf8)
        precondition(mopp.contains("State(initialValue: settings.moppStatus)"))
        precondition(mopp.contains("selection = status") && mopp.contains("settings.moppStatus = selection"))
        precondition(!mopp.contains("send(") && !mopp.contains("Color.green") && !mopp.contains("Color.red"))
        precondition(mopp.contains(".disabled(!settings.moppEnabled)"))
        precondition(mopp.contains(".disabled(!settings.moppEnabled || (selection == settings.moppStatus"))
        precondition(mopp.contains("settings.moppSavedAt = Date()"))
        precondition(mopp.contains("included in outgoing watch-identity position remarks"))
        let copy = try String(contentsOfFile: "WearTAK Watch App/WatchSettings.xcstrings", encoding: .utf8)
        precondition(!copy.contains("Manual status saved on this watch only."))
        precondition(copy.contains("included in outgoing watch-identity position remarks"))
        precondition(mopp.contains("When enabled and connected to a supported Companion"))
        precondition(!mopp.contains("phone UID") && !mopp.contains("watch only"))
        let view = try String(contentsOfFile: "WearTAK Watch App/SettingsView.swift", encoding: .utf8)
        let controls = view.components(separatedBy: "struct PhysiologicalControlsView: View {")[1]
            .components(separatedBy: "struct PhysiologicalAlertsView: View {")[0]
        precondition(!controls.contains("Change alert thresholds"))
        precondition(controls.contains(".accessibilityLabel(String(localized: \"Edit alert thresholds\""))
        precondition(controls.contains("isOn: $settings.physiologicalAlertsEnabled"))
        let appSettings = try String(contentsOfFile: "WearTAK Watch App/AppSettings.swift", encoding: .utf8)
        precondition(appSettings.contains("moppEnabled = defaults.object(forKey: Keys.moppEnabled) as? Bool ?? false"))
        let symbols = Dictionary(uniqueKeysWithValues: WatchPluginEntry.current.map { ($0.id, $0.symbol) })
        precondition(symbols["commands"] == "megaphone")
        precondition(symbols["data-sync"] == "arrow.triangle.2.circlepath")
        precondition(symbols["ditto"] == "arrow.triangle.branch")
        precondition(symbols["everywhere-comms"] == "globe")
        precondition(symbols["gotenna"] == "antenna.radiowaves.left.and.right")
        precondition(symbols["somewear-labs"] == "dot.radiowaves.left.and.right")
        precondition(symbols["sensor-manager"] == "waveform.path")
        let commands = try String(contentsOfFile: "WearTAK Watch App/ChatCommandSettingsView.swift", encoding: .utf8)
        precondition(commands.contains("ForEach(Array(settings.commandSenderUIDs.enumerated())"))
        precondition(commands.contains("startEditing(uid: uid, index: index)"))
        precondition(commands.contains(".focused($focusedUIDIndex, equals: index)"))
        precondition(commands.contains("Button(role: .destructive, action: { removeUID(at: index) })"))
        precondition(commands.components(separatedBy: ".buttonStyle(.borderless)").count == 3)
        precondition(commands.contains("ChatCommandAllowList.replacing(settings.commandSenderUIDs"))
        precondition(commands.contains("ChatCommandAllowList.removing(settings.commandSenderUIDs"))
        precondition(commands.contains("Button(\"Save Allowed UIDs\", action: saveUIDs)"))
        let settings = try String(contentsOfFile: "WearTAK Watch App/SettingsView.swift", encoding: .utf8)
        let row = settings.components(separatedBy: "case .dataSync:")[1]
            .components(separatedBy: "case .ditto:")[0]
        precondition(row.contains("NavigationLink") && row.contains("Toggle(isOn: $settings.dataSyncEnabled)"))
        precondition(row.contains("arrow.triangle.2.circlepath") && row.contains(".buttonStyle(.borderless)"))
        precondition(settings.contains("Toggle(isOn: $settings.moppEnabled)"))
        precondition(settings.components(separatedBy: "Image(systemName: plugin.symbol)").count == 5)
        let output = try String(contentsOfFile: "WearTAK Watch App/WatchCompanionOutput.swift", encoding: .utf8)
        precondition(output.contains("guard settings.dataSyncEnabled, hasSubscriptions"))
        precondition(output.components(separatedBy: "missionGate.accepts(").count == 4)
        let model = try String(contentsOfFile: "WearTAK Watch App/WatchSessionModel.swift", encoding: .utf8)
        for function in ["func editMissionItem(", "func deleteMissionItem("] {
            let body = model.components(separatedBy: function)[1].components(separatedBy: "guard let detail")[0]
            precondition(body.contains("guard settings.dataSyncEnabled"))
        }
        print("PASS: manual MOPP persistence and candidate/save contract; independent DataSync controls and off/on request invalidation")
    }
}
