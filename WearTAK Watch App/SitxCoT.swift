import CoreLocation
import Foundation

enum SitxCoT {
    static func isUser(type: String) -> Bool {
        type.hasPrefix("a-") && type.split(separator: "-").dropFirst(2).starts(with: ["G", "U", "C"])
    }

    /// TAK clients identify user PLI with `__group`, `takv`, a contact `endpoint`, or ATAK's
    /// `<uid Droid>`; those markers win over the 2525 type so e.g. a K9 user is not drawn as a point.
    static func isUser(type: String, hasGroup: Bool, hasTAKVersion: Bool, hasContactEndpoint: Bool,
                       hasDeviceUID: Bool = false) -> Bool {
        type.hasPrefix("a-") && (isUser(type: type) || hasGroup || hasTAKVersion || hasContactEndpoint || hasDeviceUID)
    }

    private static let roleBadges: [String: String] = [
        "team member": "TM", "team lead": "TL", "hq": "HQ", "k9": "K9", "medic": "MED",
        "rto": "RTO", "sniper": "SNP", "forward observer": "FO",
        "armed surveillance": "AS", "assistant team leader": "ATL", "aviation": "AVN",
        "bomb tech": "BT", "command post": "CP", "critical response": "CR", "hazards": "HAZ",
        "negotiator": "NEG", "surveillance": "SRV", "tactical communicator": "TC", "toc": "TOC"
    ]

    /// Short (<= 3 character) label drawn inside an incoming user's map dot.
    static func roleBadge(_ role: String?) -> String? {
        let trimmed = role?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        let key = trimmed.lowercased().split(whereSeparator: { $0 == " " || $0 == "_" || $0 == "-" }).joined(separator: " ")
        if let badge = roleBadges[key] { return badge }
        let words = key.split(separator: " ")
        if words.count > 1 { return String(words.prefix(3).compactMap(\.first)).uppercased() }
        return String(key.prefix(3)).uppercased()
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static let pliType = "a-f-G-U-C"
    static let defaultRole = "Team Member"

    /// Callsign other TAK clients list for this watch; never blank.
    static func pliCallSign(_ callSign: String, uid: String) -> String {
        let trimmed = callSign.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "WEARTAK-\(uid.prefix(8))" : trimmed
    }

    /// ATAK-compatible self-PLI detail: contact endpoint, `__group`, `takv` and `uid Droid`.
    static func pliDetail(uid: String, callSign: String, team: String, role: String,
                          appVersion: String, osVersion: String) -> String {
        let name = escape(pliCallSign(callSign, uid: uid))
        let trimmedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupRole = escape(trimmedRole.isEmpty ? defaultRole : trimmedRole)
        return "<contact callsign=\"\(name)\" endpoint=\"*:-1:stcp\"/>" +
            "<__group name=\"\(escape(team))\" role=\"\(groupRole)\"/>" +
            "<takv device=\"Apple Watch\" platform=\"WearTAK\" os=\"\(escape(osVersion))\" version=\"\(escape(appVersion))\"/>" +
            "<uid Droid=\"\(name)\"/>"
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
    private var callSign: String?
    private var team: String?
    private var role: String?
    private var hasGroup = false
    private var hasTAKVersion = false
    private var hasContactEndpoint = false
    private var hasDeviceUID = false
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
            callSign = nil
            team = nil
            role = nil
            hasGroup = false
            hasTAKVersion = false
            hasContactEndpoint = false
            hasDeviceUID = false
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var stale = attributes["stale"].flatMap { formatter.date(from: $0) }
            if stale == nil {
                formatter.formatOptions = [.withInternetDateTime]
                stale = attributes["stale"].flatMap { formatter.date(from: $0) }
            }
            expired = stale.map { $0 <= now } ?? true
        } else if elementName == "contact" {
            callSign = attributes["callsign"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            hasContactEndpoint = !(attributes["endpoint"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        } else if elementName == "__group" {
            hasGroup = true
            team = attributes["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            role = attributes["role"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if elementName == "takv" {
            hasTAKVersion = true
        } else if elementName == "uid", !(attributes["Droid"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            hasDeviceUID = true
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
            let isUser = SitxCoT.isUser(type: eventType, hasGroup: hasGroup, hasTAKVersion: hasTAKVersion,
                                        hasContactEndpoint: hasContactEndpoint, hasDeviceUID: hasDeviceUID)
            entities.append(EntityRelayPayload(uid: eventUID, lat: point.latitude, lon: point.longitude, type: eventType,
                                               callSign: callSign, team: team, role: role, isUser: isUser))
        }
        eventUID = nil
        point = nil
    }
}