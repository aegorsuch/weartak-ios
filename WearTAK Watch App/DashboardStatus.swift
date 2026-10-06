import Foundation

enum DashboardPhysiologySeverity {
    case normal, warning, alert

    static func resolve(warningActive: Bool, alertActive: Bool) -> Self {
        if alertActive { return .alert }
        if warningActive { return .warning }
        return .normal
    }
}

enum DashboardLocationStatus {
    case watch, phone, disabled

    var label: String {
        switch self {
        case .watch: return String(localized: "Watch location enabled", table: "WatchStatus")
        case .phone: return String(localized: "Phone location enabled", table: "WatchStatus")
        case .disabled: return String(localized: "Location disabled or unavailable", table: "WatchStatus")
        }
    }

    /// Localized display text for existing call sites; never persisted or sent.
    var rawValue: String { label }

    static func resolve(watchEnabled: Bool, phoneEnabled: Bool) -> Self {
        if phoneEnabled { return .phone }
        return watchEnabled ? .watch : .disabled
    }
}

enum DashboardNetworkConnectivity {
    case phone, wifi, cellular, offline, other

    var label: String {
        switch self {
        case .phone: return String(localized: "Phone reachable", table: "WatchStatus")
        case .wifi: return String(localized: "WiFi", table: "WatchStatus")
        case .cellular: return String(localized: "Cellular", table: "WatchStatus")
        case .offline: return String(localized: "No network connection", table: "WatchStatus")
        case .other: return String(localized: "Network available", table: "WatchStatus")
        }
    }

    /// Localized display text for existing call sites; never persisted or sent.
    var rawValue: String { label }

    var symbol: String {
        switch self {
        case .phone: return "iphone.radiowaves.left.and.right"
        case .wifi: return "wifi"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .offline: return "wifi.slash"
        case .other: return "network"
        }
    }

    static func resolve(satisfied: Bool, wifi: Bool, cellular: Bool, phoneReachable: Bool = false) -> Self {
        if phoneReachable { return .phone }
        guard satisfied else { return .offline }
        if wifi { return .wifi }
        if cellular { return .cellular }
        return .other
    }
}

enum DashboardTAKTransport: String, Hashable {
    case multicast = "Multicast"
    case phoneRelay = "TAK BLE relay"
    case sitx = "Sit(x)"

    var label: String {
        switch self {
        case .multicast: return String(localized: "Multicast", table: "WatchStatus")
        case .phoneRelay: return String(localized: "TAK BLE relay", table: "WatchStatus")
        case .sitx: return rawValue
        }
    }

    var symbol: String {
        switch self {
        case .multicast: return "dot.radiowaves.left.and.right"
        case .phoneRelay: return "iphone.radiowaves.left.and.right"
        case .sitx: return "cloud"
        }
    }
}

/// What the watch shows for its phone link. Short WatchConnectivity drops (phone locked, set down, Bluetooth
/// hand-off) stay "reconnecting" for a grace period instead of flashing disconnected.
enum CompanionLinkState: Equatable {
    case connected, checking, reconnecting, paused(String), disconnected

    static let graceSeconds: TimeInterval = 45
    static let checkingSeconds: TimeInterval = 10

    var isPending: Bool { self == .checking || self == .reconnecting }

    var label: String {
        switch self {
        case .connected: return String(localized: "Connected", table: "WatchStatus")
        case .checking: return String(localized: "Checking…", table: "WatchStatus")
        case .reconnecting: return String(localized: "Reconnecting…", table: "WatchStatus")
        case .paused(let reason):
            if reason.isEmpty { return String(localized: "Phone paused – open Companion", table: "WatchStatus") }
            return String(localized: "Phone paused – open Companion (\(reason))", table: "WatchStatus",
                          comment: "Argument is a pause reason reported by the phone")
        case .disconnected: return String(localized: "Not connected", table: "WatchStatus")
        }
    }

