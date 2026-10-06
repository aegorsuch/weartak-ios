import Foundation

// Display-only labels for app-owned option values. Raw values remain the persisted and CoT/network values;
// tokens (UDP, iTAK, TAK Aware, WearTAK Companion, HQ, K9, RTO, TOC, blood groups) are shown unchanged.

extension RelayProvider {
    var localizedName: String {
        switch self {
        case .notSet: return String(localized: "N/A", table: "WatchSettings", comment: "Not applicable / none selected")
        case .itak, .takAwareRelay, .companion: return rawValue
        }
    }
}

extension TeamColor {
    var localizedName: String {
        switch self {
        case .white: return String(localized: "White", table: "WatchSettings", comment: "Team color")
        case .yellow: return String(localized: "Yellow", table: "WatchSettings", comment: "Team color")
        case .orange: return String(localized: "Orange", table: "WatchSettings", comment: "Team color")
        case .magenta: return String(localized: "Magenta", table: "WatchSettings", comment: "Team color")
        case .red: return String(localized: "Red", table: "WatchSettings", comment: "Team color")
        case .maroon: return String(localized: "Maroon", table: "WatchSettings", comment: "Team color")
        case .purple: return String(localized: "Purple", table: "WatchSettings", comment: "Team color")
        case .darkBlue: return String(localized: "Dark Blue", table: "WatchSettings", comment: "Team color")
        case .blue: return String(localized: "Blue", table: "WatchSettings", comment: "Team color")
        case .cyan: return String(localized: "Cyan", table: "WatchSettings", comment: "Team color")
        case .teal: return String(localized: "Teal", table: "WatchSettings", comment: "Team color")
        case .green: return String(localized: "Green", table: "WatchSettings", comment: "Team color")
        case .darkGreen: return String(localized: "Dark Green", table: "WatchSettings", comment: "Team color")
        case .brown: return String(localized: "Brown", table: "WatchSettings", comment: "Team color")
        }
    }
}

extension UserRoleGroup {
    var localizedName: String {
        switch self {
        case .military: return String(localized: "roleGroup.military", defaultValue: "MIL", table: "WatchSettings", comment: "Role group: military")
        case .lawEnforcement: return String(localized: "roleGroup.lawEnforcement", defaultValue: "LEO", table: "WatchSettings", comment: "Role group: law enforcement")
        }
    }
}

extension ReportingStrategy {
    var localizedName: String {
        switch self {
        case .dynamic: return String(localized: "Dynamic Reporting", table: "WatchSettings", comment: "Position reporting strategy")
        case .constant: return String(localized: "Constant Reporting", table: "WatchSettings", comment: "Position reporting strategy")
        }
    }
}

extension WiFiBatteryPolicy {
    var localizedName: String {
        switch self {
        case .all: return String(localized: "All WiFi Connections", table: "WatchSettings", comment: "Save Battery on WiFi option")
        case .none: return String(localized: "No WiFi Connections", table: "WatchSettings", comment: "Save Battery on WiFi option")
        case .some: return String(localized: "Some WiFi Connections", table: "WatchSettings", comment: "Save Battery on WiFi option")
        }
    }
}

