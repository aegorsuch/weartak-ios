import Foundation

@main
struct LocalizationResourceChecks {
    static func main() throws {
        precondition(CommandLine.arguments.count == 3, "Pass the built Companion app path and expected Git revision.")
        let phoneURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let watchURL = phoneURL.appendingPathComponent("Watch/WearTAK Watch App.app")
        let revision = try String(contentsOf: watchURL.appendingPathComponent("WearTAKGitCommit.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(revision == CommandLine.arguments[2])
        precondition(revision.count == 7 && revision.allSatisfy(\.isHexDigit))

        for language in ["fr", "es", "de", "ar", "ja", "zh-Hans"] {
            let phone = Bundle(path: phoneURL.appendingPathComponent("\(language).lproj").path)!
            let watch = Bundle(path: watchURL.appendingPathComponent("\(language).lproj").path)!
            for (key, table) in [("Connected just now", "PhoneServerStatus"),
                                 ("Connecting…", "PhoneServerStatus"),
                                 ("Disabled", "PhoneBridgeStatus"),
                                 ("Paused in background", "PhoneBridgeStatus")] {
                let value = phone.localizedString(forKey: key, value: nil, table: table)
                precondition(!value.isEmpty && value != key, "Missing \(language) translation for \(key)")
            }
            for key in ["Medic", "Team Member", "Dark Green", "Blue"] {
                let value = watch.localizedString(forKey: key, value: nil, table: "WatchSettings")
                precondition(!value.isEmpty && value != key, "Missing \(language) translation for \(key)")
            }
            for key in ["Certificate expired %@", "Certificate expires %@",
                        "Certificate expires in %@", "Certificate expires today"] {
                let value = phone.localizedString(forKey: key, value: nil, table: "PhoneCertificateStatus")
                precondition(!value.isEmpty && value != key, "Missing \(language) translation for \(key)")
                precondition(value.components(separatedBy: "%@").count == key.components(separatedBy: "%@").count)
            }
        }
        print("PASS: packaged server statuses, map role/team labels, and Git revision")
    }
}
