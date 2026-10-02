import CoreLocation
import Foundation

enum SitxCoT {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func event(uid: String, type: String, coordinate: CLLocationCoordinate2D,
                      detail: String, lifetime: TimeInterval, now: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        let start = formatter.string(from: now)
        let stale = formatter.string(from: now.addingTimeInterval(lifetime))
        return "<event version=\"2.0\" uid=\"\(escape(uid))\" type=\"\(escape(type))\" time=\"\(start)\" start=\"\(start)\" stale=\"\(stale)\" how=\"m-g\"><point lat=\"\(coordinate.latitude)\" lon=\"\(coordinate.longitude)\" hae=\"9999999\" ce=\"9999999\" le=\"9999999\"/><detail>\(detail)</detail></event>"
    }

    static func parse(_ data: Data, excluding uid: String, now: Date = Date()) -> [EntityRelayPayload] {
        let delegate = CoTEntityParser(excludedUID: uid, now: now)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { return [] }
        return delegate.entities
    }
}

private final class CoTEntityParser: NSObject, XMLParserDelegate {
    let excludedUID: String
    let now: Date
    var entities: [EntityRelayPayload] = []
    private var eventUID: String?
    private var eventType: String?
    private var point: CLLocationCoordinate2D?
    private var expired = false

    init(excludedUID: String, now: Date) {
        self.excludedUID = excludedUID
        self.now = now
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if elementName == "event" {
            eventUID = attributes["uid"]
            eventType = attributes["type"]
            point = nil
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var stale = attributes["stale"].flatMap { formatter.date(from: $0) }
            if stale == nil {
                formatter.formatOptions = [.withInternetDateTime]
                stale = attributes["stale"].flatMap { formatter.date(from: $0) }
            }
            expired = stale.map { $0 <= now } ?? true
        } else if elementName == "point",
                  let latitude = attributes["lat"].flatMap(Double.init),
                  let longitude = attributes["lon"].flatMap(Double.init),
                  latitude.isFinite, longitude.isFinite {
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            if CLLocationCoordinate2DIsValid(coordinate) { point = coordinate }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        guard elementName == "event" else { return }
        if let eventUID, eventUID != excludedUID, !eventUID.isEmpty,
           let eventType, eventType.hasPrefix("a-"), let point, !expired {
            entities.append(EntityRelayPayload(uid: eventUID, lat: point.latitude, lon: point.longitude, type: eventType))
        }
        eventUID = nil
        point = nil
    }
}