extension AppSettings {
    static func localizedMapRole(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let roles = UserRoleGroup.allCases.flatMap { $0.roles }
        guard let role = roles.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return value
        }
        return localizedOption(role)
    }

    /// Display label for a persisted role or medical/tool option value; unknown values are returned unchanged.
    nonisolated static func localizedOption(_ value: String) -> String {
        switch value {
        case "Forward Observer": return String(localized: "Forward Observer", table: "WatchSettings", comment: "User role")
        case "Medic": return String(localized: "Medic", table: "WatchSettings", comment: "User role")
        case "Sniper": return String(localized: "Sniper", table: "WatchSettings", comment: "User role")
        case "Team Lead": return String(localized: "Team Lead", table: "WatchSettings", comment: "User role")
        case "Team Member": return String(localized: "Team Member", table: "WatchSettings", comment: "User role")
        case "Armed Surveillance": return String(localized: "Armed Surveillance", table: "WatchSettings", comment: "User role")
        case "Assistant Team Leader": return String(localized: "Assistant Team Leader", table: "WatchSettings", comment: "User role")
        case "Aviation": return String(localized: "Aviation", table: "WatchSettings", comment: "User role")
        case "Bomb Tech": return String(localized: "Bomb Tech", table: "WatchSettings", comment: "User role: bomb technician")
        case "Command Post": return String(localized: "Command Post", table: "WatchSettings", comment: "User role")
        case "Critical Response": return String(localized: "Critical Response", table: "WatchSettings", comment: "User role")
        case "Hazards": return String(localized: "Hazards", table: "WatchSettings", comment: "User role: hazardous materials")
        case "Negotiator": return String(localized: "Negotiator", table: "WatchSettings", comment: "User role")
        case "Surveillance": return String(localized: "Surveillance", table: "WatchSettings", comment: "User role")
        case "Tactical Communicator": return String(localized: "Tactical Communicator", table: "WatchSettings", comment: "User role")
        case "Not Set": return String(localized: "Not Set", table: "WatchSettings")
        case "Female": return String(localized: "Female", table: "WatchSettings", comment: "Sex option")
        case "Male": return String(localized: "Male", table: "WatchSettings", comment: "Sex option")
        case "Unknown": return String(localized: "Unknown", table: "WatchSettings", comment: "Blood type option")
        case "N/A": return String(localized: "N/A", table: "WatchSettings", comment: "Not applicable / none selected")
        case "Antibiotics": return String(localized: "Antibiotics", table: "WatchSettings", comment: "Allergy option")
        case "Anti-Inflammatory (Ibuprofen)": return String(localized: "Anti-Inflammatory (Ibuprofen)", table: "WatchSettings", comment: "Allergy option")
        case "Antiseizure": return String(localized: "Antiseizure", table: "WatchSettings", comment: "Allergy option: antiseizure medication")
        case "Aspirin": return String(localized: "Aspirin", table: "WatchSettings", comment: "Allergy option")
        case "Insulin": return String(localized: "Insulin", table: "WatchSettings", comment: "Allergy option")
        case "Muscle Relaxers": return String(localized: "Muscle Relaxers", table: "WatchSettings", comment: "Allergy option")
        case "Sulfa Drugs": return String(localized: "Sulfa Drugs", table: "WatchSettings", comment: "Allergy option")
        case "Child": return String(localized: "Child", table: "WatchSettings", comment: "BATDOK user type option")
        case "Coalition Civilian": return String(localized: "Coalition Civilian", table: "WatchSettings", comment: "BATDOK user type option")
        case "Coalition Military": return String(localized: "Coalition Military", table: "WatchSettings", comment: "BATDOK user type option")
        case "Non-Coalition Civilian": return String(localized: "Non-Coalition Civilian", table: "WatchSettings", comment: "BATDOK user type option")
        case "Non-Coalition Military": return String(localized: "Non-Coalition Military", table: "WatchSettings", comment: "BATDOK user type option")
        case "Opposing Force Detainee": return String(localized: "Opposing Force Detainee", table: "WatchSettings", comment: "BATDOK user type option")
        case "Single Burst": return String(localized: "Single Burst", table: "WatchSettings", comment: "Bloodhound vibration intensity option")
        case "Triple Burst": return String(localized: "Triple Burst", table: "WatchSettings", comment: "Bloodhound vibration intensity option")
        case "Until In Position": return String(localized: "Until In Position", table: "WatchSettings", comment: "Bloodhound vibration intensity option")
        default: return value
        }
    }
}

/// Display-only translation of app-owned connection status messages. The clients keep their English
/// status strings because their logic compares them; text reported by servers or the iPhone, error
/// descriptions, addresses and protocol codes pass through unchanged.
enum WatchSettingsStatusText {
    nonisolated static func multicast(_ status: String) -> String {
        switch status {
        case "Disabled": return String(localized: "Disabled", table: "WatchSettings")
        case "App inactive": return String(localized: "App inactive", table: "WatchSettings", comment: "Connection status: the watch app is in the background")
        case "Invalid address or port": return String(localized: "Invalid address or port", table: "WatchSettings", comment: "Multicast connection status")
        case "Connecting": return String(localized: "Connecting", table: "WatchSettings", comment: "Connection status")
        case "Ready": return String(localized: "Ready", table: "WatchSettings", comment: "Multicast connection status")
        default: break
        }
        if let detailText = status.suffix(after: "Waiting: ") {
            return String(localized: "Waiting: \(detailText)", table: "WatchSettings", comment: "Multicast connection status. The argument is a system error description and is not translated.")
        }
        if let detailText = status.suffix(after: "Failed: ") {
            return String(localized: "Failed: \(detailText)", table: "WatchSettings", comment: "Multicast connection status. The argument is a system error description and is not translated.")
        }
        return status
    }

