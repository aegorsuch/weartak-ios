import Foundation

@main
struct CompanionServerStatusChecks {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let off = CompanionServerStatus(enabled: false, connected: true, detail: "Connected", connectedSince: now, now: now)
        precondition(off.level == .off && off.summary == "Disabled")
        let up = CompanionServerStatus(enabled: true, connected: true, detail: "Connected",
                                       connectedSince: now.addingTimeInterval(-3_900), now: now)
        precondition(up.level == .connected && up.summary == "Connected · \(CompanionServerStatus.duration(3_900))" && up.detail == nil)
        let justNow = CompanionServerStatus(enabled: true, connected: true, detail: "Connected", connectedSince: now, now: now)
        precondition(justNow.summary == "Connected just now")
        let connecting = CompanionServerStatus(enabled: true, connected: false, detail: "Connecting", connectedSince: nil, now: now)
        precondition(connecting.level == .connecting)
        let paused = CompanionServerStatus(enabled: true, connected: false, detail: "Paused in background", connectedSince: nil, now: now)
        precondition(paused.level == .off)
        let raw = "TAK stream tak.example:8089 (TLS name tak.example): The operation timed out (NSPOSIXErrorDomain 60)."
        let timeout = CompanionServerStatus(enabled: true, connected: false, detail: raw, connectedSince: nil, now: now)
        precondition(timeout.level == .failed && timeout.summary == "Server didn't respond" && timeout.detail == raw)
        let refused = "TAK stream tak.example:8089 (TLS name tak.example): Connection refused (NSPOSIXErrorDomain 61)."
        precondition(CompanionServerStatus.plainError(refused).hasPrefix("Server refused"))
        let unknown = "TAK stream tak.example:8089 (TLS name tak.example): Something odd (X 1)."
        precondition(CompanionServerStatus.plainError(unknown) == unknown, "TLS name prefix must not imply a TLS error")
        precondition(CompanionServerStatus.plainError("Configure certificate") == "Needs a client certificate")
        precondition(CompanionServerStatus.duration(30) == "just now")
        let durationFormatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en")
        durationFormatter.calendar = calendar
        durationFormatter.unitsStyle = .short
        durationFormatter.zeroFormattingBehavior = .dropAll
        durationFormatter.allowedUnits = [.hour, .minute]
        precondition(CompanionServerStatus.duration(7_200) == durationFormatter.string(from: DateComponents(hour: 2, minute: 0)))
        durationFormatter.allowedUnits = [.day]
        precondition(CompanionServerStatus.duration(86_400 * 3) == durationFormatter.string(from: DateComponents(day: 3)))
        precondition(CompanionServerStatus.certificateText(expires: now.addingTimeInterval(-1), now: now).warning)
        let soon = CompanionServerStatus.certificateText(expires: now.addingTimeInterval(86_400 * 10.5), now: now)
        precondition(soon.warning && soon.text == "Certificate expires in 10 days")
        for days in [1, 2, 29] {
            let certificate = CompanionServerStatus.certificateText(expires: now.addingTimeInterval(Double(days) * 86_400), now: now)
            precondition(certificate.warning && certificate.text == "Certificate expires in \(days) day\(days == 1 ? "" : "s")")
        }
        precondition(CompanionServerStatus.certificateText(expires: now.addingTimeInterval(60), now: now).text == "Certificate expires today")
        precondition(CompanionServerStatus.certificateText(expires: now.addingTimeInterval(86_400 * 30), now: now).warning == false)
        let later = CompanionServerStatus.certificateText(expires: now.addingTimeInterval(86_400 * 200), now: now)
        precondition(!later.warning && later.text.hasPrefix("Certificate expires "))
        print("Companion server status checks passed")
    }
}
