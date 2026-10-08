#if canImport(CoreLocation)
import CoreLocation
#endif
import Foundation
#if canImport(OSLog)
import OSLog
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

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

    #if canImport(CoreLocation)
    static func event(uid: String, type: String, coordinate: CLLocationCoordinate2D,
                      detail: String, lifetime: TimeInterval, now: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        let start = formatter.string(from: now)
        let stale = formatter.string(from: now.addingTimeInterval(lifetime))
        return "<event version=\"2.0\" uid=\"\(escape(uid))\" type=\"\(escape(type))\" time=\"\(start)\" start=\"\(start)\" stale=\"\(stale)\" how=\"m-g\"><point lat=\"\(coordinate.latitude)\" lon=\"\(coordinate.longitude)\" hae=\"9999999\" ce=\"9999999\" le=\"9999999\"/><detail>\(detail)</detail></event>"
    }
    #endif

    static func parse(_ data: Data, excluding uid: String, now: Date = Date()) -> [EntityRelayPayload] {
        diagnose("CoT ingress: \(data.count) bytes")
        let delegate = CoTEntityParser(excludedUID: uid, now: now)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else {
            diagnose("Rejected malformed CoT XML")
            return []
        }
        diagnose("CoT parsed: \(delegate.entities.count) accepted entities")
        return delegate.entities
    }

    fileprivate static func diagnose(_ message: String) {
        #if canImport(OSLog)
        Logger(subsystem: "com.aegorsuch.weartak", category: "RemoteAlerts")
            .debug("\(message, privacy: .public)")
        #endif
    }
}

private final class CoTEntityParser: NSObject, XMLParserDelegate {
    let excludedUID: String
    let now: Date
    var entities: [EntityRelayPayload] = []
    private var eventUID: String?
    private var eventType: String?
    private var point: (latitude: Double, longitude: Double)?
    private var callSign: String?
    private var team: String?
    private var role: String?
    private var senderUID: String?
    private var hasOwnParent = false
    private var parentUID: String?
    private var parentCallSign: String?
    private var hasGroup = false
    private var hasTAKVersion = false
    private var hasContactEndpoint = false
    private var hasDeviceUID = false
    private var expired = false
    private var sentAt: Date?
    private var how: String?
    private var emergencyState: EmergencyState?
    private var alertCategory: String?
    private var staleAt: Date?
    private var invalidStaleTime = false
    private var depth = 0
    private var emergencyText = ""
    private var remarksText = ""
    private var textElement: String?

