import Foundation

struct RelayEnvelope<Payload: Encodable>: Encodable {
    let msgType: String
    let payload: Payload
}

struct RelayHelloPayload: Codable {
    let watchLabel: String
    let protocolVersion: Int
}

struct MarkerRelayPayload: Codable {
    let uid: String
    let lat: Double
    let lon: Double
    let type: String
    let title: String
    let remark: String
    let tStart: String
    let tStale: String
}

struct MarkerDeleteRelayPayload: Codable {
    let uid: String
}

struct EmergencyRelayPayload: Codable {
    let uid: String
    let state: EmergencyState
    let alertType: String?
    let catg: String?
    let desc: String?
    let tStart: String
    let tStale: String
}

struct ChatRelayPayload: Codable {
    let replyTo: String
    let text: String
}

struct EntityRelayPayload: Codable {
    let uid: String
    let lat: Double
    let lon: Double
    let type: String
    var callSign: String? = nil
    var team: String? = nil
    var role: String? = nil
    var senderUID: String? = nil
    /// Parser-derived user classification; nil falls back to the CoT type.
    var isUser: Bool? = nil
    /// CoT `time`/`how`; a newer `time` on a human-entered (`h-`) point means the sender re-sent it.
    var sentAt: Date? = nil
    var how: String? = nil

    var isHumanEntered: Bool { how?.hasPrefix("h") == true }

    /// A same-uid update without `__group`/contact detail keeps the last known metadata,
    /// so the user's dot color, role badge and Layers counts do not drop out.
    func inheritingMetadata(callSign previousCallSign: String?, team previousTeam: String?,
                            role previousRole: String?, senderUID previousSenderUID: String? = nil,
                            isUser previousIsUser: Bool) -> Self {
        var merged = self
        if callSign?.isEmpty ?? true { merged.callSign = previousCallSign }
        if (team?.isEmpty ?? true) && (role?.isEmpty ?? true) {
            merged.team = previousTeam
            merged.role = previousRole
        }
        if senderUID?.isEmpty ?? true { merged.senderUID = previousSenderUID }
        if previousIsUser { merged.isUser = true }
        return merged
    }
}

/// Age of an incoming contact's last report (CoT event time for cached/relayed events).
struct MapContactAge: Equatable {
    static let staleThreshold = 60
    let seconds: Int

    init(lastSeen: Date, now: Date) {
        let elapsed = now.timeIntervalSince(lastSeen)
        seconds = elapsed.isFinite ? max(0, Int(min(elapsed, Double(Int32.max)))) : 0
    }

    var isStale: Bool { seconds > Self.staleThreshold }

    var shortText: String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }

    var spokenText: String {
        func unit(_ value: Int, _ name: String) -> String { "\(value) \(name)\(value == 1 ? "" : "s") ago" }
        if seconds < 60 { return unit(seconds, "second") }
        if seconds < 3600 { return unit(seconds / 60, "minute") }
        return unit(seconds / 3600, "hour")
    }

    func title(_ callSign: String) -> String { "\(callSign) ? \(shortText)" }

    func accessibilityLabel(callSign: String, team: String?, role: String?) -> String {
        let group = [team, role].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        let kind = group.isEmpty ? "user" : group + " user"
        return "\(callSign), \(kind), last report \(spokenText)" + (isStale ? ", stale" : "")
    }
}

struct MapUserGroup: Identifiable {
    let id: String
    let name: String
    let count: Int

    static func make(values: [String]) -> [Self] {
        let names = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return Dictionary(grouping: names, by: { $0.lowercased() }).map { key, names in
            Self(id: key, name: names.sorted()[0], count: names.count)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

enum RelayMessages {
    static func hello(watchLabel: String = "WearTAK Apple Watch") -> RelayEnvelope<RelayHelloPayload> {
        RelayEnvelope(
            msgType: "relay_hello",
            payload: RelayHelloPayload(watchLabel: watchLabel, protocolVersion: 1)
        )
    }

    static func marker(_ payload: MarkerRelayPayload) -> RelayEnvelope<MarkerRelayPayload> {
        RelayEnvelope(msgType: "marker", payload: payload)
    }

    static func markerDelete(uid: String) -> RelayEnvelope<MarkerDeleteRelayPayload> {
        RelayEnvelope(msgType: "marker_delete", payload: MarkerDeleteRelayPayload(uid: uid))
    }

    static func emergency(_ payload: EmergencyRelayPayload) -> RelayEnvelope<EmergencyRelayPayload> {
        RelayEnvelope(msgType: "emergency", payload: payload)
    }

    static func chat(_ payload: ChatRelayPayload) -> RelayEnvelope<ChatRelayPayload> {
        RelayEnvelope(msgType: "chat", payload: payload)
    }
}
