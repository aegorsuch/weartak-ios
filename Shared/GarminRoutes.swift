import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Route geometry is independent of the short-lived point/entity cache.
struct GarminRoute: Codable, Equatable, Identifiable {
    static let version = 1
    static let maximumRoutes = 8
    static let maximumPoints = 64
    static let maximumTotalPoints = 128
    static let maximumEnvelopeBytes = 6_000

    struct Point: Codable, Equatable {
        let lat: Double
        let lon: Double
        var name: String?
        var type: String? = nil

        var isCheckpoint: Bool { type == nil || type == "b-m-p-w" }

        var routeListName: String? {
            guard let name else { return nil }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        var payload: [String: Any] {
            var value: [String: Any] = ["lat": lat, "lon": lon]
            if let name { value["name"] = name }
            if let type { value["type"] = type }
            return value
        }
    }

    let serverId: String
    let uid: String
    var name: String
    var missionName: String?
    var senderUid: String?
    let points: [Point]
    var method: String? = nil
    var id: String { serverId + "\n" + uid }
    var checkpointIndices: [Int] { points.indices.filter { points[$0].isCheckpoint } }
    var navigationIndices: [Int] { points.indices.filter { points[$0].isCheckpoint || $0 == points.count - 1 } }
    var namedPoints: [(index: Int, point: Point, name: String)] {
        points.enumerated().compactMap { index, point in
            point.routeListName.map { (index: index, point: point, name: $0) }
        }
    }

    var payload: [String: Any] {
        var value: [String: Any] = [
            "routeVersion": Self.version, "serverId": serverId, "uid": uid,
            "name": name, "points": points.map(\.payload)
        ]
        if let missionName { value["missionName"] = missionName }
        if let senderUid { value["senderUid"] = senderUid }
        if let method { value["method"] = method }
        return value
    }

    var removalPayload: [String: Any] {
        ["routeVersion": Self.version, "serverId": serverId, "uid": uid]
    }

    static func validText(_ text: String, maximum: Int) -> Bool {
        !text.isEmpty && text.utf8.count <= maximum &&
            !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    func validated() throws -> Self {
        guard Self.validText(serverId, maximum: 64), Self.validText(uid, maximum: 128),
              Self.validText(name, maximum: 64),
              missionName.map({ Self.validText($0, maximum: 128) }) ?? true,
              senderUid.map({ Self.validText($0, maximum: 128) }) ?? true,
              method.map({ Self.validText($0, maximum: 64) }) ?? true,
              (2...Self.maximumPoints).contains(points.count),
              points.allSatisfy({
                  $0.lat.isFinite && $0.lon.isFinite && (-90...90).contains($0.lat) &&
                      (-180...180).contains($0.lon) &&
                      ($0.type.map { Self.validText($0, maximum: 64) } ?? true) &&
                      ($0.name.map { Self.validText($0, maximum: 64) } ?? true)
              }) else { throw Failure.invalid }
        let data = try JSONSerialization.data(withJSONObject: ["msgType": "route", "payload": payload])
        guard data.count <= Self.maximumEnvelopeBytes else { throw Failure.envelopeBudget }
        return self
    }

    enum Failure: LocalizedError {
        case invalid, envelopeBudget, capacity, malformedXML
        var errorDescription: String? {
            switch self {
            case .invalid: return "Route rejected: invalid metadata or geometry (2–64 points required)."
            case .envelopeBudget: return "Route rejected: its full message exceeds 6,000 bytes."
            case .capacity: return "Route rejected: the 8-route or 128-point limit was reached."
            case .malformedXML: return "Routes could not be read from the server response."
            }
        }
    }
}

struct GarminRouteStore: Codable {
    struct Entry: Codable {
        var route: GarminRoute
        var live: Bool
        var missions: Set<String>
    }
    private(set) var entries: [Entry] = []
    var routes: [GarminRoute] { entries.map(\.route) }

