import Foundation

struct WatchPluginEntry: Identifiable, Equatable {
    enum Content: Equatable {
        case dataSync
        case placeholder
        case sensorManager
    }

    let id: String
    let title: String
    let content: Content

    var subtitle: String {
        switch content {
        case .dataSync:
            return ""
        case .placeholder, .sensorManager:
            return "Unfunded Request"
        }
    }

    static let current = alphabetized([
        WatchPluginEntry(id: "data-sync", title: "DataSync", content: .dataSync),
        WatchPluginEntry(id: "everywhere-comms", title: "Everywhere Comms", content: .placeholder),
        WatchPluginEntry(id: "gotenna", title: "GoTenna", content: .placeholder),
        WatchPluginEntry(id: "sensor-manager", title: "Sensor Manager", content: .sensorManager),
        WatchPluginEntry(id: "somewear-labs", title: "Somewear Labs", content: .placeholder)
    ])

    static func alphabetized(_ entries: [WatchPluginEntry]) -> [WatchPluginEntry] {
        entries.sorted { left, right in
            let comparison = left.title.localizedCaseInsensitiveCompare(right.title)
            return comparison == .orderedSame ? left.title < right.title : comparison == .orderedAscending
        }
    }
}
