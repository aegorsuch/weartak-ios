import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct CompanionMapEvent: Codable {
    let xml: String
    let sourceServerID: UUID
    let sourceGeneration: Int
    let receivedAt: Date

    var isValid: Bool {
        sourceGeneration >= 0 && receivedAt.timeIntervalSince1970.isFinite &&
            CoTStreamFramer.isEvent(Data(xml.utf8)) && header != nil
    }

    var header: CoTMapHeader? { CoTMapHeader.parse(xml) }
    var lastSeen: Date { min(header?.time ?? receivedAt, receivedAt) }

    func isCurrent(at now: Date) -> Bool {
        guard let header, lastSeen <= now.addingTimeInterval(30),
              now.timeIntervalSince(lastSeen) <= CompanionMapCache.maximumAge else { return false }
        return header.stale.map { $0 > now } ?? true
    }
}

struct CompanionMapCache: Codable {
    static let maximumEvents = 50
    static let maximumAge: TimeInterval = 300
    private(set) var events: [CompanionMapEvent] = []

    mutating func receive(_ event: CompanionMapEvent, now: Date = Date()) {
        guard event.isValid, let header = event.header else { return }
        events.removeAll {
            $0.sourceServerID == event.sourceServerID && $0.header?.uid == header.uid &&
                $0.lastSeen <= event.lastSeen
        }
        if !events.contains(where: {
            $0.sourceServerID == event.sourceServerID && $0.header?.uid == header.uid
        }), event.isCurrent(at: now) {
            events.append(event)
        }
        prune(now: now)
    }

    mutating func prune(now: Date = Date(), enabledServerIDs: Set<UUID>? = nil) {
        events.removeAll { event in
            !event.isValid || !event.isCurrent(at: now) ||
                (enabledServerIDs.map { !$0.contains(event.sourceServerID) } ?? false)
        }
        events.sort { $0.lastSeen > $1.lastSeen }
        if events.count > Self.maximumEvents { events.removeLast(events.count - Self.maximumEvents) }
    }

    mutating func remove(sourceID: UUID, beforeGeneration: Int? = nil) {
        events.removeAll { event in
            event.sourceServerID == sourceID &&
                (beforeGeneration.map { event.sourceGeneration < $0 } ?? true)
        }
    }

    mutating func resetGenerations() {
        events = events.map {
            CompanionMapEvent(xml: $0.xml, sourceServerID: $0.sourceServerID,
                              sourceGeneration: 0, receivedAt: $0.receivedAt)
        }
    }

    func filling(_ message: BridgeWire.Message) throws -> BridgeWire.Message {
        var reply = message
        reply.mapEvents = []
        reply.snapshotTruncated = false
        for event in events {
            var candidate = reply
            candidate.mapEvents?.append(event)
            do {
                _ = try candidate.encoded()
                reply = candidate
            } catch BridgeWire.Failure.tooLarge {
                reply.snapshotTruncated = true
            }
        }
        _ = try reply.encoded()
        return reply
    }
}

struct CoTMapHeader {
    let uid: String
    let time: Date?
    let stale: Date?

    static func parse(_ xml: String) -> Self? {
        guard CoTStreamFramer.isEvent(Data(xml.utf8)) else { return nil }
        let delegate = CoTMapHeaderParser()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.hasPoint, let attributes = delegate.attributes,
              let uid = attributes["uid"], !uid.isEmpty else { return nil }
        func date(_ value: String?) -> Date? {
            guard let value else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }
        let time = date(attributes["time"])
        let stale = date(attributes["stale"])
        guard attributes["time"] == nil || time != nil,
              attributes["stale"] == nil || stale != nil else { return nil }
        return Self(uid: uid, time: time, stale: stale)
    }
}

private final class CoTMapHeaderParser: NSObject, XMLParserDelegate {
    var attributes: [String: String]?
    var hasPoint = false
    private var depth = 0

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        if depth == 1, elementName == "event" { self.attributes = attributes }
        if depth == 2, elementName == "point",
           let lat = attributes["lat"].flatMap(Double.init),
           let lon = attributes["lon"].flatMap(Double.init),
           lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon) {
            hasPoint = true
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        depth -= 1
    }
}