    nonisolated static func sitx(_ status: String) -> String {
        switch status {
        case "Connected": return String(localized: "Connected", table: "WatchStatus")
        case "Not connected": return String(localized: "Not connected", table: "WatchStatus")
        case "Off": return String(localized: "sitx.status.off", defaultValue: "Off", table: "WatchSettings", comment: "Sit(x) status: the connection is turned off")
        case "Requesting device code": return String(localized: "Requesting device code", table: "WatchSettings", comment: "Sit(x) status")
        case "Waiting for authorization": return String(localized: "Waiting for authorization", table: "WatchSettings", comment: "Sit(x) status")
        case "Refreshing token": return String(localized: "Refreshing token", table: "WatchSettings", comment: "Sit(x) status: renewing the sign-in token")
        case "Checking account": return String(localized: "Checking account", table: "WatchSettings", comment: "Sit(x) status")
        case "Code expired; retry": return String(localized: "Code expired; retry", table: "WatchSettings", comment: "Sit(x) status: the device authorization code expired")
        case "Phone relay reachable; Sit(x) paused": return String(localized: "Phone relay reachable; Sit(x) paused", table: "WatchSettings", comment: "Sit(x) status")
        case "Handing Sit(x) to iPhone": return String(localized: "Handing Sit(x) to iPhone", table: "WatchSettings", comment: "Sit(x) status: transferring the connection to the paired iPhone")
        case "Via iPhone": return String(localized: "Via iPhone", table: "WatchSettings", comment: "Sit(x) status: connection is relayed through the paired iPhone")
        case "Via iPhone; phone not reachable": return String(localized: "Via iPhone; phone not reachable", table: "WatchSettings", comment: "Sit(x) status")
        case "iPhone relay ended; select Re-auth": return String(localized: "iPhone relay ended; select Re-auth", table: "WatchSettings", comment: "Sit(x) status. Re-auth is the button label used in Settings.")
        case "Authorized; app inactive": return String(localized: "Authorized; app inactive", table: "WatchSettings", comment: "Sit(x) status")
        case "Authorized; select Connect / Pair to verify": return String(localized: "Authorized; select Connect / Pair to verify", table: "WatchSettings", comment: "Sit(x) status")
        case "Enter Sit(x) API host": return String(localized: "Enter Sit(x) API host", table: "WatchSettings", comment: "Sit(x) status")
        case "Enter a valid HTTPS host": return String(localized: "Enter a valid HTTPS host", table: "WatchSettings", comment: "Sit(x) status. HTTPS is a protocol name.")
        case "Authorized; profile check returned no HTTP response": return String(localized: "Authorized; profile check returned no HTTP response", table: "WatchSettings", comment: "Sit(x) status. HTTP is a protocol name.")
        case "No permitted TAK groups": return String(localized: "No permitted TAK groups", table: "WatchSettings", comment: "Sit(x) status")
        case "Authorized; select TAK group": return String(localized: "Authorized; select TAK group", table: "WatchSettings", comment: "Sit(x) status")
        case "Live stream needs WearTAK Companion; watchOS blocks direct Sit(x) streaming": return String(localized: "Live stream needs WearTAK Companion; watchOS blocks direct Sit(x) streaming", table: "WatchSettings", comment: "Sit(x) status. WearTAK Companion and watchOS are product names.")
        case "Sit(x) device limit reached for this account; remove an old device in the Sit(x) portal": return String(localized: "Sit(x) device limit reached for this account; remove an old device in the Sit(x) portal", table: "WatchSettings", comment: "Sit(x) sequestered-device status")
        case "Sit(x) device needs activation; open Sequestered Devices in the Sit(x) portal": return String(localized: "Sit(x) device needs activation; open Sequestered Devices in the Sit(x) portal", table: "WatchSettings", comment: "Sit(x) sequestered-device status. Sequestered Devices is a Sit(x) portal page.")
        case "Sit(x) organization is at its active-device limit; retrying": return String(localized: "Sit(x) organization is at its active-device limit; retrying", table: "WatchSettings", comment: "Sit(x) sequestered-device status")
        case "Sit(x) device awaiting administrator approval": return String(localized: "Sit(x) device awaiting administrator approval", table: "WatchSettings", comment: "Sit(x) sequestered-device status")
        default: break
        }
        if let codeText = status.suffix(after: "Authorized; profile check HTTP "), let code = Int(codeText) {
            return String(localized: "Authorized; profile check HTTP \(code)", table: "WatchSettings", comment: "Sit(x) status. The number is an HTTP status code.")
        }
        if let innerText = status.suffix(after: "On iPhone: ").map(sitx) {
            return String(localized: "On iPhone: \(innerText)", table: "WatchSettings", comment: "Sit(x) status reported by the iPhone. The argument is that status.")
        }
        if let innerText = status.suffix(after: "Via iPhone: ").map(sitx) {
            return String(localized: "Via iPhone: \(innerText)", table: "WatchSettings", comment: "Sit(x) status reported by the iPhone relay. The argument is that status.")
        }
        if let innerText = status.suffix(after: "Authorized; ").map(sitx) {
            return String(localized: "Authorized; \(innerText)", table: "WatchSettings", comment: "Sit(x) status: signed in, followed by a profile-check problem.")
        }
        if let detailText = status.suffix(after: "Sit(x) settings sync failed: ") {
            return String(localized: "Sit(x) settings sync failed: \(detailText)", table: "WatchSettings", comment: "Sit(x) status. The argument is a system error description and is not translated.")
        }
        if let detailText = status.suffix(after: "iPhone relay setup failed: ") {
            return String(localized: "iPhone relay setup failed: \(detailText)", table: "WatchSettings", comment: "Sit(x) status. The argument is an error description and is not translated.")
        }
        if let detailText = status.suffix(after: "iPhone relay update failed: ") {
            return String(localized: "iPhone relay update failed: \(detailText)", table: "WatchSettings", comment: "Sit(x) status. The argument is an error description and is not translated.")
        }
        if let detailText = status.suffix(after: "Sit(x) saved settings could not be loaded: ") {
            return String(localized: "Sit(x) saved settings could not be loaded: \(detailText)", table: "WatchSettings", comment: "Sit(x) status. The argument is a system error description and is not translated.")
        }
        if let codeText = status.suffix(after: "Sit(x) device sequestered ("), codeText.hasSuffix(")") {
            let tokenText = String(codeText.dropLast())
            return String(localized: "Sit(x) device sequestered (\(tokenText))", table: "WatchSettings", comment: "Sit(x) status. The argument is a server status code and is not translated.")
        }
        return failure(status) ?? status
    }

