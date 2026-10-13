import Foundation

@main
struct PluginCatalogChecks {
    static func main() {
        precondition(WatchPluginEntry.current.map(\.title) == [
            "DataSync",
            "Everywhere Comms",
            "Somewear Labs"
        ])

        let dynamicEntries = [
            WatchPluginEntry(id: "zulu", title: "zulu", content: .placeholder),
            WatchPluginEntry(id: "alpha", title: "alpha", content: .placeholder),
            WatchPluginEntry(id: "middle", title: "Middle", content: .placeholder)
        ]
        precondition(WatchPluginEntry.alphabetized(dynamicEntries).map(\.title) == [
            "alpha",
            "Middle",
            "zulu"
        ])

        let placeholders = WatchPluginEntry.current.filter { $0.content == .placeholder }
        precondition(placeholders.map(\.subtitle) == [
            "Unfunded Request",
            "Unfunded Request"
        ])
        print("PASS: plugin catalog ordering and placeholder labels")
    }
}
