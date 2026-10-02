import Foundation

enum DashboardNetworkConnectivity: String {
    case wifi = "WiFi"
    case cellular = "Cellular"
    case offline = "No network connection"
    case other = "Network available"

    var symbol: String {
        switch self {
        case .wifi: return "wifi"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .offline: return "wifi.slash"
        case .other: return "network"
        }
    }

    static func resolve(satisfied: Bool, wifi: Bool, cellular: Bool) -> Self {
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

struct DashboardTAKStatus: Equatable {
    let active: [DashboardTAKTransport]
    let configured: [DashboardTAKTransport]

    var displayed: [DashboardTAKTransport] { active.isEmpty ? configured : active }
    var isConnected: Bool { !active.isEmpty }
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