    func validated() throws -> Self {
        guard entries.count <= GarminRoute.maximumRoutes,
              entries.reduce(0, { $0 + $1.route.points.count }) <= GarminRoute.maximumTotalPoints else {
            throw GarminRoute.Failure.capacity
        }
        var keys = Set<String>()
        for entry in entries {
            _ = try entry.route.validated()
            guard keys.insert(entry.route.serverId + "\n" + entry.route.uid).inserted,
                  entry.missions.count <= 40,
                  entry.live || !entry.missions.isEmpty,
                  entry.missions.allSatisfy({ GarminRoute.validText($0, maximum: 128) }) else {
                throw GarminRoute.Failure.invalid
            }
        }
        return self
    }

    mutating func upsert(_ value: GarminRoute, mission: String? = nil) throws {
        let route = try value.validated()
        guard mission.map({ GarminRoute.validText($0, maximum: 128) && route.missionName == $0 }) ?? true else {
            throw GarminRoute.Failure.invalid
        }
        let index = entries.firstIndex { $0.route.serverId == route.serverId && $0.route.uid == route.uid }
        let count = entries.reduce(0) { $0 + $1.route.points.count } -
            (index.map { entries[$0].route.points.count } ?? 0) + route.points.count
        guard count <= GarminRoute.maximumTotalPoints,
              index != nil || entries.count < GarminRoute.maximumRoutes else { throw GarminRoute.Failure.capacity }
        if let index, let mission, !entries[index].missions.contains(mission),
           entries[index].missions.count >= 40 { throw GarminRoute.Failure.capacity }
        if let index {
            entries[index].route = route
            if let mission { entries[index].missions.insert(mission) }
            else { entries[index].live = true }
        } else {
            entries.append(Entry(route: route, live: mission == nil,
                                 missions: mission.map { [$0] } ?? []))
        }
    }

    mutating func remove(serverId: String, uid: String) {
        entries.removeAll { $0.route.serverId == serverId && $0.route.uid == uid }
    }

    mutating func removeServer(_ serverId: String) {
        entries.removeAll { $0.route.serverId == serverId }
    }

    mutating func removeMissionItem(serverId: String, name: String, uid: String) {
        for index in entries.indices where entries[index].route.serverId == serverId && entries[index].route.uid == uid {
            entries[index].missions.remove(name)
            refreshMissionName(at: index)
        }
        entries.removeAll { !$0.live && $0.missions.isEmpty }
    }

    mutating func retainServers(_ ids: Set<String>) {
        entries.removeAll { !ids.contains($0.route.serverId) }
    }

    mutating func retainMissions(serverId: String, names: Set<String>) {
        for index in entries.indices where entries[index].route.serverId == serverId {
            entries[index].missions.formIntersection(names)
            refreshMissionName(at: index)
        }
        entries.removeAll { !$0.live && $0.missions.isEmpty }
    }

    /// A failed/over-budget refresh must not erase the last complete mission route set.
    mutating func replaceMission(serverId: String, name: String, routes: [GarminRoute]) throws {
        var candidate = self
        for index in candidate.entries.indices where candidate.entries[index].route.serverId == serverId {
            candidate.entries[index].missions.remove(name)
            candidate.refreshMissionName(at: index)
        }
        candidate.entries.removeAll { !$0.live && $0.missions.isEmpty }
        for route in routes {
            guard route.serverId == serverId, route.missionName == name else { throw GarminRoute.Failure.invalid }
            try candidate.upsert(route, mission: name)
        }
        self = candidate
    }

    private mutating func refreshMissionName(at index: Int) {
        entries[index].route.missionName = entries[index].live ? nil : entries[index].missions.sorted().first
    }
}

enum GarminRouteCoT {
    enum Event {
        case route(GarminRoute)
        case remove(String)
    }

