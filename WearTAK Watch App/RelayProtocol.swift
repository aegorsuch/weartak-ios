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
