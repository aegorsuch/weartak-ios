import Foundation
import CoreFoundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// WearOS/Tracker v2 CoT aliases. Only tactical data is reconstructed; no command/config dispatch.
struct DittoCoTDocument {
    static let collections = ["track", "mapitem", "alert", "chat"]
    static let sourceID = UUID(uuidString: "D1770000-0000-4000-8000-000000000001")!
    let uid: String
    let peer: String
    let author: String?
    let time: Date
    let stale: Date
    let xml: String

    enum Failure: LocalizedError {
        case invalid
        var errorDescription: String? { "Invalid or unsupported Ditto tactical document." }
    }

    static func collection(for type: String) -> String? {
        if type == "b-t-f" { return "chat" }
        if type == "a-f-G-U-C" || type.hasPrefix("a-") && type.contains("-G-U") { return "track" }
        if type == "b-a-g" || type.hasPrefix("b-a-o") { return "alert" }
        if type.hasPrefix("a-") && !type.contains("-U") { return "mapitem" }
        return nil
    }

    static func decode(_ doc: [String: Any], collection: String, now: Date = Date()) throws -> Self {
        if collection == "chat" { return try DittoChatDocument.decode(doc, ownUID: nil, now: now) }
        return try decodeAliases(doc, collection: collection, now: now)
    }

    static func decodeAliases(_ doc: [String: Any], collection: String, now: Date = Date()) throws -> Self {
        func text(_ key: String) throws -> String {
            guard let value = doc[key] as? String, !value.isEmpty, value.count <= 512,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw Failure.invalid
            }
            return value
        }
        func number(_ key: String) throws -> Double {
            guard let value = doc[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite else { throw Failure.invalid }
            return value.doubleValue
        }
        func date(_ key: String) throws -> Date {
            let value = try number(key)
            guard value > 0, value <= 253_402_300_799_999, value.rounded(.towardZero) == value else {
                throw Failure.invalid
            }
            return Date(timeIntervalSince1970: value / 1_000)
        }
        guard Self.collections.contains(collection), try number("_v") == 2,
              let removed = doc["_r"] as? NSNumber, CFGetTypeID(removed) == CFBooleanGetTypeID(),
              !removed.boolValue, doc["visible"] as? Bool != false, doc["f"] as? Bool != false else {
            throw Failure.invalid
        }
        let uid = try text("d"), peer = try text("a"), type = try text("w")
        guard try text("_id") == uid, Self.collection(for: type) == collection else { throw Failure.invalid }
        let time = try date("b"), start = try date("n"), stale = try date("o")
        let lat = try number("j"), lon = try number("l")
        guard time <= now.addingTimeInterval(300), stale >= time,
              (-90...90).contains(lat), (-180...180).contains(lon),
              let detail = doc["r"] as? String, detail.utf8.count <= 50_000 else { throw Failure.invalid }
        let parsed = DittoXMLFields()
        guard parsed.parse(detail, expectedRoot: "detail") else { throw Failure.invalid }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let xml = """
        <event version="\(escape(try text("g")))" uid="\(escape(uid))" type="\(escape(type))" time="\(formatter.string(from: time))" start="\(formatter.string(from: start))" stale="\(formatter.string(from: stale))" how="\(escape(try text("p")))" access="\(escape(try text("q")))"><point lat="\(lat)" lon="\(lon)" hae="\(try number("i"))" ce="\(try number("h"))" le="\(try number("k"))"/>\(detail)</event>
        """
        guard xml.utf8.count <= 55_000 else { throw Failure.invalid }
        return Self(uid: uid, peer: peer, author: try doc["AuthorId"].map { _ in try text("AuthorId") },
                    time: time, stale: stale, xml: xml)
    }

