import Foundation

struct WatchPluginEntry: Identifiable, Equatable {
    enum Content: Equatable {
        case commands
        case dataSync
        case ditto
        case mopp
        case placeholder
        case sensorManager
    }

    let id: String
    let title: String
    let content: Content

    /// Native semantic symbols; these are not third-party brand marks.
    var symbol: String {
        switch id {
        case "commands": return "megaphone"
        case "data-sync": return "arrow.triangle.2.circlepath"
        case "ditto": return "arrow.triangle.branch"
        case "everywhere-comms": return "globe"
        case "gotenna": return "antenna.radiowaves.left.and.right"
        case "sensor-manager": return "waveform.path"
        default: return "dot.radiowaves.left.and.right"
        }
    }

    var subtitle: String {
        switch content {
        case .commands, .dataSync, .ditto, .mopp:
            return ""
        case .placeholder, .sensorManager:
            return "Unfunded Request"
        }
    }

    static let current = alphabetized([
        WatchPluginEntry(id: "commands", title: "Commands", content: .commands),
        WatchPluginEntry(id: "data-sync", title: "DataSync", content: .dataSync),
        WatchPluginEntry(id: "ditto", title: "Ditto", content: .ditto),
        WatchPluginEntry(id: "everywhere-comms", title: "Everywhere Comms", content: .placeholder),
        WatchPluginEntry(id: "gotenna", title: "GoTenna", content: .placeholder),
        WatchPluginEntry(id: "mopp", title: "MOPP", content: .mopp),
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
