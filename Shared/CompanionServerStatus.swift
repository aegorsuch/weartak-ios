import Foundation

/// How a Companion TAK server row presents its connection: a status color, plain-language text and certificate warning.
struct CompanionServerStatus: Equatable {
    enum Level: Equatable {
        case connected, connecting, failed, off
    }

    static let certificateWarningDays = 30

    let level: Level
    /// Short, plain-language status line ("Connected 5 min", "Can't reach the server", ...).
    let summary: String
    /// Technical detail for failures (the original error), shown under the summary.
    let detail: String?

    init(enabled: Bool, connected: Bool, detail: String, connectedSince: Date?, now: Date = Date()) {
        if !enabled {
            level = .off
            summary = String(localized: "Disabled", table: "PhoneBridgeStatus")
            self.detail = nil
        } else if connected {
            level = .connected
            if let connectedSince {
                let elapsed = max(0, now.timeIntervalSince(connectedSince))
                summary = elapsed < 60
                    ? String(localized: "Connected just now", table: "PhoneServerStatus")
                    : String(localized: "Connected", table: "PhoneBridgeStatus") + " · " + Self.duration(elapsed)
            } else {
                summary = String(localized: "Connected", table: "PhoneBridgeStatus")
            }
            self.detail = nil
        } else if detail == "Connecting" {
            level = .connecting
            summary = String(localized: "Connecting…", table: "PhoneServerStatus")
            self.detail = nil
        } else if detail == "Paused in background" || detail == "Disabled"
                    || detail == String(localized: "Paused in background", table: "PhoneBridgeStatus")
                    || detail == String(localized: "Disabled", table: "PhoneBridgeStatus") {
            level = .off
            summary = detail == "Disabled"
                ? String(localized: "Disabled", table: "PhoneBridgeStatus")
                : detail == "Paused in background"
                    ? String(localized: "Paused in background", table: "PhoneBridgeStatus") : detail
            self.detail = nil
        } else {
            level = .failed
            let plain = Self.plainError(detail)
            summary = plain
            self.detail = plain == detail ? nil : detail
        }
    }

    /// "just now", "5 min", "3 hr 12 min", "2 days".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes < 1 { return "just now" }
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        formatter.calendar = calendar
        formatter.unitsStyle = .short
        formatter.allowedUnits = minutes >= 1_440 ? [.day] : [.hour, .minute]
        formatter.zeroFormattingBehavior = .dropAll
        let components = minutes >= 1_440
            ? DateComponents(day: minutes / 1_440)
            : DateComponents(hour: minutes / 60, minute: minutes % 60)
        guard let duration = formatter.string(from: components) else {
            preconditionFailure("Cannot format a valid connection duration")
        }
        return duration
    }

    /// Maps connection and certificate errors to wording a field user can act on.
    static func plainError(_ detail: String) -> String {
        // Stream errors start with "TAK stream host:port (TLS name host): "; match only the error after it.
        var text = detail.lowercased()
        if text.hasPrefix("tak stream "), let colon = text.range(of: "): ") { text = String(text[colon.upperBound...]) }
        func has(_ needles: String...) -> Bool { needles.contains { text.contains($0) } }
        if has("configure certificate", "certificate required") { return "Needs a client certificate" }
        if has("expired or not yet valid") { return "Certificate expired or phone clock is wrong" }
        if has("enrolled private key is unavailable") { return "Certificate key missing — enroll again" }
        if has("timed out") { return "Server didn't respond" }
        if has("connection refused") { return "Server refused the connection — check the port" }
        if has("could not be found", "nodename nor servname", "dns", "-65554", "nxdomain") {
            return "Server name not found — check the address"
        }
        if has("network is down", "network is unreachable", "no route to host", "internet connection appears to be offline") {
            return "No network connection"
        }
        if has("trust", "certificate", "-9807", "-9808", "-9813", "-9814", "-9825", "-9836", "bad certificate", "handshake", "ssl") {
            return "Certificate or TLS problem"
        }
        if has("closed the connection", "connection reset", "socket is not connected", "write failed") {
            return "Connection dropped — retrying"
        }
        return detail
    }

    /// Certificate line for a server row; `warning` when it expires within 30 days or already has.
    static func certificateText(expires: Date, now: Date = Date()) -> (text: String, warning: Bool) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let date = formatter.string(from: expires)
        let remaining = expires.timeIntervalSince(now)
        if remaining <= 0 {
            return (String(localized: "Certificate expired \(date)", table: "PhoneCertificateStatus"), true)
        }
        let days = Int(remaining / 86_400)
        if days < certificateWarningDays {
            if days == 0 {
                return (String(localized: "Certificate expires today", table: "PhoneCertificateStatus"), true)
            }
            let durationFormatter = DateComponentsFormatter()
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = formatter.locale
            durationFormatter.calendar = calendar
            durationFormatter.unitsStyle = .full
            durationFormatter.allowedUnits = [.day]
            guard let duration = durationFormatter.string(from: DateComponents(day: days)) else {
                preconditionFailure("Cannot format a valid certificate lifetime")
            }
            return (String(localized: "Certificate expires in \(duration)", table: "PhoneCertificateStatus"), true)
        }
        return (String(localized: "Certificate expires \(date)", table: "PhoneCertificateStatus"), false)
    }
}
