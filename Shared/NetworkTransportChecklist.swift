import Foundation

/// Watch transports with a real local enable gate. Checked means enabled, not connected.
/// Companion TAK servers are owned by the iPhone and are shown as read-only status instead.
nonisolated enum NetworkTransport: String, CaseIterable, Identifiable {
    case ditto = "Ditto"
    case multicast = "TAK SA Multicast"
    case sitx = "Sit(x) TAK"

    var id: String { rawValue }

    static func sorted(_ items: [Self] = allCases, title: (Self) -> String) -> [Self] {
        items.sorted { title($0).localizedStandardCompare(title($1)) == .orderedAscending }
    }
}

/// Configured Ditto PDL source only; never the PDL contents or a validity claim.
nonisolated enum DittoPDLSourceSummary: String, Equatable {
    case community = "Community"
    case customPDL = "Custom PDL"
    case none = "None"

    static let missingPDLMessage = "Save a custom PDL before enabling Ditto."

    init(usesCommunity: Bool, hasCustomPDL: Bool) {
        self = usesCommunity ? .community : hasCustomPDL ? .customPDL : .none
    }

    /// Same guard as the Plugins row: disabling is always allowed.
    func allows(enabling enabled: Bool) -> Bool { !enabled || self != .none }
}
