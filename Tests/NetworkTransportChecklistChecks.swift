import Foundation

@main
struct NetworkTransportChecklistChecks {
    static func main() throws {
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
        let source = try String(contentsOfFile: "WearTAK Watch App/SettingsView.swift", encoding: .utf8)
        let networkView = source.components(separatedBy: "struct NetworkPreferencesView: View {")[1]
        let list = networkView.components(separatedBy: "    /// The row opens")[0]
        precondition(list.contains("""
                if settings.networkPreferencesChecklist {
                    Section(String(localized: "Transports", table: "WatchSettings")) {
"""), "the whole checklist section is opt-in")
        let gatedSection = list.components(separatedBy: "if settings.networkPreferencesChecklist {")[1]
            .components(separatedBy: "\n                Section {")[0]
        precondition(gatedSection.contains("ForEach(NetworkTransport.sorted"))
        precondition(gatedSection.contains("TAK Servers"))
        precondition(list.contains("""
                }
                Section {
                    networkConfigurationLinks
                }
"""), "normal configuration links remain available outside the checklist gate")
        precondition(list.contains("if settings.networkPreferencesLocked {"), "admin lock still takes priority")
        print("Network transport checklist checks passed")
    }
}