    static func parse(_ data: Data, serverId: String, missionName: String? = nil) throws -> [Event] {
        guard data.count <= 4_194_304, var xml = String(data: data, encoding: .utf8),
              !xml.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !xml.localizedCaseInsensitiveContains("<!ENTITY") else { throw GarminRoute.Failure.malformedXML }
        while let start = xml.range(of: "<?xml"), let end = xml.range(of: "?>", range: start.upperBound..<xml.endIndex) {
            xml.removeSubrange(start.lowerBound..<end.upperBound)
        }
        let delegate = RouteParser(serverId: serverId, missionName: missionName)
        let parser = XMLParser(data: Data(("<routes>" + xml + "</routes>").utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), parser.parserError == nil, delegate.failure == nil else {
            throw delegate.failure ?? GarminRoute.Failure.malformedXML
        }
        return delegate.events
    }
}

private final class RouteParser: NSObject, XMLParserDelegate {
    let serverId: String
    let missionName: String?
    var events: [GarminRouteCoT.Event] = []
    var failure: GarminRoute.Failure?
    private var depth = 0
    private var eventDepth = 0
    private var attributes: [String: String]?
    private var name: String?
    private var senderUid: String?
    private var method: String?
    private var points: [GarminRoute.Point] = []
    private var removalUID: String?
    private var invalidGeometry = false

    init(serverId: String, missionName: String?) {
        self.serverId = serverId
        self.missionName = missionName
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes values: [String: String]) {
        depth += 1
        guard depth <= 32 else { fail(parser, .malformedXML); return }
        if elementName == "event", attributes == nil {
            attributes = values
            eventDepth = depth
            name = nil
            senderUid = nil
            method = nil
            points = []
            removalUID = nil
            invalidGeometry = false
            return
        }
        guard let attributes else { return }
        guard depth == eventDepth + 2 else { return }
        let type = attributes["type"] ?? ""
        if type == "t-x-d-d", elementName == "link" {
            removalUID = values["uid"]
        }
        guard type == "b-m-r" || type.hasPrefix("b-m-r-") else { return }
        if elementName == "contact" { name = values["callsign"] }
        if elementName == "link_attr" { method = values["method"] }
        if elementName == "link", values["relation"] == "p-p" { senderUid = values["uid"] }
        if elementName == "link", values["relation"] == "c", values["point"] == nil {
            invalidGeometry = true
        }
        if elementName == "link", values["relation"] != "p-p", let point = values["point"] {
            let fields = point.split(separator: ",", omittingEmptySubsequences: false)
            guard (2...3).contains(fields.count), let lat = Double(fields[0]),
                  let lon = Double(fields[1]), lat.isFinite, lon.isFinite,
                  (-90...90).contains(lat), (-180...180).contains(lon),
                  points.count < GarminRoute.maximumPoints else {
                invalidGeometry = true
                return
            }
            points.append(GarminRoute.Point(lat: lat, lon: lon, name: values["callsign"] ?? values["name"],
                                            type: values["type"] ?? "b-m-p-c"))
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        defer { depth -= 1 }
        guard elementName == "event", depth == eventDepth, let attributes else { return }
        self.attributes = nil
        let type = attributes["type"] ?? ""
        if type == "t-x-d-d", let uid = removalUID ?? attributes["uid"], GarminRoute.validText(uid, maximum: 128) {
            events.append(.remove(uid))
        } else if type == "b-m-r" || type.hasPrefix("b-m-r-") {
            guard !invalidGeometry, let uid = attributes["uid"] else { fail(parser, .invalid); return }
            let route = GarminRoute(serverId: serverId, uid: uid, name: name ?? "Route",
                                    missionName: missionName, senderUid: senderUid, points: points, method: method)
            do {
                _ = try route.validated()
                events.append(.route(route))
            } catch let error as GarminRoute.Failure { fail(parser, error) }
            catch { fail(parser, .invalid) }
        }
        if events.count > 128 { fail(parser, .capacity) }
    }

    private func fail(_ parser: XMLParser, _ error: GarminRoute.Failure) {
        failure = error
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if failure == nil { failure = .malformedXML }
    }
}