    static func resolve(ready: Bool, pauseReason: String?, lastHealthy: Date?, checkingSince: Date?,
                        now: Date = Date()) -> Self {
        if ready { return .connected }
        if let checkingSince, now.timeIntervalSince(checkingSince) < checkingSeconds { return .checking }
        if let pauseReason { return .paused(pauseReason) }
        if let lastHealthy, now.timeIntervalSince(lastHealthy) < graceSeconds { return .reconnecting }
        return .disconnected
    }
}

enum DashboardServerBadge: Equatable {
    case connected, pending, paused, disconnected

    var symbol: String {
        switch self {
        case .connected: return "checkmark.circle.fill"
        case .pending: return "arrow.triangle.2.circlepath.circle.fill"
        case .paused: return "pause.circle.fill"
        case .disconnected: return "xmark.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .connected: return String(localized: "TAK server connected", table: "WatchStatus")
        case .pending: return String(localized: "TAK server reconnecting", table: "WatchStatus")
        case .paused: return String(localized: "TAK server paused on phone", table: "WatchStatus")
        case .disconnected: return String(localized: "TAK server not connected", table: "WatchStatus")
        }
    }

    /// The phone link state only matters when nothing else connects the watch to a TAK server.
    static func resolve(status: DashboardTAKStatus, phoneLink: CompanionLinkState?) -> Self {
        if status.isServerConnected { return .connected }
        switch phoneLink {
        case .checking?, .reconnecting?: return .pending
        case .paused?: return .paused
        default: return .disconnected
        }
    }
}

struct DashboardTAKStatus: Equatable {
    let active: [DashboardTAKTransport]
    let configured: [DashboardTAKTransport]

    var displayed: [DashboardTAKTransport] { active.isEmpty ? configured : active }
    var isConnected: Bool { !active.isEmpty }
    var usesServerIcon: Bool {
        active.contains { $0 != .multicast } || configured.contains { $0 != .multicast }
    }
    var isServerConnected: Bool { active.contains { $0 != .multicast } }
    var indicatorLabel: String {
        if usesServerIcon {
            return isServerConnected ? String(localized: "TAK server connected", table: "WatchStatus")
                : String(localized: "TAK server not connected", table: "WatchStatus")
        }
        if configured.contains(.multicast) || active.contains(.multicast) {
            return active.contains(.multicast) ? String(localized: "TAK multicast ready", table: "WatchStatus")
                : String(localized: "TAK multicast not ready", table: "WatchStatus")
        }
        return String(localized: "No TAK connection", table: "WatchStatus")
    }
    var label: String {
        if isConnected {
            let transports = Self.joined(active)
            return String(localized: "\(transports) connected", table: "WatchStatus",
                          comment: "Argument is a list of connected TAK transports, e.g. Multicast and Sit(x)")
        }
        if configured == [.phoneRelay] { return String(localized: "TAK BLE relay incomplete", table: "WatchStatus") }
        if configured.isEmpty { return String(localized: "No TAK connection", table: "WatchStatus") }
        let transports = Self.joined(configured)
        return String(localized: "\(transports) not connected", table: "WatchStatus",
                      comment: "Argument is a list of configured TAK transports that are not connected")
    }

    /// Joins transport names using the list conjunction of the app's active localization.
    private static func joined(_ transports: [DashboardTAKTransport]) -> String {
        let names = transports.map(\.label)
        let formatter = ListFormatter()
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        return formatter.string(from: names) ?? names.joined(separator: ", ")
    }

    static func resolve(multicastReady: Bool, sitxConnected: Bool, phoneRelayConnected: Bool,
                        multicastEnabled: Bool, sitxEnabled: Bool, relaySelected: Bool) -> Self {
        var active: [DashboardTAKTransport] = []
        var configured: [DashboardTAKTransport] = []
        if multicastReady { active.append(.multicast) }
        if phoneRelayConnected { active.append(.phoneRelay) }
        if sitxConnected { active.append(.sitx) }
        if multicastEnabled { configured.append(.multicast) }
        if relaySelected { configured.append(.phoneRelay) }
        if sitxEnabled { configured.append(.sitx) }
        return Self(active: active, configured: configured)
    }
}