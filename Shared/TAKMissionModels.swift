import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// One map item of a Data Sync mission, reduced from its CoT so many fit in one watch message.
struct TAKMissionItem: Codable, Equatable, Identifiable {
    let uid: String
    var type: String
    var callsign: String?
    var lat: Double
    var lon: Double
    var stale: Date?
    var remark: String?
    var id: String { uid }
}

struct TAKMission: Codable, Equatable, Identifiable {
    let name: String
    var description: String?
    var itemCount: Int?
    var passwordProtected = false
    var subscribed = false
    /// Present only for subscribed missions whose map items loaded.
    var items: [TAKMissionItem]?
    var error: String?
    /// Subscribed missions only: whether the watch's mission role allows edits; nil when the role is unknown.
    var canEdit: Bool?
    var id: String { name }
}

struct TAKMissionServer: Codable, Equatable, Identifiable {
    static let selectState = "Select server to load missions"
    static let readyState = "Ready"
    static let emptyState = "No Data Sync missions"
    let id: UUID
    let name: String
    var missions: [TAKMission] = []
    var state = TAKMissionServer.selectState
    var error: String?
    /// The mission list loaded, so subscribed missions in it are authoritative for the watch map.
    var isLoaded: Bool { state == Self.readyState || state == Self.emptyState }
}

/// TAK Server Mission (Data Sync) API: `/Marti/api/missions` on TAK Server, `/api/v1/missions` on Sit(x).
enum TAKMissionAPI {
    static let maximumMissions = 40
    static let maximumItemsPerMission = 100
    static let maximumItemsTotal = 200

