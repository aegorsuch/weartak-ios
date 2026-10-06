import Foundation

@main
struct CompanionMapChecks {
    static func checkMissionPaging() throws {
        // 1,200 items in a line north of the origin: nearest keeps the first 999 by distance, not document order.
        let items = (0..<1_200).reversed().map {
            TAKMissionItem(uid: "item-\($0)", type: "a-u-G", callsign: "Point \($0)", lat: Double($0) * 0.001, lon: 0,
                           stale: nil, remark: String(repeating: "r", count: 160))
        }
        let nearest = TAKMissionAPI.nearest(items, limit: TAKMissionAPI.maximumItemsPerMission, latitude: 0, longitude: 0)
        precondition(nearest.count == 999 && Set(nearest.map(\.uid)) == Set((0..<999).map { "item-\($0)" }))
        precondition(TAKMissionAPI.nearest(items, limit: 999, latitude: nil, longitude: nil).first?.uid == "item-1199")
        precondition(TAKMissionAPI.nearest(Array(items.prefix(278)), limit: 999, latitude: 0, longitude: 0).count == 278)
        let wrap = [TAKMissionItem(uid: "east", type: "a-u-G", lat: 0, lon: 179.9),
                    TAKMissionItem(uid: "mid", type: "a-u-G", lat: 0, lon: 90)]
        precondition(TAKMissionAPI.nearest(wrap, limit: 1, latitude: 0, longitude: -179.9).first?.uid == "east")

        // A full page of large items is trimmed to fit, and the pages together cover all 999 items.
        var offset = 0
        var pages = 0
        while offset < nearest.count {
            var page = BridgeWire.Message(kind: .missions, serverID: UUID())
            page.missionName = "Mission"
            page.missionItemOffset = offset
            var slice = Array(nearest[offset...].prefix(TAKMissionAPI.maximumItemsPerMission))
            page.missionItems = slice
            while (try? page.encoded()) == nil, slice.count > 1 {
                slice.removeLast((slice.count + 1) / 2)
                page.missionItems = slice
            }
            let decoded = try BridgeWire.Message.decode(page.encoded())
            precondition(decoded.missionItems?.count == slice.count && decoded.missionItemOffset == offset)
            offset += slice.count
            pages += 1
        }
        precondition(offset == 999 && pages > 1 && pages < 20)

        var invalid = BridgeWire.Message(kind: .missions, serverID: UUID())
        invalid.missionName = "Mission"
        invalid.missionItemOffset = TAKMissionAPI.maximumItemsTotal
        precondition((try? BridgeWire.Message.decode(JSONEncoder().encode(invalid))) == nil)
        invalid.missionItemOffset = 0
        invalid.serverID = nil
        precondition((try? BridgeWire.Message.decode(JSONEncoder().encode(invalid))) == nil)
        var located = BridgeWire.Message(kind: .missions, missionSync: true)
        located.latitude = 35.7
        located.longitude = -78.6
        precondition((try? BridgeWire.Message.decode(located.encoded())) != nil)
        located.latitude = 95
        precondition((try? BridgeWire.Message.decode(JSONEncoder().encode(located))) == nil)
        located.latitude = 35.7
        located.longitude = nil
        precondition((try? BridgeWire.Message.decode(JSONEncoder().encode(located))) == nil)

        struct HTTPFailure: LocalizedError { let errorDescription: String? }
        precondition(TAKMissionAPI.isNotFound(HTTPFailure(errorDescription: "Data Sync API x: HTTP 404.")))
        precondition(TAKMissionAPI.isNotFound(HTTPFailure(errorDescription: "HTTP 404: not found")))
        precondition(!TAKMissionAPI.isNotFound(HTTPFailure(errorDescription: "HTTP 500.")))
        precondition(!TAKMissionAPI.isNotFound(URLError(.timedOut)))
        print("PASS: Data Sync nearest-999 selection, \(pages) message-sized item pages, page/location validation and 404 detection")
    }
    @MainActor
    static func main() async throws {
        var writes = 0
        var latestValue = 0
        var persistedValue = 0
        let batcher = MapCacheWriteBatcher(interval: .milliseconds(30)) {
            writes += 1
            persistedValue = latestValue
        }
        for index in 1...500 {
            latestValue = index
            batcher.schedule()
        }
        precondition(writes == 0)
        try await Task.sleep(for: .milliseconds(80))
        precondition(writes == 1 && persistedValue == 500)
        latestValue = 501
        batcher.schedule()
        batcher.flush()
        precondition(writes == 2 && persistedValue == 501)
        batcher.flush()
        try await Task.sleep(for: .milliseconds(80))
        precondition(writes == 2)
        batcher.schedule()
        batcher.cancel()
        try await Task.sleep(for: .milliseconds(80))
        precondition(writes == 2)
        batcher.schedule()
        try await Task.sleep(for: .milliseconds(80))
        precondition(writes == 3)
        print("PASS: 500 updates coalesced, latest-state persistence, inactive flush, cancellation and rescheduling")
        try checkMissionPaging()
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
        precondition(restored.events[0].header?.uid == "contact")
        precondition(restored.events[0].xml.contains("name=\"Dark Green\" role=\"K9\""))
        guard let persisted = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cache)) as? [String: Any],
              let persistedEvents = persisted["events"] as? [[String: Any]], let persistedEvent = persistedEvents.first else {
            fatalError("Invalid persisted cache shape")
        }
        precondition(Set(persistedEvent.keys) == ["xml", "sourceServerID", "sourceGeneration", "receivedAt"])
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
        let restoredInvalid = try JSONDecoder().decode(CompanionMapEvent.self, from: JSONEncoder().encode(invalid))
        precondition(!restoredInvalid.isValid && restoredInvalid.header == nil)
        let invalidTime = CompanionMapEvent(
            xml: "<event uid=\"bad-time\" time=\"invalid\"><point lat=\"0\" lon=\"0\"/></event>",
            sourceServerID: server, sourceGeneration: 0, receivedAt: now)
        precondition(!invalidTime.isValid)
        let chat = CompanionMapEvent(
            xml: "<event uid=\"chat\" type=\"b-t-f\"><point lat=\"0\" lon=\"0\"/></event>",
            sourceServerID: server, sourceGeneration: 0, receivedAt: now)
        precondition(!chat.isValid && chat.header?.type == "b-t-f")

        var heavyCache = CompanionMapCache()
        for index in 0..<50 {
            heavyCache.receive(event("heavy-\(index)", age: Double(50 - index) / 100,
                remarks: String(repeating: "A", count: 48_000)), now: now)
            let storedBytes = try JSONEncoder().encode(heavyCache).count
            precondition(storedBytes < CompanionMapCache.maximumStorageBytes)
        }
        precondition(heavyCache.events.count == 5 && heavyCache.events.first?.header?.uid == "heavy-49")
        let escaped = event("escaped", remarks: String(repeating: "\n", count: 48_000))
        heavyCache.receive(escaped, now: now)
        let escapedBytes = try JSONEncoder().encode(heavyCache).count
        precondition(escapedBytes < CompanionMapCache.maximumStorageBytes)
        let restoredHeavy = try JSONDecoder().decode(CompanionMapCache.self, from: JSONEncoder().encode(heavyCache))
        precondition(restoredHeavy.events.count == heavyCache.events.count)
        print("PASS: large-payload and JSON-escape storage bounds below watchOS preferences limit")

        var busyCache = CompanionMapCache()
        let started = Date()
        for index in 0..<5_000 {
            busyCache.receive(event("busy-\(index)", age: Double(5_000 - index) / 100), now: now)
            precondition(busyCache.events.count <= CompanionMapCache.maximumEvents)
            if index.isMultiple(of: 100) {
                busyCache.prune(now: now)
                _ = try JSONEncoder().encode(busyCache)
            }
        }
        precondition(busyCache.events.count == 50)
        precondition(Set(busyCache.events.compactMap { $0.header?.uid }) ==
                     Set((4_950..<5_000).map { "busy-\($0)" }))
        for _ in 0..<100 {
            busyCache.receive(event("busy-4999"), now: now)
        }
        precondition(busyCache.events.count == 50 && busyCache.events.first?.header?.uid == "busy-4999")
        let busySnapshot = try busyCache.filling(BridgeWire.Message(kind: .mapSnapshot))
        let busyDecoded = try BridgeWire.Message.decode(busySnapshot.encoded())
        precondition(busyDecoded.mapEvents?.count == 50 && busyDecoded.snapshotTruncated == false)
        busyCache.prune(now: now.addingTimeInterval(301))
        precondition(busyCache.events.isEmpty)
        print("PASS: 5,000-contact burst, repeated updates, persistence, snapshot and expiry in \(Date().timeIntervalSince(started)) seconds")
        print("PASS: cached CoT age/stale times, persistence, generation resets, source/count/60KB bounds and snapshot validation")
    }
}
