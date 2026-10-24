import Foundation

@main
struct ManualAlertChecks {
    static func main() throws {
        let name = "WearTAK.manual-alert-checks.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var saved = try SavedManualAlerts(defaults: defaults)
        precondition(saved.types.isEmpty)
        precondition(!ManualAlertType.allCases.contains(.gunshotInjury))
        precondition(ManualAlertType.allCases.contains(.gunshot))
        precondition(ManualAlertType(rawValue: "Gunshot Injury") == .gunshotInjury,
                     "Existing active/custom alerts must remain readable")
        let alpha = ManualAlertType(rawValue: "alpha")!
        let zulu = ManualAlertType(rawValue: "Zulu")!
        let picker = ManualAlertType.pickerTypes(custom: [zulu, alpha])
        precondition(picker.map(\.rawValue) == ["911 Alert", "alpha", "Gate Runner", "Geofence Breached",
            "Gunshot", "In Contact", "Injury", "Ring The Bell", "UAS", "Vehicle", "Zulu"])
        let translated = ManualAlertType.pickerTypes(custom: [], label: { $0 == .vehicle ? "AAA" : $0.rawValue })
        precondition(translated[1] == .vehicle, "Alert ordering must use displayed localized labels")
        let custom = try saved.add("  Need assistance  ", defaults: defaults)
        precondition(custom.rawValue == "Need assistance")
        for duplicate in ["need ASSISTANCE", "  911 alert  "] {
            do { try saved.add(duplicate, defaults: defaults); preconditionFailure("Duplicate accepted") }
            catch SavedManualAlerts.Failure.duplicate {}
        }
        precondition(saved.types == [custom])
        let restored = try SavedManualAlerts(defaults: defaults)
        precondition(restored.types == [custom])
        for text in ["", "  ", "\n", "line\nbreak", "line\tbreak", String(repeating: "a", count: 129)] {
            do {
                try saved.add(text, defaults: defaults)
                preconditionFailure("Invalid custom alert accepted")
            } catch SavedManualAlerts.Failure.invalidText {}
        }
        let escaped = try saved.add("A&B <help> \"now\"", defaults: defaults)
        precondition(escaped.rawValue == "A&B <help> \"now\"")
        precondition(ManualAlertType.geofenceBreached.emergencyName == "Geo-fence Breached")
        precondition(custom.emergencyName == custom.rawValue)
        saved.remove(custom, defaults: defaults)
        let afterDelete = try SavedManualAlerts(defaults: defaults)
        precondition(afterDelete.types == [escaped])
        let legacy = ["Test", "test", "Injury", "  unchanged  ", String(repeating: "L", count: 129), "old\ttext"]
        defaults.set(legacy, forKey: SavedManualAlerts.storageKey)
        var legacySaved = try SavedManualAlerts(defaults: defaults)
        precondition(legacySaved.types.map(\.rawValue) == legacy)
        legacySaved.remove(legacySaved.types[4], defaults: defaults)
        precondition(defaults.stringArray(forKey: SavedManualAlerts.storageKey) == legacy.enumerated().filter { $0.offset != 4 }.map(\.element))
        defaults.removeObject(forKey: SavedManualAlerts.storageKey)
        var bounded = try SavedManualAlerts(defaults: defaults)
        _ = try bounded.add(String(repeating: "a", count: 60), defaults: defaults)
        _ = try bounded.add(String(repeating: "😀", count: 30), defaults: defaults)
        for invalid in [String(repeating: "a", count: 61), String(repeating: "😀", count: 31),
                        " \nvalid", "valid\t ", "a\u{7f}b", "a\u{85}b"] {
            do { try bounded.add(invalid, defaults: defaults); preconditionFailure("Invalid shared-rule text accepted") }
            catch SavedManualAlerts.Failure.invalidText {}
        }
        let collapsed = try bounded.add("  Need\u{a0}  help\u{2003}now  ", defaults: defaults)
        precondition(collapsed.rawValue == "Need help now")
        for i in 3..<20 { _ = try bounded.add("Alert \(i)", defaults: defaults) }
        precondition(bounded.types.count == 20)
        do { try bounded.add("Twenty first", defaults: defaults); preconditionFailure("21st accepted") }
        catch SavedManualAlerts.Failure.full {}
        defaults.set((0..<21).map { "Legacy \($0)" }, forKey: SavedManualAlerts.storageKey)
        let overLimitLegacy = try SavedManualAlerts(defaults: defaults)
        precondition(overLimitLegacy.types.count == 21)

        for type in ManualAlertType.allCases + [custom, escaped] {
            var session = ManualAlertSession()
            var starts = 0, cancels = 0
            for _ in 0..<20 {
                _ = session.start(type) { sent in
                    precondition(sent == type)
                    starts += 1
                    return true
                }
            }
            precondition(starts == 1 && session.active == type,
                         "Double taps/re-entrant UI callbacks may enqueue only one start")
            let expected: [ManualAlertType: String] = [.alert911: "b-a-o-tbl", .ringTheBell: "b-a-o-pan",
                .geofenceBreached: "b-a-g", .inContact: "b-a-o-opn"]
            precondition(type.cotType == (expected[type] ?? "b-a-o") && ManualAlertType.priority == 1)
            var restored = ManualAlertSession(active: ManualAlertType(rawValue: session.active!.rawValue))
            _ = restored.start(type) { _ in preconditionFailure("Restart must not resend active manual alert") }
            for _ in 0..<20 {
                _ = restored.cancel { sent in
                    precondition(sent == type)
                    cancels += 1
                    return true
                }
            }
            precondition(cancels == 1 && restored.active == nil)
            precondition(ManualAlertType.cancelCoTType == "b-a-o-can")
            precondition(restored.start(type) { _ in true }, "A deliberately restarted alert is a new action")
        }
        var failed = ManualAlertSession()
        precondition(!failed.start(.injury) { _ in false } && failed.active == nil)
        precondition(failed.start(.injury) { _ in true })
        precondition(!failed.cancel { _ in false } && failed.active == .injury,
                     "Queue failures must not silently clear the active alert")

        let queue = try OfflineOutbox(defaults: defaults, storageKey: "manual-alert-queue")
        let start = try queue.enqueue(key: "alert-\(custom.rawValue)", payload: Data("start".utf8))
        try queue.replacePayload(id: start.id, payload: Data("resolved first GPS".utf8))
        precondition(queue.entries.count == 1 && queue.entries[0].id == start.id,
                     "First location fills the queued intent without generating a new delivery ID")
        let cancel = try queue.enqueue(key: "alert-\(custom.rawValue)", payload: Data("cancel".utf8))
        try queue.acknowledge(id: start.id)
        precondition(queue.entries == [cancel], "An in-flight start acknowledgement must preserve cancellation")
        try queue.acknowledge(id: cancel.id)
        precondition(queue.entries.isEmpty)
        print("PASS: saved custom alert validation, deduplication, persistence/delete, one start/cancel, retained queue IDs and WearOS-parity kind/priority")
    }
}
