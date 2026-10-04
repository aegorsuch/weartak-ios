import Foundation

@main
struct CompanionMapChecks {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let server = UUID()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func event(_ uid: String, age: TimeInterval = 0, stale: TimeInterval = 120,
                   source: UUID? = nil, generation: Int = 0, remarks: String = "") -> CompanionMapEvent {
            let xml = """
            <event uid="\(uid)" type="a-f-G-U-C" time="\(formatter.string(from: now.addingTimeInterval(-age)))" stale="\(formatter.string(from: now.addingTimeInterval(stale)))">
            <point lat="41.88" lon="-87.64"/><detail><contact callsign="ODIN-ATAK"/><__group name="Dark Green" role="K9"/><remarks>\(remarks)</remarks></detail></event>
            """
            return CompanionMapEvent(xml: xml, sourceServerID: source ?? server,
                                     sourceGeneration: generation, receivedAt: now)
        }
        var cache = CompanionMapCache()
        cache.receive(event("contact", age: 45), now: now)
        cache.receive(event("contact", age: 60), now: now)
        precondition(cache.events.count == 1 && cache.events[0].lastSeen == now.addingTimeInterval(-45))
        cache.receive(event("contact", age: 10), now: now)
        precondition(cache.events.count == 1 && cache.events[0].lastSeen == now.addingTimeInterval(-10))
        cache.receive(event("expired", stale: -1), now: now)
        cache.receive(event("too-old", age: 301), now: now)
        precondition(cache.events.count == 1)
        var restored = try JSONDecoder().decode(CompanionMapCache.self, from: JSONEncoder().encode(cache))
        precondition(restored.events[0].lastSeen == now.addingTimeInterval(-10))
        precondition(restored.events[0].xml.contains("name=\"Dark Green\" role=\"K9\""))
        restored.prune(now: now.addingTimeInterval(121))
        precondition(restored.events.isEmpty)
        cache.receive(event("other", source: UUID()), now: now)
        cache.prune(now: now, enabledServerIDs: [server])
        precondition(cache.events.count == 1)
        cache.receive(event("new-generation", generation: 2), now: now)
        cache.remove(sourceID: server, beforeGeneration: 2)
        precondition(cache.events.count == 1 && cache.events[0].sourceGeneration == 2)
        cache.resetGenerations()
        precondition(cache.events[0].sourceGeneration == 0)
        for index in 0..<60 { cache.receive(event("bounded-\(index)", age: TimeInterval(index)), now: now) }
        precondition(cache.events.count == 50)
        let requestID = UUID()
        let reply = try cache.filling(BridgeWire.Message(kind: .mapSnapshot, id: requestID, enabledServerIDs: [server]))
        let decoded = try BridgeWire.Message.decode(reply.encoded())
        precondition(decoded.id == requestID && decoded.mapEvents?.count == 50 &&
                     decoded.enabledServerIDs == [server] && decoded.snapshotTruncated == false)
        var largeCache = CompanionMapCache()
        for index in 0..<3 {
            largeCache.receive(event("large-\(index)", remarks: String(repeating: "A", count: 30_000)), now: now)
        }
        let bounded = try largeCache.filling(BridgeWire.Message(kind: .mapSnapshot))
        let data = try bounded.encoded()
        precondition(data.count <= BridgeWire.maximumMessageBytes &&
                     bounded.snapshotTruncated == true && bounded.mapEvents?.count == 1)
        let invalid = CompanionMapEvent(xml: "<event uid=\"bad\"><point lat=\"91\" lon=\"0\"/></event>",
                                        sourceServerID: server, sourceGeneration: 0, receivedAt: now)
        precondition(!invalid.isValid)
        do {
            _ = try BridgeWire.Message.decode(BridgeWire.Message(kind: .mapSnapshot, mapEvents: [invalid]).encoded())
            fatalError("Invalid map snapshot accepted")
        } catch BridgeWire.Failure.invalidCoT {}
        print("PASS: cached CoT age/stale times, persistence, generation resets, source/count/60KB bounds and snapshot validation")
    }
}
