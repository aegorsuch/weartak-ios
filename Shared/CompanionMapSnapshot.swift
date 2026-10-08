import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct CompanionMapEvent: Codable {
    let xml: String
    let sourceServerID: UUID
    let sourceGeneration: Int
    let receivedAt: Date
    let header: CoTMapHeader?
    let storageByteBudget: Int

    init(xml: String, sourceServerID: UUID, sourceGeneration: Int, receivedAt: Date) {
        self.xml = xml
        self.sourceServerID = sourceServerID
        self.sourceGeneration = sourceGeneration
        self.receivedAt = receivedAt
        header = CoTMapHeader.parse(xml)
        // JSON escapes control bytes; reserve space for the fixed event metadata.
        storageByteBudget = xml.utf8.reduce(512) { size, byte in
            size + (byte < 32 ? 6 : byte == 34 || byte == 92 ? 2 : 1)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case xml, sourceServerID, sourceGeneration, receivedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(xml: try values.decode(String.self, forKey: .xml),
                  sourceServerID: try values.decode(UUID.self, forKey: .sourceServerID),
                  sourceGeneration: try values.decode(Int.self, forKey: .sourceGeneration),
                  receivedAt: try values.decode(Date.self, forKey: .receivedAt))
    }

    var isValid: Bool {
        sourceGeneration >= 0 && receivedAt.timeIntervalSince1970.isFinite &&
            header != nil && header?.type != "b-t-f"
    }

    var lastSeen: Date { min(header?.time ?? receivedAt, receivedAt) }

    func isCurrent(at now: Date) -> Bool {
        guard let header, lastSeen <= now.addingTimeInterval(30) else { return false }
        if header.isEmergency { return true }
        guard now.timeIntervalSince(lastSeen) <= CompanionMapCache.maximumAge else { return false }
        return header.stale.map { $0 > now } ?? true
    }
}

struct CompanionMapCache: Codable {
    static let maximumEvents = 50
    static let maximumStorageBytes = 262_144
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
        var bytes = events.reduce(0) { $0 + $1.storageByteBudget }
        while bytes > Self.maximumStorageBytes, let oldest = events.last {
            bytes -= oldest.storageByteBudget
            events.removeLast()
        }
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

    @discardableResult
    mutating func retainEmergencySources(_ ids: Set<UUID>) -> Bool {
        let count = events.count
        events.removeAll { $0.header?.isEmergency == true && !ids.contains($0.sourceServerID) }
        return events.count != count
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

@MainActor
final class MapCacheWriteBatcher {
    private let interval: Duration
    private let write: @MainActor () -> Void
    private var task: Task<Void, Never>?

    init(interval: Duration = .seconds(1), write: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.write = write
    }

    func schedule() {
        guard task == nil else { return }
        task = Task { [weak self, interval] in
            do { try await Task.sleep(for: interval) } catch { return }
            self?.flush()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func flush() {
        guard task != nil else { return }
        cancel()
        write()
    }
}

struct CoTMapHeader {
    let uid: String
    let type: String?
    let time: Date?
    let stale: Date?
    let isEmergency: Bool

    static func parse(_ xml: String) -> Self? {
        guard CoTStreamFramer.isEvent(Data(xml.utf8)) else { return nil }
        let delegate = CoTMapHeaderParser()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let attributes = delegate.attributes,
              delegate.hasPoint || delegate.isEmergency,
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
        return Self(uid: uid, type: attributes["type"], time: time, stale: stale,
                    isEmergency: delegate.isEmergency)
    }
}

private final class CoTMapHeaderParser: NSObject, XMLParserDelegate {
    var attributes: [String: String]?
    var hasPoint = false
    var isEmergency = false
    private var depth = 0

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        if depth == 1, elementName == "event" {
            self.attributes = attributes
            let type = attributes["type"] ?? ""
            isEmergency = type == "b-a-o" || type.hasPrefix("b-a-o-")
        }
        if depth == 3, elementName == "emergency" { isEmergency = true }
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
