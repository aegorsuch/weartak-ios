import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Builds the Ditto `track` document WearTAK-Tracker publishes, from the watch's own PLI CoT event.
/// Field names and sentinel values mirror Tracker's `DittoClient.publishTrack` so ATAK Ditto peers read both alike.
enum DittoTrackDocument {
    static let collection = "track"
    static let upsertQuery = "INSERT INTO track DOCUMENTS (:doc) ON ID CONFLICT DO UPDATE"
    static let unknownAccuracy = 9_999_999.0
    static let pliType = "a-f-G-U-C"

    static func make(fromPLI xml: String, peerKey: String, appVersion: String,
                     now: Date = Date()) -> [String: Any]? {
        let data = Data(xml.utf8)
        guard !data.isEmpty, data.count <= 60_000, !xml.contains("<!DOCTYPE") else { return nil }
        let fields = PLIFields()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = fields
        guard parser.parse(), fields.root == "event", let uid = fields.uid, !uid.isEmpty, uid.count <= 256,
              let type = fields.type, type == pliType,
              let latitude = fields.latitude, let longitude = fields.longitude,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }

        let nowMilliseconds = milliseconds(now)
        let staleMilliseconds = fields.stale.map(milliseconds) ?? nowMilliseconds + 180_000
        guard staleMilliseconds > nowMilliseconds else { return nil }
        let callSign = fields.callSign.flatMap { $0.isEmpty ? nil : $0 } ?? uid
        let hae = fields.hae.flatMap { $0.isFinite && $0 < unknownAccuracy ? $0 : nil } ?? unknownAccuracy
        return [
            "_id": uid,
            "_r": false,
            "_v": 2,
            "authorCs": callSign,
            "AuthorId": uid,
            "authorType": pliType,
            "visible": true,
            "a": peerKey,
            "b": nowMilliseconds,
            "c": callSign,
            "d": uid,
            "e": callSign,
            "f": true,
            "g": appVersion,
            "h": accuracy(fields.ce),
            "i": hae,
            "j": latitude,
            "k": accuracy(fields.le),
            "l": longitude,
            "n": nowMilliseconds,
            "o": staleMilliseconds,
            "p": "m-g",
            "q": "Undefined",
            "r": detail(in: xml),
            "r1": String(fields.speed ?? 0),
            "r2": String(hae),
            "w": pliType,
        ]
    }

    /// The raw `<detail>` element, matching Tracker's regex extraction; an empty detail when absent.
    static func detail(in xml: String) -> String {
        guard let open = xml.range(of: "<detail"),
              let close = xml.range(of: "</detail>", range: open.upperBound..<xml.endIndex) else { return "<detail/>" }
        return String(xml[open.lowerBound..<close.upperBound])
    }

    private static func accuracy(_ value: Double?) -> Double {
        guard let value, value.isFinite, value >= 0 else { return unknownAccuracy }
        return value
    }

    private static func milliseconds(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

private final class PLIFields: NSObject, XMLParserDelegate {
    var root: String?
    var uid: String?
    var type: String?
    var stale: Date?
    var latitude: Double?
    var longitude: Double?
    var hae: Double?
    var ce: Double?
    var le: Double?
    var callSign: String?
    var speed: Double?
    private var depth = 0

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        if root == nil { root = elementName }
        switch elementName {
        case "event" where depth == 1:
            uid = attributes["uid"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            type = attributes["type"]
            stale = attributes["stale"].flatMap(Self.date)
        case "point" where depth == 2:
            latitude = attributes["lat"].flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
            longitude = attributes["lon"].flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
            hae = attributes["hae"].flatMap(Double.init)
            ce = attributes["ce"].flatMap(Double.init)
            le = attributes["le"].flatMap(Double.init)
        case "contact":
            if callSign == nil { callSign = attributes["callsign"]?.trimmingCharacters(in: .whitespacesAndNewlines) }
        case "track":
            speed = attributes["speed"].flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        depth -= 1
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
