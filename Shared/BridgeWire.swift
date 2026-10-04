import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum BridgeWire {
    static let version = 1
    static let maximumMessageBytes = 60_000

    struct Message: Codable {
        enum Kind: String, Codable { case hello, cot, status, acknowledgement, channels, channelUpdate, mapSnapshot }
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
            return message
        }
    }

    enum Failure: LocalizedError {
        case tooLarge, unsupportedVersion, invalidCoT
        var errorDescription: String? {
            switch self {
            case .tooLarge: return "The Companion message exceeds the supported size."
            case .unsupportedVersion: return "Update both WearTAK apps to matching versions."
            case .invalidCoT: return "The Companion message contains invalid CoT map data."
            }
        }
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