    static func make(xml: String, peer: String, author: String, callsign: String) throws -> (String, [String: Any]) {
        let fields = DittoXMLFields()
        guard fields.parse(xml, expectedRoot: "event"), let uid = fields.event["uid"],
              let type = fields.event["type"], let collection = collection(for: type),
              let time = fields.event["time"].flatMap(date),
              let start = fields.event["start"].flatMap(date),
              let stale = fields.event["stale"].flatMap(date) else { throw Failure.invalid }
        if collection == "chat" {
            guard TAKChatMessage.parse(xml, ownUID: author)?.senderUID == author else { throw Failure.invalid }
        } else {
            guard collection == "track" ? uid == author : fields.parentUID == author else { throw Failure.invalid }
        }
        var doc: [String: Any] = [
            "_id": uid, "_r": false, "_v": 2, "a": peer, "b": milliseconds(time),
            "d": uid, "e": collection == "alert" ? "\(fields.callsign ?? callsign)-Alert" : fields.callsign ?? callsign,
            "authorCs": callsign, "AuthorId": author, "authorType": type, "visible": true,
            "g": fields.event["version"] ?? "2.0", "n": milliseconds(start), "o": milliseconds(stale),
            "p": fields.event["how"] ?? "m-g", "q": fields.event["access"] ?? "Undefined",
            "r": DittoTrackDocument.detail(in: xml), "w": type,
        ]
        for (key, attribute) in [("h", "ce"), ("i", "hae"), ("j", "lat"), ("k", "le"), ("l", "lon")] {
            guard let value = fields.point[attribute].flatMap(Double.init), value.isFinite else { throw Failure.invalid }
            doc[key] = value
        }
        if collection != "alert" { doc["c"] = fields.callsign ?? callsign; doc["f"] = true }
        if collection == "chat" {
            doc["c"] = callsign
            doc["e"] = callsign
            doc["o"] = milliseconds(time.addingTimeInterval(86_400))
            guard let chat = TAKChatMessage.parse(xml, ownUID: author) else { throw Failure.invalid }
            doc["eventUid"] = uid
            doc["_id"] = chat.id
            doc["d"] = author
            doc["msg"] = chat.text
            doc["room"] = chat.title ?? fields.room ?? chat.recipientUID
            doc["roomId"] = chat.conversationUid ?? chat.recipientUID
            doc["parent"] = fields.parent ?? "RootContactGroup"
            doc["authorType"] = "a-f-G-U-C"
            doc["authorLoc"] = "\(doc["j"]!),\(doc["l"]!),\(doc["i"]!)"
        }
        _ = try decode(doc, collection: collection)
        return (collection, doc)
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
    private static func milliseconds(_ value: Date) -> Double { (value.timeIntervalSince1970 * 1_000).rounded() }
    private static func date(_ value: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: value) { return date }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: value)
    }
}

/// Replay suppression is shared across collections and rehydrated once per runtime start.
struct DittoIngress {
    private struct Watermark { let time: Date; let stale: Date }
    private var watermarks: [String: Watermark] = [:]

    mutating func accept(_ doc: DittoCoTDocument, ownUID: String, localPeer: String, now: Date = Date()) -> Bool {
        guard doc.uid != ownUID, doc.author != ownUID, doc.peer != localPeer else { return false }
        let key = doc.peer + "\u{0}" + doc.uid
        if let prior = watermarks[key], doc.time <= prior.time { return false }
        if watermarks[key] == nil, watermarks.count >= 8_192 {
            watermarks = watermarks.filter { $0.value.stale > now }
            guard watermarks.count < 8_192 else { return false }
        }
        watermarks[key] = Watermark(time: doc.time, stale: doc.stale)
        return true
    }
}

private final class DittoXMLFields: NSObject, XMLParserDelegate {
    var event: [String: String] = [:]
    var point: [String: String] = [:]
    var callsign: String?
    var parentUID: String?
    var room: String?
    var parent: String?
    private var depth = 0
    private var root = ""
    private var valid = true
    func parse(_ xml: String, expectedRoot: String) -> Bool {
        guard xml.utf8.count <= 55_000, !xml.uppercased().contains("<!DOCTYPE"),
              !xml.uppercased().contains("<!ENTITY") else { return false }
        let p = XMLParser(data: Data(xml.utf8))
        p.shouldResolveExternalEntities = false
        p.delegate = self
        return p.parse() && valid && root == expectedRoot
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        if depth == 1 { root = name; if name == "event" { event = attributes } }
        if name == "event", depth != 1 { valid = false }
        if name == "detail", depth != (root == "event" ? 2 : 1) { valid = false }
        if name == "point", depth == 2 { point = attributes }
        if name == "contact" { callsign = attributes["callsign"] }
        if name == "__chat", depth == 3 { room = attributes["chatroom"]; parent = attributes["parent"] }
        if name == "link", depth == 3, attributes["relation"] == "p-p" { parentUID = attributes["uid"] }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        depth -= 1
    }
}
