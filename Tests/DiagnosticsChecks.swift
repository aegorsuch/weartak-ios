import Foundation

@main
struct DiagnosticsChecks {
    static func main() throws {
        let suite = "WearTAK.DiagnosticsChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let log = DiagnosticsLog(defaults: defaults, directory: directory)
        precondition(!log.isEnabled)
        for event in DiagnosticEvent.allCases { log.record(event, at: now) }
        precondition(!FileManager.default.fileExists(atPath: directory.path))
        try log.setEnabled(true, now: now)
        precondition(DiagnosticsLog(defaults: defaults, directory: directory).isEnabled)
        log.record(.locationAccepted, at: now)
        let first = try log.export()
        for index in 0..<1_000 { log.record(.locationAccepted, at: now.addingTimeInterval(Double(index) / 1_000)) }
        try expectExport(log, equals: first)
        log.record(.locationAccepted, at: now.addingTimeInterval(30))
        let afterInterval = try log.export()
        precondition(afterInterval != first)
        DispatchQueue.concurrentPerform(iterations: 100) { _ in log.record(.syncUpdated, at: now) }
        let concurrent = try JSONSerialization.jsonObject(with: log.export()) as! [String: Any]
        precondition((concurrent["entries"] as! [[String: Any]]).filter { $0["event"] as? String == "syncUpdated" }.count == 1)
        for index in 1...DiagnosticsLog.maximumEntries + 20 {
            log.record(.reportSent, at: now.addingTimeInterval(Double(index) * 31))
        }
        let data = try log.export()
        precondition(data.count <= DiagnosticsLog.maximumBytes)
        let archive = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(Set(archive.keys) == ["version", "entries"])
        let entries = archive["entries"] as! [[String: Any]]
        precondition(entries.count == DiagnosticsLog.maximumEntries)
        let allowed = Set(DiagnosticEvent.allCases.map(\.rawValue))
        for entry in entries {
            precondition(Set(entry.keys) == ["time", "event"])
            precondition(allowed.contains(entry["event"] as! String))
        }
        let relaunched = DiagnosticsLog(defaults: defaults, directory: directory)
        try expectExport(relaunched, equals: data)
        try relaunched.setEnabled(false)
        precondition(!DiagnosticsLog(defaults: defaults, directory: directory).isEnabled)
        relaunched.record(.operationFailed, at: now.addingTimeInterval(50_000))
        try expectExport(relaunched, equals: data)
        defaults.set(true, forKey: "WearTAK.diagnostics.enabled")
        let previouslyEnabled = DiagnosticsLog(defaults: defaults, directory: directory)
        precondition(previouslyEnabled.isEnabled)
        try expectExport(previouslyEnabled, equals: data)
        try previouslyEnabled.setEnabled(false)
        var injected = archive
        injected["coordinates"] = "must never export unknown fields"
        let cleaned = try DiagnosticsLog.validatedExport(JSONSerialization.data(withJSONObject: injected))
        precondition(!(String(data: cleaned, encoding: .utf8)!.contains("must never")))
        expectFailure { _ = try DiagnosticsLog.validatedExport(Data(repeating: 0, count: DiagnosticsLog.maximumBytes + 1)) }
        expectFailure { _ = try DiagnosticsLog.validatedExport(Data("{\"version\":2,\"entries\":[]}".utf8)) }
        expectFailure { _ = try DiagnosticsLog.validatedExport(Data("{\"version\":1,\"entries\":[{\"time\":0,\"event\":\"raw_chat\"}]}".utf8)) }

        let blocked = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)
        let failure = DiagnosticsLog(defaults: defaults, directory: blocked)
        expectFailure { try failure.setEnabled(true) }
        precondition(failure.hasStorageFailure && !failure.isEnabled)
        expectFailure { _ = try failure.export() }
        precondition(DeveloperPreference.sorted([.networkPreferencesChecklist, .diagnostics, .developerMode, .viewDiagnostics],
            title: \.rawValue) == [.developerMode, .diagnostics, .networkPreferencesChecklist, .viewDiagnostics])
        precondition(DeveloperPreference.sorted([.diagnostics, .developerMode],
            title: { $0 == .diagnostics ? "A" : "Z" }) == [.diagnostics, .developerMode])
        precondition(DeveloperPreference.diagnostics.rawValue == "Logging")
        precondition(DeveloperPreference.sorted([.diagnostics, .exportDiagnostics, .developerMode, .collectWatch, .betaFeatures],
            title: \.rawValue).map(\.rawValue) ==
            ["Beta Features", "Collect Watch Logs", "Developer mode", "Export Logs", "Logging"])
        precondition(DeveloperPreference.viewDiagnostics.rawValue == "View Logs")
        precondition(DeveloperPreference.networkPreferencesChecklist.rawValue == "Network Preferences Checklist")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "Shared/Diagnostics.xcstrings"))) as! [String: Any]
        let strings = catalog["strings"] as! [String: Any]
        for label in ["Logging", "Collect Watch Logs", "Export Logs", "Share Logs", "View Logs"] {
            precondition(strings[label] != nil)
        }
        let checklist = strings[DeveloperPreference.networkPreferencesChecklist.rawValue] as! [String: Any]
        let localizations = checklist["localizations"] as! [String: Any]
        for language in ["fr", "es", "de", "ar", "ja", "zh-Hans"] {
            let localization = localizations[language] as! [String: Any]
            let unit = localization["stringUnit"] as! [String: String]
            precondition(unit["state"] == "translated")
            precondition(!(unit["value"] ?? "").isEmpty)
        }

        let watch = try String(contentsOfFile: "WearTAK Watch App/SettingsView.swift", encoding: .utf8)
        precondition(watch.contains("DeveloperPreference.sorted([.developerMode, .diagnostics, .networkPreferencesChecklist, .viewDiagnostics]"))
        precondition(watch.contains("Toggle(title(item), isOn: $settings.networkPreferencesChecklist)"))
        let phone = try String(contentsOfFile: "WearTAK Companion/DeveloperPreferencesView.swift", encoding: .utf8)
        precondition(phone.contains("[.betaFeatures, .collectWatch, .developerMode, .diagnostics, .exportDiagnostics]"))
        precondition(phone.contains("ShareLink(item: file.url)"))
        let model = try String(contentsOfFile: "WearTAK Companion/PhoneBridgeModel.swift", encoding: .utf8)
        let collection = model.components(separatedBy: "func collectWatchDiagnostics()")[1]
            .components(separatedBy: "\n    func ")[0]
        precondition(collection.contains("developerMode, watchRoute == .apple") && collection.contains("isReachable"))
        precondition(collection.contains("DiagnosticsLog.validatedExport(data)"))
        let receiver = try String(contentsOfFile: "WearTAK Watch App/WatchCompanionOutput.swift", encoding: .utf8)
        precondition(receiver.contains("self.settings.developerMode") && receiver.contains("DiagnosticsLog.shared.export()"))
        for source in [watch, phone, model, receiver] {
            precondition(!source.contains("OSLogStore") && !source.contains("sysdiagnose"))
        }
        print("PASS: opt-in diagnostics persistence, rate/storage/privacy bounds, safe manual export, failure surfacing and localized developer menu ordering")
    }

    static func expectFailure(_ action: () throws -> Void) {
        do { try action(); preconditionFailure("Expected diagnostics failure") }
        catch {}
    }

    static func expectExport(_ log: DiagnosticsLog, equals expected: Data) throws {
        let actual = try log.export()
        precondition(actual == expected)
    }
}