    /// Mirrors SitxClient.errorSummary: "<context> failed: <detail>", "<context> network error <code> (<reason>)"
    /// and "<context> failed (<domain> <code>)".
    private nonisolated static func failure(_ status: String) -> String? {
        let contexts = ["Sit(x) device authorization", "Sit(x) token exchange", "Token refresh", "TAK connection", "profile check"]
        guard let context = contexts.first(where: { status.hasPrefix($0 + " ") }) else { return nil }
        let rest = String(status.dropFirst(context.count + 1))
        if let detailText = rest.suffix(after: "failed: ") {
            switch context {
            case "Sit(x) device authorization": return String(localized: "Sit(x) device authorization failed: \(detailText)", table: "WatchSettings", comment: "Sit(x) status. The argument is an error description and is not translated.")
            case "Sit(x) token exchange": return String(localized: "Sit(x) token exchange failed: \(detailText)", table: "WatchSettings", comment: "Sit(x) status. The argument is an error description and is not translated.")
            case "Token refresh": return String(localized: "Token refresh failed: \(detailText)", table: "WatchSettings", comment: "Sit(x) status. The argument is an error description and is not translated.")
            case "TAK connection": return String(localized: "TAK connection failed: \(detailText)", table: "WatchSettings", comment: "Sit(x) status. The argument is an error description and is not translated.")
            default: return String(localized: "profile check failed: \(detailText)", table: "WatchSettings", comment: "Sit(x) status, shown after \"Authorized; \". The argument is an error description and is not translated.")
            }
        }
        if let networkText = rest.suffix(after: "network error "), networkText.hasSuffix(")"),
           let open = networkText.firstIndex(of: "("), let code = Int(networkText[..<open].trimmingCharacters(in: .whitespaces)) {
            let reasonText = networkReason(String(networkText[networkText.index(after: open)..<networkText.index(before: networkText.endIndex)]))
            switch context {
            case "Sit(x) device authorization": return String(localized: "Sit(x) device authorization network error \(code) (\(reasonText))", table: "WatchSettings", comment: "Sit(x) status. The number is a system network error code; the text in parentheses is the reason.")
            case "Sit(x) token exchange": return String(localized: "Sit(x) token exchange network error \(code) (\(reasonText))", table: "WatchSettings", comment: "Sit(x) status. The number is a system network error code; the text in parentheses is the reason.")
            case "Token refresh": return String(localized: "Token refresh network error \(code) (\(reasonText))", table: "WatchSettings", comment: "Sit(x) status. The number is a system network error code; the text in parentheses is the reason.")
            case "TAK connection": return String(localized: "TAK connection network error \(code) (\(reasonText))", table: "WatchSettings", comment: "Sit(x) status. The number is a system network error code; the text in parentheses is the reason.")
            default: return String(localized: "profile check network error \(code) (\(reasonText))", table: "WatchSettings", comment: "Sit(x) status, shown after \"Authorized; \". The number is a system network error code; the text in parentheses is the reason.")
            }
        }
        if let errorText = rest.suffix(after: "failed ("), errorText.hasSuffix(")"),
           let space = errorText.lastIndex(of: " "), let code = Int(errorText[errorText.index(after: space)..<errorText.index(before: errorText.endIndex)]) {
            let domainText = String(errorText[..<space])
            switch context {
            case "Sit(x) device authorization": return String(localized: "Sit(x) device authorization failed (\(domainText) \(code))", table: "WatchSettings", comment: "Sit(x) status. The arguments are a system error domain and code and are not translated.")
            case "Sit(x) token exchange": return String(localized: "Sit(x) token exchange failed (\(domainText) \(code))", table: "WatchSettings", comment: "Sit(x) status. The arguments are a system error domain and code and are not translated.")
            case "Token refresh": return String(localized: "Token refresh failed (\(domainText) \(code))", table: "WatchSettings", comment: "Sit(x) status. The arguments are a system error domain and code and are not translated.")
            case "TAK connection": return String(localized: "TAK connection failed (\(domainText) \(code))", table: "WatchSettings", comment: "Sit(x) status. The arguments are a system error domain and code and are not translated.")
            default: return String(localized: "profile check failed (\(domainText) \(code))", table: "WatchSettings", comment: "Sit(x) status, shown after \"Authorized; \". The arguments are a system error domain and code and are not translated.")
            }
        }
        return nil
    }

    /// Mirrors SitxAPI.networkReason.
    private nonisolated static func networkReason(_ reason: String) -> String {
        switch reason {
        case "no internet path": return String(localized: "no internet path", table: "WatchSettings", comment: "Network failure reason, shown in parentheses")
        case "timed out": return String(localized: "timed out", table: "WatchSettings", comment: "Network failure reason, shown in parentheses")
        case "host not found": return String(localized: "host not found", table: "WatchSettings", comment: "Network failure reason, shown in parentheses")
        case "cannot reach host": return String(localized: "cannot reach host", table: "WatchSettings", comment: "Network failure reason, shown in parentheses")
        case "connection lost": return String(localized: "connection lost", table: "WatchSettings", comment: "Network failure reason, shown in parentheses")
        case "TLS failed": return String(localized: "TLS failed", table: "WatchSettings", comment: "Network failure reason, shown in parentheses. TLS is a protocol name.")
        case "bad server response": return String(localized: "bad server response", table: "WatchSettings", comment: "Network failure reason, shown in parentheses")
        case "URL error": return String(localized: "URL error", table: "WatchSettings", comment: "Network failure reason, shown in parentheses")
        default: return reason
        }
    }
}

private extension String {
    nonisolated func suffix(after prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
