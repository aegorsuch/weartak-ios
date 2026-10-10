import Foundation

@main
struct GarminRelayProtocolTests {
    static func main() throws {
        func envelope(_ type: String, _ payload: [String: Any]) throws -> GarminEnvelope {
            let data = try JSONSerialization.data(withJSONObject: GarminEnvelope(type, payload).object)
            return try GarminEnvelope(object: JSONSerialization.jsonObject(with: data))
        }
        let booleans = try envelope("test", ["yes": true, "no": false, "one": 1, "zero": 0])
        let yes = try booleans.boolean("yes")
        let no = try booleans.boolean("no")
        precondition(yes && !no)
        for key in ["one", "zero"] {
            do { _ = try booleans.boolean(key); fatalError("Numbers cannot substitute for booleans.") }
            catch GarminRelayProtocol.Failure.invalid {}
        }
        do { _ = try booleans.integer("yes", range: 0...1); fatalError("Booleans cannot substitute for numbers.") }
        catch GarminRelayProtocol.Failure.invalid {}
        let now = Date()
        let device = UUID()
        let identity = try GarminRelayProtocol.identity(envelope("watch_settings", [
            "callsign": "TEST", "team": "Cyan", "role": "Team Member", "reportIntSecs": 10
        ]), uid: device, now: now)
        let hello = try GarminRelayProtocol.request(envelope("relay_hello", ["protocolVersion": 1]),
            identity: nil, fix: nil, channelServers: [])
        precondition(hello.kind == .hello)
        let events = [
            try envelope("marker", ["messageId": "marker-1", "uid": "garmin-marker-1", "type": "a-f-G-T",
                                    "lat": 38.0, "lon": -77.0, "title": "A & B"]),
            try envelope("marker_delete", ["messageId": "delete-1", "uid": "garmin-marker-1"]),
            try envelope("emergency", ["messageId": "cancel-1", "uid": "garmin-sos", "state": "CANCEL"]),
            try envelope("chat", ["messageId": "chat-1", "replyTo": "recipient", "text": "Rgr"])
        ]
        var ledger = GarminDeliveryLedger()
        for event in events {
            let fingerprint = try JSONSerialization.data(withJSONObject: event.object, options: .sortedKeys)
            let original = try ledger.reserve(deviceID: device, messageID: event.string("messageId"),
                fingerprint: fingerprint, now: now) {
                try GarminRelayProtocol.outgoingCoT(event, identity: identity, fix: nil, now: now)
            }
            precondition(CoTStreamFramer.isEvent(Data(original.xml.utf8)))
            try ledger.accept(original.requestID)
            let retry = try ledger.reserve(deviceID: device, messageID: event.string("messageId"),
                fingerprint: fingerprint, now: now.addingTimeInterval(30)) {
                fatalError("Accepted event must not regenerate its CoT on retry.")
            }
            precondition(retry.accepted && retry.requestID == original.requestID && retry.xml == original.xml)
        }
        let invalidMarker = try envelope("marker", ["messageId": "invalid", "uid": "garmin-marker-invalid",
            "type": "a-f-G-T", "lat": true, "lon": -77.0])
        do {
            _ = try GarminRelayProtocol.outgoingCoT(invalidMarker, identity: identity, fix: nil, now: now)
            fatalError("Boolean coordinates must be rejected.")
        } catch GarminRelayProtocol.Failure.invalid {}
        let metrics = UserMetrics(birthYear: 1990, source: "Test", measuredAt: now)
        let restoredMetrics = try JSONDecoder().decode(UserMetrics.self, from: JSONEncoder().encode(metrics))
        precondition(restoredMetrics == metrics)
        print("PASS: JSON types, hello, four queued event types, stable CoT retries, coordinate validation, metrics roundtrip")
    }
}
