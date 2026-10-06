import Foundation

enum DashboardPhysiologySeverity {
    case normal, warning, alert

    static func resolve(warningActive: Bool, alertActive: Bool) -> Self {
        if alertActive { return .alert }
        if warningActive { return .warning }
        return .normal
    }
}

enum DashboardLocationStatus: String {
    case watch = "Watch location enabled"
    case phone = "Phone location enabled"
    case disabled = "Location disabled or unavailable"

    static func resolve(watchEnabled: Bool, phoneEnabled: Bool) -> Self {
        if phoneEnabled { return .phone }
        return watchEnabled ? .watch : .disabled
    }
}

enum DashboardNetworkConnectivity: String {
    case phone = "Phone reachable"
    case wifi = "WiFi"
    case cellular = "Cellular"
    case offline = "No network connection"
    case other = "Network available"

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
        case .connected: return "Connected"
        case .checking: return "Checking…"
        case .reconnecting: return "Reconnecting…"
        case .paused(let reason): return "Phone paused – open Companion" + (reason.isEmpty ? "" : " (\(reason))")
        case .disconnected: return "Not connected"
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
        case .connected: return "TAK server connected"
        case .pending: return "TAK server reconnecting"
        case .paused: return "TAK server paused on phone"
        case .disconnected: return "TAK server not connected"
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
        if usesServerIcon { return isServerConnected ? "TAK server connected" : "TAK server not connected" }
        if configured.contains(.multicast) || active.contains(.multicast) {
            return active.contains(.multicast) ? "TAK multicast ready" : "TAK multicast not ready"
        }
        return "No TAK connection"
    }
    var label: String {
        if isConnected { return active.map(\.rawValue).joined(separator: " and ") + " connected" }
        if configured == [.phoneRelay] { return "TAK BLE relay incomplete" }
        if configured.isEmpty { return "No TAK connection" }
        return configured.map(\.rawValue).joined(separator: " and ") + " not connected"
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