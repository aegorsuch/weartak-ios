import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum BridgeWire {
    static let version = 1
    static let maximumMessageBytes = 60_000

    struct Message: Codable {
        enum Kind: String, Codable { case hello, cot, status, acknowledgement, channels, channelUpdate, mapSnapshot, sitxConfig }
        let kind: Kind
        var version: Int = BridgeWire.version
        var id: UUID = UUID()
        var xml: String?
        var ready: Bool?
        var configured: Bool?
        var detail: String?
        var serverID: UUID?
        var channelBitPosition: Int?
        var channelActive: Bool?
        var channelServers: [TAKChannelServer]?
        var sourceServerID: UUID?
        var sourceGeneration: Int?
        var clientUID: String?
        var sessionID: UUID?
        var mapEvents: [CompanionMapEvent]?
        var enabledServerIDs: [UUID]?
        var snapshotTruncated: Bool?
        var refreshError: String?
        var phoneReporting: String?
        var phoneLocationEnabled: Bool?
        var chatEvents: [CompanionMapEvent]?
        var sitxConfig: SitxRelayConfig?
        /// Phone-side Sit(x) relay state; empty when Companion holds no Sit(x) configuration.
        var sitxStatus: String?

        func encoded() throws -> Data {
            let data = try JSONEncoder().encode(self)
            guard data.count <= BridgeWire.maximumMessageBytes else { throw Failure.tooLarge }
            return data
        }

        static func decode(_ data: Data) throws -> Self {
            guard data.count <= BridgeWire.maximumMessageBytes else { throw Failure.tooLarge }
            let message = try JSONDecoder().decode(Self.self, from: data)
            guard message.version == BridgeWire.version else { throw Failure.unsupportedVersion }
            if message.kind == .cot {
                guard let xml = message.xml, CoTStreamFramer.isEvent(Data(xml.utf8)) else { throw Failure.invalidCoT }
            }
            if let events = message.mapEvents {
                guard message.kind == .mapSnapshot, events.count <= CompanionMapCache.maximumEvents,
                      events.allSatisfy({ $0.isValid }) else { throw Failure.invalidCoT }
            }
            if message.kind == .sitxConfig {
                guard let config = message.sitxConfig, config.isValid else { throw Failure.invalidSitxConfig }
            }
            if let events = message.chatEvents {
                guard message.kind == .status, events.count <= CompanionChatBuffer.maximumEvents,
                      events.allSatisfy({ CompanionChatBuffer.isValid($0) }) else { throw Failure.invalidCoT }
            }
            return message
        }
    }

    enum Failure: LocalizedError {
        case tooLarge, unsupportedVersion, invalidCoT, invalidSitxConfig
        var errorDescription: String? {
            switch self {
            case .invalidSitxConfig: return "The Sit(x) relay settings from the watch are invalid."
            case .tooLarge: return "The Companion message exceeds the supported size."
            case .unsupportedVersion: return "Update both WearTAK apps to matching versions."
            case .invalidCoT: return "The Companion message contains invalid CoT map data."
            }
        }
    }
}

/// Watch → phone hand-off of Sit(x) streaming. watchOS hardware blocks WebSockets (TN3135), so Companion holds
/// the Sit(x) connection. A refresh token transfers ownership: the watch deletes its copy after the phone accepts it,
/// because Sit(x) invalidates the whole token family if a rotated refresh token is reused.
struct SitxRelayConfig: Codable, Equatable {
    static let serverID = UUID(uuidString: "5170A7A0-0000-4000-8000-000000005177")!
    var enabled: Bool
    var host: String
    var flowTag: String
    var groupName: String?
    var refreshToken: String?

    var isValid: Bool {
        guard !enabled else {
            guard let url = URL(string: host), url.scheme == "https", let name = url.host,
                  name == "sitx.io" || name.hasSuffix(".sitx.io"),
                  !flowTag.isEmpty, flowTag.count <= 256, (groupName?.count ?? 0) <= 256,
                  (refreshToken?.count ?? 0) <= 8_192 else { return false }
            return refreshToken.map { !$0.isEmpty } ?? true
        }
        return true
    }
}

struct CompanionChatBuffer {
    static let maximumEvents = 32
    static let maximumAge: TimeInterval = 300
    private(set) var events: [CompanionMapEvent] = []

    static func isValid(_ event: CompanionMapEvent) -> Bool {
        event.sourceGeneration >= 0 && event.receivedAt.timeIntervalSince1970.isFinite &&
            CoTStreamFramer.isEvent(Data(event.xml.utf8)) && event.header?.type == "b-t-f"
    }

    // Retain until expiry, not first transmission: watch inbox deduplication makes polling retry-safe.
    mutating func receive(_ event: CompanionMapEvent, now: Date = Date()) -> Bool {
        guard Self.isValid(event) else { return false }
        prune(now: now)
        guard !events.contains(where: {
            $0.sourceServerID == event.sourceServerID && $0.header?.uid == event.header?.uid
        }) else { return false }
        events.append(event)
        var evicted = false
        while events.count > Self.maximumEvents || events.reduce(0, { $0 + $1.xml.utf8.count }) > 40_000 {
            events.removeFirst()
            evicted = true
        }
        return evicted
    }

    mutating func prune(now: Date = Date(), enabledServerIDs: Set<UUID>? = nil) {
        events.removeAll { event in
            now.timeIntervalSince(event.receivedAt) > Self.maximumAge || event.receivedAt > now.addingTimeInterval(30) ||
                (enabledServerIDs.map { !$0.contains(event.sourceServerID) } ?? false)
        }
    }

    func filling(_ message: BridgeWire.Message) throws -> BridgeWire.Message {
        var reply = message
        reply.chatEvents = []
        for event in events.reversed() {
            var candidate = reply
            candidate.chatEvents?.insert(event, at: 0)
            do {
                _ = try candidate.encoded()
                reply = candidate
            } catch BridgeWire.Failure.tooLarge {
                break
            }
        }
        _ = try reply.encoded()
        return reply
    }
}

struct CoTStreamFramer {
    private var buffer = Data()
    private let maximumBufferBytes = 262_144

    mutating func append(_ bytes: Data) throws -> [Data] {
        guard buffer.count + bytes.count <= maximumBufferBytes else { throw BridgeWire.Failure.tooLarge }
        buffer.append(bytes)
        var events: [Data] = []
        let start = Data("<event".utf8)
        let end = Data("</event>".utf8)
        while let opening = buffer.range(of: start) {
            if opening.lowerBound > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<opening.lowerBound) }
            var search = buffer.startIndex
            var consumed = false
            while search < buffer.endIndex, let closing = buffer.range(of: end, in: search..<buffer.endIndex) {
                let candidate = Data(buffer[buffer.startIndex..<closing.upperBound])
                if Self.isEvent(candidate) {
                    events.append(candidate)
                    buffer.removeSubrange(buffer.startIndex..<closing.upperBound)
                    consumed = true
                    break
                }
                search = closing.upperBound
            }
            if !consumed { break }
        }
        if buffer.range(of: start) == nil, buffer.count > start.count {
            buffer = Data(buffer.suffix(start.count - 1))
        }
        return events
    }

    static func isEvent(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= BridgeWire.maximumMessageBytes,
              data.range(of: Data("<!DOCTYPE".utf8)) == nil else { return false }
        let parser = XMLParser(data: data)
        let root = CoTRootValidator()
        parser.shouldResolveExternalEntities = false
        parser.delegate = root
        return parser.parse() && root.root == "event"
    }
}

private final class CoTRootValidator: NSObject, XMLParserDelegate {
    var root: String?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if root == nil { root = elementName }
    }
}