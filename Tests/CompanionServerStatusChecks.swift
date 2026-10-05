import Foundation

@main
struct CompanionServerStatusChecks {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let off = CompanionServerStatus(enabled: false, connected: true, detail: "Connected", connectedSince: now, now: now)
        precondition(off.level == .off && off.summary == "Disabled")
        let up = CompanionServerStatus(enabled: true, connected: true, detail: "Connected",
                                       connectedSince: now.addingTimeInterval(-3_900), now: now)
        precondition(up.level == .connected && up.summary == "Connected 1 hr 5 min" && up.detail == nil)
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
        precondition(CompanionServerStatus.duration(7_200) == "2 hr")
        precondition(CompanionServerStatus.duration(86_400 * 3) == "3 days")
        precondition(CompanionServerStatus.certificateText(expires: now.addingTimeInterval(-1), now: now).warning)
        let soon = CompanionServerStatus.certificateText(expires: now.addingTimeInterval(86_400 * 10.5), now: now)
        precondition(soon.warning && soon.text == "Certificate expires in 10 days")
        let later = CompanionServerStatus.certificateText(expires: now.addingTimeInterval(86_400 * 200), now: now)
        precondition(!later.warning && later.text.hasPrefix("Certificate expires "))
        print("Companion server status checks passed")
    }
}