    init(excludedUID: String, now: Date) {
        self.excludedUID = excludedUID
        self.now = now
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        if elementName == "event", depth == 1 {
            eventUID = attributes["uid"]
            eventType = attributes["type"]
            point = nil
            callSign = nil
            team = nil
            role = nil
            senderUID = nil
            hasOwnParent = false
            parentUID = nil
            parentCallSign = nil
            hasGroup = false
            hasTAKVersion = false
            hasContactEndpoint = false
            hasDeviceUID = false
            emergencyState = eventType == "b-a-o-can" || eventType?.hasPrefix("b-a-o-can-") == true ? .cancel :
                (eventType == "b-a-o" || eventType?.hasPrefix("b-a-o-") == true ? .alert : nil)
            alertCategory = nil
            emergencyText = ""
            remarksText = ""
            textElement = nil
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var stale = attributes["stale"].flatMap { formatter.date(from: $0) }
            if stale == nil {
                formatter.formatOptions = [.withInternetDateTime]
                stale = attributes["stale"].flatMap { formatter.date(from: $0) }
            }
            expired = stale.map { $0 <= now } ?? true
            staleAt = stale
            invalidStaleTime = attributes["stale"] != nil && stale == nil
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            sentAt = attributes["time"].flatMap { formatter.date(from: $0) }
            if sentAt == nil {
                formatter.formatOptions = [.withInternetDateTime]
                sentAt = attributes["time"].flatMap { formatter.date(from: $0) }
            }
            how = attributes["how"]
        } else if elementName == "contact" {
            callSign = attributes["callsign"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            hasContactEndpoint = !(attributes["endpoint"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        } else if elementName == "__group" {
            hasGroup = true
            team = attributes["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            role = attributes["role"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if elementName == "takv" {
            // Sit(x) web-portal markers carry `<takv device="Map Marker"/>`; that is not a user.
            hasTAKVersion = attributes["device"]?.caseInsensitiveCompare("Map Marker") != .orderedSame
        } else if elementName == "uid", !(attributes["Droid"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            hasDeviceUID = true
        } else if elementName == "link", ["p-p", "p-c"].contains(attributes["relation"] ?? "") {
            if attributes["uid"] == excludedUID { hasOwnParent = true }
            parentUID = attributes["uid"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            parentCallSign = attributes["parent_callsign"]
            if attributes["relation"] == "p-p" { senderUID = parentUID }
        } else if elementName == "emergency" {
            let cancelled = ["true", "1"].contains(attributes["cancel"]?.lowercased() ?? "")
            if cancelled { emergencyState = .cancel }
            else if emergencyState != .cancel { emergencyState = .alert }
            alertCategory = attributes["type"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            textElement = "emergency"
        } else if elementName == "remarks" {
            textElement = "remarks"
        } else if elementName == "point", depth == 2,
                  let latitude = attributes["lat"].flatMap(Double.init),
                  let longitude = attributes["lon"].flatMap(Double.init),
                  latitude.isFinite, longitude.isFinite {
            if (-90...90).contains(latitude), (-180...180).contains(longitude) {
                point = (latitude, longitude)
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if textElement == "emergency" { emergencyText += string }
        if textElement == "remarks" { remarksText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        defer { depth -= 1 }
        if elementName == textElement { textElement = nil }
        guard elementName == "event" else { return }
        defer { eventUID = nil; point = nil }
        if emergencyState != nil {
            senderUID = parentUID ?? senderUID
            if senderUID == nil, let eventUID, eventUID.hasSuffix("-9-1-1") {
                senderUID = String(eventUID.dropLast("-9-1-1".count))
            }
            if callSign?.isEmpty ?? true {
                let text = emergencyText.trimmingCharacters(in: .whitespacesAndNewlines)
                callSign = parentCallSign ?? (text.isEmpty ? nil : text)
            }
            if alertCategory?.isEmpty ?? true {
                let text = remarksText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { alertCategory = text }
            }
        }
        guard let eventUID, !eventUID.isEmpty, let eventType else {
            SitxCoT.diagnose("Rejected CoT entity: missing UID/type")
            return
        }
        guard eventType.hasPrefix("a-") || emergencyState != nil else {
            SitxCoT.diagnose("Rejected CoT entity: unsupported type")
            return
        }
        guard eventUID != excludedUID,
              emergencyState == nil || (!hasOwnParent && senderUID != excludedUID &&
                eventUID != excludedUID + "-9-1-1" && !eventUID.hasPrefix(excludedUID + "-alert-")) else {
            SitxCoT.diagnose("Rejected CoT entity: local device UID or emergency parent")
            return
        }
        guard emergencyState == nil || (sentAt != nil && !invalidStaleTime) else {
            SitxCoT.diagnose("Rejected emergency: missing/invalid CoT time or invalid stale timestamp")
            return
        }
        guard point != nil || emergencyState != nil else {
            SitxCoT.diagnose("Rejected ordinary entity: missing/invalid coordinates")
            return
        }
        guard !expired || emergencyState != nil else {
            SitxCoT.diagnose("Rejected ordinary entity: stale deadline passed")
            return
        }
        let isUser = SitxCoT.isUser(type: eventType, hasGroup: hasGroup, hasTAKVersion: hasTAKVersion && senderUID == nil,
                                  hasContactEndpoint: hasContactEndpoint, hasDeviceUID: hasDeviceUID)
        entities.append(EntityRelayPayload(uid: eventUID, lat: point?.latitude ?? 0, lon: point?.longitude ?? 0, type: eventType,
                                           callSign: callSign, team: team, role: role, senderUID: senderUID,
                                           isUser: emergencyState == nil && isUser, sentAt: sentAt, how: how,
                                           emergencyState: emergencyState, alertCategory: alertCategory, staleAt: staleAt,
                                           hasUsableLocation: point != nil))
    }
}