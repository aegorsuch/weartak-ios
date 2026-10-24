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
        let settings = try String(contentsOfFile: "WearTAK Watch App/SettingsView.swift", encoding: .utf8)
        let row = settings.components(separatedBy: "case .dataSync:")[1]
            .components(separatedBy: "case .ditto:")[0]
        precondition(row.contains("NavigationLink") && row.contains("Toggle(isOn: $settings.dataSyncEnabled)"))
        precondition(row.contains("arrow.triangle.2.circlepath") && row.contains(".buttonStyle(.borderless)"))
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
