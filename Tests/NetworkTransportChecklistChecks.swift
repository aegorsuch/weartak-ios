import Foundation

@main
struct NetworkTransportChecklistChecks {
    static func main() {
        let names = NetworkTransport.sorted(title: \.rawValue).map(\.rawValue)
        precondition(names == ["Ditto", "Sit(x) TAK", "TAK SA Multicast"], "checklist sorts by displayed label")
        let reversed = NetworkTransport.sorted(title: { String($0.rawValue.reversed()) })
        precondition(reversed.count == NetworkTransport.allCases.count, "sorting keeps every control")
        precondition(!NetworkTransport.allCases.map(\.rawValue).contains("TAK Servers"),
                     "iPhone-owned TAK servers are status only, not a watch checkbox")

        precondition(DittoPDLSourceSummary(usesCommunity: true, hasCustomPDL: false) == .community)
        precondition(DittoPDLSourceSummary(usesCommunity: true, hasCustomPDL: true) == .community)
        precondition(DittoPDLSourceSummary(usesCommunity: false, hasCustomPDL: true) == .customPDL)
        precondition(DittoPDLSourceSummary(usesCommunity: false, hasCustomPDL: false) == .none)

        precondition(DittoPDLSourceSummary.none.allows(enabling: false), "disabling Ditto is always allowed")
        precondition(!DittoPDLSourceSummary.none.allows(enabling: true), "Custom without a saved PDL cannot enable")
        precondition(DittoPDLSourceSummary.community.allows(enabling: true))
        precondition(DittoPDLSourceSummary.customPDL.allows(enabling: true))
        precondition(DittoPDLSourceSummary.missingPDLMessage == "Save a custom PDL before enabling Ditto.")
        print("Network transport checklist checks passed")
    }
}