    enum Failure: LocalizedError, Equatable {
        case invalidResponse, invalidName, passwordProtected
        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "The server returned an unreadable mission response."
            case .invalidName: return "Invalid mission name."
            case .passwordProtected: return "Password-protected missions are not supported on the watch."
            }
        }
    }

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 128 && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Mission names are free text; encode everything that is not unreserved so names cannot add path segments.
    static func path(_ name: String, _ suffix: String = "") -> String? {
        guard isValidName(name) else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return "/missions/" + encoded + suffix
    }

    /// Parses `GET /missions`, keeping Data Sync (`tool` "public" or absent) missions only.
    static func parseList(_ data: Data) throws -> [TAKMission] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["data"] as? [[String: Any]] else { throw Failure.invalidResponse }
        var seen = Set<String>()
        var missions: [TAKMission] = []
        for entry in entries {
            guard let name = entry["name"] as? String, isValidName(name), seen.insert(name).inserted else { continue }
            if let tool = entry["tool"] as? String, !tool.isEmpty, tool.lowercased() != "public" { continue }
            let description = (entry["description"] as? String)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : String($0.prefix(120)) }
            missions.append(TAKMission(name: name, description: description,
                                       itemCount: (entry["uids"] as? [Any])?.count,
                                       passwordProtected: entry["passwordProtected"] as? Bool ?? false))
        }
        missions.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return Array(missions.prefix(maximumMissions))
    }

    /// Parses `GET /missions/{name}/cot` (an `<events>` document or bare events) into map items.
    static func parseItems(_ data: Data, limit: Int = maximumItemsPerMission) -> [TAKMissionItem] {
        guard limit > 0, data.count <= 4_194_304, var text = String(data: data, encoding: .utf8),
              !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else { return [] }
        while let start = text.range(of: "<?xml"), let end = text.range(of: "?>", range: start.upperBound..<text.endIndex) {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        let parser = XMLParser(data: Data(("<r>" + text + "</r>").utf8))
        let delegate = MissionCoTParser(limit: limit)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.items
    }

    /// Reads `GET /missions/{name}/subscription?uid=`; `MISSION_WRITE` (or an owner/subscriber role) allows edits.
    static func parseCanEdit(_ data: Data) -> Bool? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subscription = object["data"] as? [String: Any],
              let role = subscription["role"] as? [String: Any] else { return nil }
        if let permissions = role["permissions"] as? [String] { return permissions.contains("MISSION_WRITE") }
        switch role["type"] as? String {
        case "MISSION_OWNER", "MISSION_SUBSCRIBER": return true
        case "MISSION_READONLY_SUBSCRIBER": return false
        default: return nil
        }
    }

    /// Explains a failed item removal; permission failures read as a role limit rather than a network error.
    static func removalMessage(_ detail: String) -> String {
        detail.contains("403") || detail.localizedCaseInsensitiveContains("forbidden")
            ? "Your mission role doesn't allow deleting items."
            : "Couldn't delete the item from the mission: \(detail)"
    }

    /// A mission-addressed CoT update for an item; TAK Server stores it in the mission and sends it to subscribers.
    static func itemEvent(_ item: TAKMissionItem, mission: String, now: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let time = formatter.string(from: now)
        let stale = formatter.string(from: max(item.stale ?? now, now.addingTimeInterval(86_400)))
        var detail = "<contact callsign=\"\(escape(item.callsign ?? ""))\"/>"
        if let remark = item.remark, !remark.isEmpty { detail += "<remarks>\(escape(remark))</remarks>" }
        detail += "<marti><dest mission=\"\(escape(mission))\"/></marti>"
        return "<event version=\"2.0\" uid=\"\(escape(item.uid))\" type=\"\(escape(item.type))\" time=\"\(time)\" start=\"\(time)\" stale=\"\(stale)\" how=\"h-g-i-g-o\">" +
            "<point lat=\"\(item.lat)\" lon=\"\(item.lon)\" hae=\"9999999\" ce=\"9999999\" le=\"9999999\"/>" +
            "<detail>\(detail)</detail></event>"
    }

    /// Replaces a CoT atom's affiliation (`a-h-G` → `a-f-G`); non-atom types become ground points.
    static func type(_ type: String, affiliation: String) -> String {
        var parts = type.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0] == "a" else { return "a-\(affiliation)-G" }
        parts[1] = affiliation
        return parts.joined(separator: "-")
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private final class MissionCoTParser: NSObject, XMLParserDelegate {
    private let limit: Int
    private(set) var items: [TAKMissionItem] = []
    private var seen = Set<String>()
    private var event: [String: String]?
    private var point: (Double, Double)?
    private var callsign: String?
    private var remark: String?
    private var inRemarks = false
    private var eventDepth = 0
    private var depth = 0

    init(limit: Int) { self.limit = limit }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        if elementName == "event", event == nil {
            event = attributes
            point = nil
            callsign = nil
            remark = nil
            eventDepth = depth
            return
        }
        guard event != nil else { return }
        if elementName == "point", depth == eventDepth + 1,
           let lat = attributes["lat"].flatMap(Double.init), let lon = attributes["lon"].flatMap(Double.init),
           lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon) {
            point = (lat, lon)
        } else if elementName == "contact", let name = attributes["callsign"], !name.isEmpty {
            callsign = String(name.prefix(64))
        } else if elementName == "remarks" {
            inRemarks = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inRemarks, (remark?.count ?? 0) < 160 else { return }
        remark = String(((remark ?? "") + string).prefix(160))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        defer { depth -= 1 }
        if elementName == "remarks" { inRemarks = false }
        guard elementName == "event", depth == eventDepth, let attributes = event else { return }
        event = nil
        guard items.count < limit, let uid = attributes["uid"], !uid.isEmpty, uid.count <= 256,
              let type = attributes["type"], !type.isEmpty, type.count <= 64,
              !type.hasPrefix("t-"), type != "b-t-f", let point, seen.insert(uid).inserted else { return }
        // Like ATAK, a mission item stays on the map while it is in the mission, even after its CoT stale time.
        let text = remark?.trimmingCharacters(in: .whitespacesAndNewlines)
        items.append(TAKMissionItem(uid: uid, type: type, callsign: callsign, lat: point.0, lon: point.1,
                                    stale: TAKMissionAPI.date(attributes["stale"]),
                                    remark: text?.isEmpty == false ? text : nil))
    }
}
