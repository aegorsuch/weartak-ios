import Combine
import CoreLocation
import Foundation

enum PLIReportingRoute { case phoneRelay, standaloneSitx }
enum TAKTransportError: Error { case notConfigured }
enum EmergencyState: String, Codable { case alert = "ALERT", cancel = "CANCEL" }
enum MarkerKind: String {
    case friendly = "Friendly", hostile = "Hostile", neutral = "Neutral", unknown = "Unknown"
}

struct WatchMarker {
    let id: UUID
    let kind: MarkerKind
    let latitude: Double
    let longitude: Double
    let title: String?
    let remark: String?
    var displayTitle: String { title.flatMap { $0.isEmpty ? nil : $0 } ?? "\(kind.rawValue) 2525D point" }
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

@MainActor
protocol TAKTransport {
    var pliReportingRoute: PLIReportingRoute { get }
    func connect() async throws
    func sendPLI(coordinate: CLLocationCoordinate2D) async throws
    func sendMarker(_ marker: WatchMarker) async throws
    func deleteMarker(uid: String) async throws
    func sendEmergencyAlert(state: EmergencyState, type: String) async throws
    func incomingEntities() -> AsyncStream<EntityRelayPayload>
}

final class MemoryTokens: SitxTokenStore {
    var values = ["refresh": "fixture-refresh", "host": "https://fixture.sitx.io"]
    func read(account: String) -> String? { values[account] }
    func save(_ value: String, account: String) throws { values[account] = value }
    func delete(account: String) { values.removeValue(forKey: account) }
}

@MainActor
final class FixtureCoTOutput: CoTOutput {
    var isReady = true
    var failSend = false
    var messages: [String] = []

    func send(_ xml: String) async throws {
        if failSend { throw TAKTransportError.notConfigured }
        messages.append(xml)
    }
}

final class MockSitxHTTP: URLProtocol {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var failRefresh = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let failRefresh = Self.failRefresh
        Self.lock.unlock()
        let path = request.url!.path
        let body: String
        let status: Int
        switch path {
        case "/api/v1/refresh/token":
            body = failRefresh ? "{}" : "{\"refresh_token\":\"rotated-refresh\"}"
            status = failRefresh ? 500 : 200
        case "/api/v1/tak_servers":
            body = "[{\"id\":1,\"flow_tag\":\"group&A\",\"name\":\"Fixture Team\"}]"
            status = 200
        case "/api/v1/access/token":
            body = "{\"end_point\":\"wss://sitx.invalid/cot\",\"access_token\":\"fixture-access\",\"refresh_token\":\"group-refresh\"}"
            status = 200
        default:
            fatalError("Unexpected HTTP request: \(path)")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class XMLFields: NSObject, XMLParserDelegate {
    var attributes: [String: [[String: String]]] = [:]
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        self.attributes[elementName, default: []].append(attributes)
    }
}

@main
struct SitxProtocolChecks {
    @MainActor
    static func main() async throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            fatalError("Sit(x) protocol checks timed out")
        }
        let suite = "WearTAK.SitxChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        precondition(!settings.developerMode)
        for _ in 0..<6 { precondition(!settings.registerVersionTap()) }
        precondition(!settings.developerMode)
        settings.resetVersionTaps()
        for _ in 0..<6 { precondition(!settings.registerVersionTap()) }
        precondition(settings.registerVersionTap() && settings.developerMode)
        precondition(!settings.registerVersionTap())
        precondition(AppSettings(defaults: defaults).developerMode)
        settings.developerMode = false
        precondition(!AppSettings(defaults: defaults).developerMode)
        for _ in 0..<6 { precondition(!settings.registerVersionTap()) }
        precondition(settings.registerVersionTap())
        settings.developerMode = false
        print("PASS: developer mode hidden default, seven-tap threshold, reset, persistence and disabling")
        precondition(DashboardPhysiologySeverity.resolve(warningActive: false, alertActive: false) == .normal)
        precondition(DashboardPhysiologySeverity.resolve(warningActive: true, alertActive: false) == .warning)
        precondition(DashboardPhysiologySeverity.resolve(warningActive: false, alertActive: true) == .alert)
        precondition(DashboardPhysiologySeverity.resolve(warningActive: true, alertActive: true) == .alert)
        print("PASS: top physiological indicator warning/alert priority and reset")
        let userCoordinate = CLLocationCoordinate2D(latitude: 38, longitude: -77)
        let userXML = SitxCoT.event(uid: "incoming-user", type: "a-f-G-U-C", coordinate: userCoordinate,
            detail: "<contact callsign=\"ALPHA\"/><__group name=\" Red \" role=\"Team Lead\"/>", lifetime: 300)
        let incomingUser = SitxCoT.parse(Data(userXML.utf8), excluding: "self")
        precondition(incomingUser.count == 1 && incomingUser[0].callSign == "ALPHA")
        precondition(incomingUser[0].team == "Red" && incomingUser[0].role == "Team Lead")
        let pointXML = SitxCoT.event(uid: "incoming-point", type: "a-n-G", coordinate: userCoordinate, detail: "", lifetime: 300)
        precondition(SitxCoT.parse(Data(pointXML.utf8), excluding: "self").first?.team == nil)
        precondition(SitxCoT.isUser(type: "a-f-G-U-C") && SitxCoT.isUser(type: "a-h-G-U-C-I"))
        precondition(!SitxCoT.isUser(type: "a-n-G") && !SitxCoT.isUser(type: "b-a-o"))
        precondition(incomingUser[0].isUser == true)
        precondition(SitxCoT.parse(Data(pointXML.utf8), excluding: "self").first?.isUser == false)
        let k9XML = SitxCoT.event(uid: "incoming-k9", type: "a-f-G-E-V-C", coordinate: userCoordinate,
            detail: "<contact callsign=\"REX\"/><__group name=\"Dark Green\" role=\"K9\"/>", lifetime: 300)
        let k9 = SitxCoT.parse(Data(k9XML.utf8), excluding: "self")
        precondition(k9.count == 1 && k9[0].isUser == true && k9[0].team == "Dark Green" && k9[0].role == "K9")
        precondition(TeamColor(cotName: k9[0].team) == .darkGreen && SitxCoT.roleBadge(k9[0].role) == "K9")
        let endpointXML = SitxCoT.event(uid: "incoming-endpoint", type: "a-f-G", coordinate: userCoordinate,
            detail: "<contact callsign=\"BRAVO\" endpoint=\"*:-1:stcp\"/>", lifetime: 300)
        precondition(SitxCoT.parse(Data(endpointXML.utf8), excluding: "self").first?.isUser == true)
        let takvXML = SitxCoT.event(uid: "incoming-takv", type: "a-f-G", coordinate: userCoordinate,
            detail: "<takv platform=\"ATAK\"/>", lifetime: 300)
        precondition(SitxCoT.parse(Data(takvXML.utf8), excluding: "self").first?.isUser == true)
        let markerXML = SitxCoT.event(uid: "incoming-marker", type: "a-f-G-U-C-I", coordinate: userCoordinate,
            detail: "<contact callsign=\"F.1\"/>", lifetime: 300)
        precondition(SitxCoT.parse(Data(markerXML.utf8), excluding: "self").first?.isUser == true)
        let hostileXML = SitxCoT.event(uid: "incoming-hostile", type: "a-h-G", coordinate: userCoordinate,
            detail: "<contact callsign=\"H.1\"/>", lifetime: 300)
        precondition(SitxCoT.parse(Data(hostileXML.utf8), excluding: "self").first?.isUser == false)
        let portalMarkerXML = SitxCoT.event(uid: "incoming-portal-marker", type: "a-f-G", coordinate: userCoordinate,
            detail: "<contact callsign=\"F.10.870308\"/><link type=\"a-f-G-U-C-I\" uid=\"web.sitx.io.SA\" parent_callsign=\"ODIN-SITX\" relation=\"p-p\"/><takv device=\"Map Marker\"/>",
            lifetime: 300)
        let portalMarker = SitxCoT.parse(Data(portalMarkerXML.utf8), excluding: "self").first
        precondition(portalMarker?.isUser == false && portalMarker?.senderUID == "web.sitx.io.SA")
        let resentXML = "<event version=\"2.0\" uid=\"resent\" type=\"a-f-G\" time=\"2026-10-05T15:51:41.652Z\" start=\"2026-10-05T15:51:41.652Z\" stale=\"2099-10-05T15:51:41Z\" how=\"h-g-i-g-o\"><point lat=\"37.3\" lon=\"-122.0\" hae=\"0\" ce=\"1\" le=\"1\"/><detail/></event>"
        let resent = SitxCoT.parse(Data(resentXML.utf8), excluding: "self").first
        precondition(resent?.sentAt == ISO8601DateFormatter().date(from: "2026-10-05T15:51:41Z")!.addingTimeInterval(0.652)
            && resent?.isHumanEntered == true)
        let machineXML = resentXML.replacingOccurrences(of: "h-g-i-g-o", with: "m-g").replacingOccurrences(of: ".652Z\" start", with: "Z\" start")
        let machine = SitxCoT.parse(Data(machineXML.utf8), excluding: "self").first
        precondition(machine?.isHumanEntered == false && machine?.sentAt == ISO8601DateFormatter().date(from: "2026-10-05T15:51:41Z"))
        let linkedTAKVXML = SitxCoT.event(uid: "incoming-linked-takv", type: "a-f-G", coordinate: userCoordinate,
            detail: "<link uid=\"sender\" relation=\"p-p\"/><takv platform=\"WebTAK\"/>", lifetime: 300)
        precondition(SitxCoT.parse(Data(linkedTAKVXML.utf8), excluding: "self").first?.isUser == false)
        precondition(TeamColor(cotName: " dark_green ") == .darkGreen && TeamColor(cotName: "DarkBlue") == .darkBlue)
        precondition(TeamColor(cotName: "cyan") == .cyan && TeamColor(cotName: "Plaid") == nil && TeamColor(cotName: nil) == nil)
        precondition(SitxCoT.roleBadge("Team Lead") == "TL" && SitxCoT.roleBadge(" team member ") == "TM")
        precondition(SitxCoT.roleBadge("Forward Observer") == "FO" && SitxCoT.roleBadge("Medic") == "MED")
        precondition(SitxCoT.roleBadge("Pilot") == "PIL" && SitxCoT.roleBadge("Quick Reaction Force Alpha") == "QRF")
        precondition(SitxCoT.roleBadge("") == nil && SitxCoT.roleBadge(nil) == nil)
        print("PASS: incoming CoT callsign/team/role parsing and user classification")
        print("PASS: __group/takv/endpoint user classification, team color lookup and role badges")
        let teamGroups = MapUserGroup.make(values: ["Red", " red ", "Green", " "])
        precondition(teamGroups.count == 2 && teamGroups.first { $0.id == "red" }?.count == 2)
        precondition(MapUserGroup.make(values: []).isEmpty)
        precondition(settings.isMapUserVisible(team: "Red", role: "Team Lead"))
        settings.hiddenMapTeams.insert("red")
        precondition(!settings.isMapUserVisible(team: " RED ", role: "Team Lead"))
        precondition(settings.isMapUserVisible(team: "Green", role: "Team Lead"))
        settings.hiddenMapRoles.insert("team lead")
        precondition(!settings.isMapUserVisible(team: "Green", role: "Team Lead"))
        precondition(settings.isMapUserVisible(team: "Green", role: "Team Member"))
        precondition(settings.isMapUserVisible(team: nil, role: nil))
        let restoredFilters = AppSettings(defaults: defaults)
        precondition(restoredFilters.hiddenMapTeams == ["red"] && restoredFilters.hiddenMapRoles == ["team lead"])
        settings.hiddenMapTeams = []
        settings.hiddenMapRoles = []
        print("PASS: present-user grouping, independent team/role filters and persistence")
        let atakNow = ISO8601DateFormatter().date(from: "2026-10-04T01:48:41Z")!
        func atakPLI(type: String, extra: String = "") -> String {
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <event version="2.0" uid="ANDROID-0f1e2d3c4b5a6978" type="\(type)" how="m-g" time="2026-10-04T01:48:40.512Z" start="2026-10-04T01:48:40.512Z" stale="2026-10-04T01:55:10.512Z">
              <point lat="38.8895" lon="-77.0353" hae="12.4" ce="9.9" le="9999999.0"/>
              <detail>
                <takv os="34" version="5.2.0.4 (8ab1f2c3).1718123456-CIV" device="SAMSUNG SM-S918U" platform="ATAK-CIV"/>
                <contact endpoint="*:-1:stcp" callsign="ODIN-ATAK"/>
                <uid Droid="ODIN-ATAK"/>
                <precisionlocation altsrc="GPS" geopointsrc="GPS"/>
                <__group role="K9" name="Dark Green"/>
                <status battery="87"/>
                <track course="132.5" speed="0.0"/>
                \(extra)
                <_flow-tags_ TAK-Server-f1e2d3c4="2026-10-04T01:48:40Z"/>
              </detail>
            </event>
            """
        }
        for type in ["a-f-G-U-C-I", "a-f-G-U-C", "a-f-G-E-V-C", "a-f-G"] {
            let parsed = SitxCoT.parse(Data(atakPLI(type: type).utf8), excluding: "self", now: atakNow)
            precondition(parsed.count == 1 && parsed[0].isUser == true && parsed[0].callSign == "ODIN-ATAK")
            precondition(parsed[0].team == "Dark Green" && parsed[0].role == "K9")
            let users = parsed.filter { $0.isUser == true || SitxCoT.isUser(type: $0.type) }
            let teams = MapUserGroup.make(values: users.compactMap(\.team))
            let roles = MapUserGroup.make(values: users.compactMap(\.role))
            precondition(teams.count == 1 && teams[0].id == "dark green" && teams[0].name == "Dark Green" && teams[0].count == 1)
            precondition(roles.count == 1 && roles[0].id == "k9" && roles[0].name == "K9" && roles[0].count == 1)
            precondition(TeamColor(cotName: teams[0].name) == .darkGreen && SitxCoT.roleBadge(users[0].role) == "K9")
            precondition(settings.isMapUserVisible(team: users[0].team, role: users[0].role))
            settings.hiddenMapTeams.insert(teams[0].id)
            precondition(!settings.isMapUserVisible(team: users[0].team, role: users[0].role))
            settings.hiddenMapTeams = []
            settings.hiddenMapRoles.insert(roles[0].id)
            precondition(!settings.isMapUserVisible(team: users[0].team, role: users[0].role))
            settings.hiddenMapRoles = []
        }
        let droidOnly = """
            <event version="2.0" uid="ANDROID-droid-only" type="a-f-G" how="m-g" time="2026-10-04T01:48:40Z" start="2026-10-04T01:48:40Z" stale="2026-10-04T01:55:10Z"><point lat="38.8" lon="-77.0" hae="0" ce="9" le="9"/><detail><uid Droid="LOKI"/></detail></event>
            """
        let watchUID = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
        precondition(SitxCoT.parse(Data(droidOnly.utf8), excluding: "self", now: atakNow).first?.isUser == true)
        let sharedMapItem = """
            <event version="2.0" uid="point-1" type="a-h-G" how="m-g" time="2026-10-04T01:48:40Z" start="2026-10-04T01:48:40Z" stale="2026-10-04T01:55:10Z"><point lat="38.8" lon="-77.0" hae="0" ce="9" le="9"/><detail><contact callsign="OBJ-1"/><link uid="\(watchUID)" type="a-f-G-U-C" relation="p-p"/></detail></event>
            """
        let parsedMapItem = SitxCoT.parse(Data(sharedMapItem.utf8), excluding: "self", now: atakNow).first
        precondition(parsedMapItem?.callSign == "OBJ-1" && parsedMapItem?.senderUID == watchUID && parsedMapItem?.isUser == false)
        let bareUpdate = EntityRelayPayload(uid: "ANDROID-0f1e2d3c4b5a6978", lat: 38.9, lon: -77.0, type: "a-f-G", isUser: false)
            .inheritingMetadata(callSign: "ODIN-ATAK", team: "Dark Green", role: "K9", isUser: true)
        precondition(bareUpdate.isUser == true && bareUpdate.team == "Dark Green" && bareUpdate.role == "K9" && bareUpdate.callSign == "ODIN-ATAK")
        let teamChange = EntityRelayPayload(uid: "u", lat: 0, lon: 0, type: "a-f-G-U-C", team: "Cyan", role: "Medic", isUser: true)
            .inheritingMetadata(callSign: nil, team: "Dark Green", role: "K9", isUser: true)
        precondition(teamChange.team == "Cyan" && teamChange.role == "Medic")
        let neverUser = EntityRelayPayload(uid: "p", lat: 0, lon: 0, type: "a-h-G", isUser: false)
            .inheritingMetadata(callSign: nil, team: nil, role: nil, isUser: false)
        precondition(neverUser.isUser == false)
        print("PASS: raw ATAK PLI (Dark Green/K9) classifies as user with team/role counts, toggles and metadata carry-over")
        let ownDetail = SitxCoT.pliDetail(uid: watchUID, callSign: " THOR <&> ", team: "Dark Green", role: "K9",
                                          appVersion: "1.2", osVersion: "watchOS 11.0")
        let ownPLI = SitxCoT.event(uid: watchUID, type: SitxCoT.pliType, coordinate: userCoordinate, detail: ownDetail, lifetime: 300)
        let ownFields = XMLFields()
        let ownParser = XMLParser(data: Data(ownPLI.utf8))
        ownParser.delegate = ownFields
        precondition(ownParser.parse())
        precondition(ownFields.attributes["event"]?.first?["type"] == "a-f-G-U-C" && ownFields.attributes["event"]?.first?["uid"] == watchUID)
        precondition(ownFields.attributes["contact"]?.first?["callsign"] == "THOR <&>")
        precondition(ownFields.attributes["contact"]?.first?["endpoint"] == "*:-1:stcp")
        precondition(ownFields.attributes["__group"]?.first?["name"] == "Dark Green" && ownFields.attributes["__group"]?.first?["role"] == "K9")
        precondition(ownFields.attributes["takv"]?.first?["platform"] == "WearTAK" && ownFields.attributes["takv"]?.first?["device"] == "Apple Watch")
        precondition(ownFields.attributes["takv"]?.first?["version"] == "1.2" && ownFields.attributes["takv"]?.first?["os"] == "watchOS 11.0")
        precondition(ownFields.attributes["uid"]?.first?["Droid"] == "THOR <&>")
        let peerView = SitxCoT.parse(Data(ownPLI.utf8), excluding: "another-device")
        precondition(peerView.count == 1 && peerView[0].isUser == true && peerView[0].callSign == "THOR <&>")
        precondition(peerView[0].team == "Dark Green" && peerView[0].role == "K9")
        precondition(SitxCoT.parse(Data(ownPLI.utf8), excluding: watchUID).isEmpty)
        let blankDetail = SitxCoT.pliDetail(uid: watchUID, callSign: "  ", team: "White", role: " ",
                                            appVersion: "1.2", osVersion: "watchOS 11.0")
        let blankPLI = SitxCoT.parse(Data(SitxCoT.event(uid: watchUID, type: SitxCoT.pliType, coordinate: userCoordinate,
                                                        detail: blankDetail, lifetime: 300).utf8), excluding: "another-device")
        precondition(blankPLI.first?.callSign == "WEARTAK-0a1b2c3d" && blankPLI.first?.role == "Team Member")
        precondition(SitxCoT.pliCallSign("ODIN", uid: watchUID) == "ODIN")
        print("PASS: outgoing PLI carries ATAK contact endpoint, __group, takv and uid Droid; blank callsign/role fall back")
        let reportTime = ISO8601DateFormatter().date(from: "2026-10-04T01:48:40Z")!
        let fresh = MapContactAge(lastSeen: reportTime, now: reportTime.addingTimeInterval(45.9))
        precondition(fresh.seconds == 45 && !fresh.isStale && fresh.title("ODIN-ATAK") == "ODIN-ATAK ? 45s")
        precondition(fresh.accessibilityLabel(callSign: "ODIN-ATAK", team: "Dark Green", role: "K9")
                     == "ODIN-ATAK, Dark Green K9 user, last report 45 seconds ago")
        let boundary = MapContactAge(lastSeen: reportTime, now: reportTime.addingTimeInterval(60))
        precondition(!boundary.isStale && boundary.shortText == "1m")
        let stale = MapContactAge(lastSeen: reportTime, now: reportTime.addingTimeInterval(61))
        precondition(stale.isStale && stale.title("ODIN-ATAK") == "ODIN-ATAK ? 1m")
        precondition(stale.accessibilityLabel(callSign: "ODIN-ATAK", team: nil, role: " ")
                     == "ODIN-ATAK, user, last report 1 minute ago, stale")
        precondition(MapContactAge(lastSeen: reportTime, now: reportTime.addingTimeInterval(299)).shortText == "4m")
        precondition(MapContactAge(lastSeen: reportTime, now: reportTime.addingTimeInterval(7_200)).spokenText == "2 hours ago")
        let future = MapContactAge(lastSeen: reportTime.addingTimeInterval(20), now: reportTime)
        precondition(future.seconds == 0 && !future.isStale && future.spokenText == "0 seconds ago")
        precondition(MapContactAge(lastSeen: reportTime, now: reportTime.addingTimeInterval(1)).spokenText == "1 second ago")
        let ages = [fresh, boundary, stale, future].map { $0.title("X") + " " + $0.accessibilityLabel(callSign: "X", team: nil, role: nil) }
        precondition(!ages.contains { $0.lowercased().contains("live") })
        print("PASS: contact age labels, 60 s stale threshold, clock-skew clamp and accessibility text without 'live'")
        precondition(settings.mapButtonsVisible)
        settings.mapButtonsVisible = false
        precondition(!AppSettings(defaults: defaults).mapButtonsVisible)
        settings.mapButtonsVisible = true
        precondition(AppSettings(defaults: defaults).mapButtonsVisible)
        print("PASS: map-buttons default and visibility persistence")
        precondition(settings.dashboardMetric == .exertion)
        settings.dashboardMetric = .heartRate
        precondition(AppSettings(defaults: defaults).dashboardMetric == .heartRate)
        settings.dashboardMetric = .mgrs
        precondition(AppSettings(defaults: defaults).dashboardMetric == .mgrs && DashboardMetric.mgrs.isCoordinate)
        settings.dashboardMetric = .latLon
        precondition(AppSettings(defaults: defaults).dashboardMetric == .latLon && !DashboardMetric.heartRate.isCoordinate)
        settings.dashboardMetric = .exertion
        precondition(DashboardNetworkConnectivity.resolve(satisfied: true, wifi: true, cellular: false) == .wifi)
        precondition(DashboardNetworkConnectivity.resolve(satisfied: true, wifi: false, cellular: true) == .cellular)
        precondition(DashboardNetworkConnectivity.resolve(satisfied: false, wifi: true, cellular: true) == .offline)
        precondition(DashboardNetworkConnectivity.resolve(satisfied: true, wifi: false, cellular: false) == .other)
        precondition(DashboardNetworkConnectivity.resolve(satisfied: true, wifi: true, cellular: false,
            phoneReachable: true) == .phone)
        precondition(DashboardNetworkConnectivity.resolve(satisfied: false, wifi: false, cellular: false,
            phoneReachable: true) == .phone)
        let pendingRelay = DashboardTAKStatus.resolve(multicastReady: false, sitxConnected: false,
            phoneRelayConnected: false, multicastEnabled: false, sitxEnabled: false, relaySelected: true)
        precondition(!pendingRelay.isConnected && pendingRelay.displayed == [.phoneRelay])
        precondition(pendingRelay.label == "TAK BLE relay incomplete")
        let bothOutputs = DashboardTAKStatus.resolve(multicastReady: true, sitxConnected: true,
            phoneRelayConnected: false, multicastEnabled: true, sitxEnabled: true, relaySelected: true)
        precondition(bothOutputs.isConnected && bothOutputs.displayed == [.multicast, .sitx])
        let bleRelay = DashboardTAKStatus.resolve(multicastReady: false, sitxConnected: false,
            phoneRelayConnected: true, multicastEnabled: false, sitxEnabled: false, relaySelected: true)
        precondition(bleRelay.isConnected && bleRelay.active == [.phoneRelay])
        for multicastReady in [false, true] {
            for serverReady in [false, true] {
                for serverConfigured in [false, true] {
                    let state = DashboardTAKStatus.resolve(multicastReady: multicastReady,
                        sitxConnected: false, phoneRelayConnected: serverReady,
                        multicastEnabled: true, sitxEnabled: false, relaySelected: serverConfigured)
                    precondition(state.usesServerIcon == (serverReady || serverConfigured))
                    precondition(state.isServerConnected == serverReady)
                }
            }
        }
        precondition(pendingRelay.indicatorLabel == "TAK server not connected")
        precondition(bothOutputs.usesServerIcon && bothOutputs.isServerConnected)
        precondition(bleRelay.indicatorLabel == "TAK server connected")
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        precondition(CompanionLinkState.resolve(ready: true, pauseReason: "x", lastHealthy: nil,
            checkingSince: t0, now: t0) == .connected)
        precondition(CompanionLinkState.resolve(ready: false, pauseReason: nil, lastHealthy: t0,
            checkingSince: nil, now: t0.addingTimeInterval(44)) == .reconnecting)
        precondition(CompanionLinkState.resolve(ready: false, pauseReason: nil, lastHealthy: t0,
            checkingSince: nil, now: t0.addingTimeInterval(45)) == .disconnected)
        precondition(CompanionLinkState.resolve(ready: false, pauseReason: nil, lastHealthy: nil,
            checkingSince: t0, now: t0.addingTimeInterval(9)) == .checking)
        precondition(CompanionLinkState.resolve(ready: false, pauseReason: nil, lastHealthy: nil,
            checkingSince: t0, now: t0.addingTimeInterval(10)) == .disconnected)
        let paused = CompanionLinkState.resolve(ready: false, pauseReason: "Location permission denied",
            lastHealthy: t0, checkingSince: nil, now: t0)
        precondition(paused == .paused("Location permission denied"))
        precondition(paused.label == "Phone paused – open Companion (Location permission denied)")
        precondition(DashboardServerBadge.resolve(status: bleRelay, phoneLink: .disconnected) == .connected)
        precondition(DashboardServerBadge.resolve(status: pendingRelay, phoneLink: .reconnecting) == .pending)
        precondition(DashboardServerBadge.resolve(status: pendingRelay, phoneLink: .checking) == .pending)
        precondition(DashboardServerBadge.resolve(status: pendingRelay, phoneLink: paused) == .paused)
        precondition(DashboardServerBadge.resolve(status: pendingRelay, phoneLink: nil) == .disconnected)
        let pausedWire = try! BridgeWire.Message.decode(BridgeWire.Message(kind: .status, ready: false,
            relayPaused: "Off").encoded())
        precondition(pausedWire.relayPaused == "Off")
        precondition((try? BridgeWire.Message.decode(BridgeWire.Message(kind: .status,
            relayPaused: String(repeating: "x", count: 513)).encoded())) == nil)
        print("PASS: phone link grace, checking and paused states")
        precondition(DashboardLocationStatus.resolve(watchEnabled: false, phoneEnabled: false) == .disabled)
        precondition(DashboardLocationStatus.resolve(watchEnabled: true, phoneEnabled: false) == .watch)
        precondition(DashboardLocationStatus.resolve(watchEnabled: false, phoneEnabled: true) == .phone)
        precondition(DashboardLocationStatus.resolve(watchEnabled: true, phoneEnabled: true) == .phone)
        print("PASS: dashboard metric persistence and network/TAK indicator states")
        precondition(settings.multicastEnabled)
        precondition(settings.multicastAddress == "239.2.3.1" && settings.multicastPort == 6969)
        precondition(settings.multicastOutputProtocol == .udp)
        precondition(AppSettings.isMulticastAddress("239.2.3.1"))
        precondition(AppSettings.isMulticastAddress("224.0.0.1"))
        precondition(!AppSettings.isMulticastAddress("223.255.255.255"))
        precondition(!AppSettings.isMulticastAddress("240.0.0.1"))
        precondition(!AppSettings.isMulticastAddress("239.2.3.999"))
        precondition(!AppSettings.isMulticastAddress("localhost"))
        settings.multicastAddress = "239.2.3.2"
        settings.multicastPort = 7000
        settings.multicastEnabled = true
        let restored = AppSettings(defaults: defaults)
        precondition(restored.multicastEnabled && restored.multicastAddress == "239.2.3.2" && restored.multicastPort == 7000)
        settings.multicastPort = 0
        precondition(settings.multicastPort == 1)
        settings.multicastPort = 70_000
        precondition(settings.multicastPort == 65535)
        settings.multicastEnabled = false
        precondition(!AppSettings(defaults: defaults).multicastEnabled)
        let multicast = MulticastTAKTransport(settings: settings)
        multicast.setAppActive(true)
        precondition(!multicast.isReady && multicast.status == "Disabled")
        do {
            try await multicast.send("<event/>")
            fatalError("Disabled multicast must not send")
        } catch {}
        print("PASS: multicast defaults, persistence, address/port validation and disabled-send guard")
        settings.sitxApiHost = "https://fixture.sitx.io"
        settings.sitxEnabled = true
        settings.callSign = "ODIN <& \"TEAM\">"
        precondition(SitxClient.normalizedHost(" Team ") == "https://team.sitx.io")
        precondition(SitxClient.normalizedHost("team.sitx.io") == "https://team.sitx.io")
        precondition(SitxClient.normalizedHost("https://team.sitx.io/") == "https://team.sitx.io")
        precondition(SitxClient.normalizedHost("http://team.sitx.io") == "https://team.sitx.io")
        precondition(SitxClient.normalizedHost("") == nil)
        precondition(SitxClient.normalizedHost("bad name") == nil)
        precondition(SitxClient.normalizedHost("https://team.sitx.io/path") == nil)
        precondition(SitxClient.normalizedHost("https://user:password@team.sitx.io") == nil)
        print("PASS: organization suffix normalization and invalid-address rejection")
        precondition(SitxClient.serverMessage(from: Data(#"{"error":"device already registered"}"#.utf8)) == "device already registered")
        precondition(SitxClient.serverMessage(from: Data(#"{"errors":["x"],"message":"Not acceptable"}"#.utf8)) == "Not acceptable")
        precondition(SitxClient.serverMessage(from: Data("<html>406</html>".utf8)) == nil)
        precondition(SitxClient.serverMessage(from: Data()) == nil)
        precondition(SitxClient.serverMessage(from: Data(#"{"error":"access_denied","error_description":""}"#.utf8)) == "authorization was denied")
        precondition(SitxClient.serverMessage(from: Data(#"{"error":"invalid_grant"}"#.utf8))?.contains("Re-auth") == true)
        precondition(SitxAPI.sequesteredReason("not_sequestered") == nil && SitxAPI.sequesteredReason(nil) == nil)
        precondition(SitxAPI.sequesteredReason(NSNull()) == nil)
        precondition(SitxAPI.sequesteredReason("admin_approval_required_sequestered")?.contains("administrator approval") == true)
        precondition(SitxAPI.sequesteredReason("over_plan_user_devices_sequestered")?.contains("device limit") == true)
        precondition(SitxAPI.sequesteredReason("new_reason")?.contains("new_reason") == true)
        let storedNow = ISO8601DateFormatter().date(from: "2026-10-05T12:00:00Z")!
        let stored = Data("""
        [{"resource_uid":"b-2","tak_group_tag":"grp","issued_at":"2026-10-05T11:59:00.000-05:00","stale_at":null,"ack_at":null,
          "payload":"<?xml version=\\"1.0\\" encoding=\\"UTF-8\\"?><event uid=\\"two\\"/>"},
         {"resource_uid":"a-1","tak_group_tag":"grp","issued_at":"2026-10-05T11:00:00Z","stale_at":"2026-10-06T00:00:00Z","ack_at":null,
          "payload":"<event uid=\\"one\\"/>"},
         {"resource_uid":"acked","tak_group_tag":"grp","issued_at":"2026-10-05T11:00:00Z","ack_at":"2026-10-05T11:01:00Z","payload":"<event/>"},
         {"resource_uid":"stale","tak_group_tag":"grp","issued_at":"2026-10-05T11:00:00Z","stale_at":"2026-10-05T11:30:00Z","ack_at":null,"payload":"<event/>"},
         {"resource_uid":"other","tak_group_tag":"other","issued_at":"2026-10-05T11:00:00Z","ack_at":null,"payload":"<event/>"},
         {"resource_uid":"../x","tak_group_tag":"grp","ack_at":null,"payload":"<event/>"},
         {"resource_uid":"html","tak_group_tag":"grp","ack_at":null,"payload":"<html/>"}]
        """.utf8)
        let storedMessages = SitxStoredMessage.parse(stored, flowTag: "grp", now: storedNow)
        precondition(storedMessages.map(\.id) == ["a-1", "b-2"], "\(storedMessages)")
        precondition(storedMessages[1].payload == "<event uid=\"two\"/>", storedMessages[1].payload)
        precondition(SitxStoredMessage.parse(Data("{}".utf8), flowTag: "grp").isEmpty)
        precondition(SitxStoredMessage.listURL(host: "https://team.sitx.io", flowTag: "tak-group-1")?.absoluteString
                     == "https://team.sitx.io/api/v1/messages?tak_group_tag=tak-group-1")
        print("PASS: sequestered status reasons, OAuth error text and Store and Forward message filtering")
        precondition(!SitxClient.isWatchOSStreamBlocked(URLError(.notConnectedToInternet)))
        print("PASS: Sit(x) HTTP error body reasons and watchOS stream-block detection")
        let relay = SitxRelayConfig(enabled: true, host: "https://team.sitx.io", flowTag: "flow-1",
                                    groupName: "Alpha", refreshToken: "rt")
        let relayMessage = try BridgeWire.Message.decode(
            BridgeWire.Message(kind: .sitxConfig, sitxConfig: relay).encoded())
        precondition(relayMessage.sitxConfig == relay)
        precondition(SitxRelayConfig(enabled: false, host: "", flowTag: "").isValid)
        for invalid in [
            SitxRelayConfig(enabled: true, host: "https://evil.example", flowTag: "flow-1"),
            SitxRelayConfig(enabled: true, host: "http://team.sitx.io", flowTag: "flow-1"),
            SitxRelayConfig(enabled: true, host: "https://team.sitx.io", flowTag: ""),
            SitxRelayConfig(enabled: true, host: "https://team.sitx.io", flowTag: "f", refreshToken: "")
        ] {
            let data = try BridgeWire.Message(kind: .sitxConfig, sitxConfig: invalid).encoded()
            precondition((try? BridgeWire.Message.decode(data)) == nil)
        }
        precondition((try? BridgeWire.Message.decode(try BridgeWire.Message(kind: .sitxConfig).encoded())) == nil)
        print("PASS: Sit(x) Companion relay config wire validation")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockSitxHTTP.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let tokens = MemoryTokens()
        let syncSuite = suite + ".settings-sync"
        let syncDefaults = UserDefaults(suiteName: syncSuite)!
        defer { syncDefaults.removePersistentDomain(forName: syncSuite) }
        let syncSettings = AppSettings(defaults: syncDefaults)
        let emptyTokens = MemoryTokens()
        emptyTokens.values = [:]
        let mirror = SitxClient(settings: syncSettings, session: session, defaults: syncDefaults, tokenStore: emptyTokens)
        let phoneSettings = SitxSettingsSnapshot(enabled: true, host: "https://fixture.sitx.io",
            groupName: "Fixture Team", status: "Connected")
        mirror.applyPhoneSettings(phoneSettings)
        precondition(mirror.phoneManagedSettings == phoneSettings && mirror.menuLabel == "Sit(x) Needs iPhone")
        precondition(emptyTokens.values.isEmpty)
        let restoredMirror = SitxClient(settings: syncSettings, session: session, defaults: syncDefaults, tokenStore: emptyTokens)
        precondition(restoredMirror.phoneManagedSettings == phoneSettings && restoredMirror.menuLabel == "Sit(x) Needs iPhone")
        restoredMirror.setAppActive(false)
        restoredMirror.setAppActive(true)
        precondition(restoredMirror.menuLabel == "Sit(x) Needs iPhone")
        restoredMirror.applyPhoneSettings(nil)
        precondition(restoredMirror.phoneManagedSettings == phoneSettings)
        restoredMirror.canReachPhone = true
        precondition(restoredMirror.menuLabel == "Sit(x) via iPhone")
        let updatedPhone = SitxSettingsSnapshot(enabled: false, host: phoneSettings.host,
            groupName: "Other Group", status: "Off")
        restoredMirror.applyPhoneSettings(updatedPhone)
        precondition(restoredMirror.phoneManagedSettings == updatedPhone)
        restoredMirror.applyPhoneSettings(SitxSettingsSnapshot(enabled: false, host: "", status: "Not connected"))
        precondition(restoredMirror.phoneManagedSettings == nil)
        let removedMirror = SitxClient(settings: syncSettings, session: session, defaults: syncDefaults, tokenStore: emptyTokens)
        precondition(removedMirror.phoneManagedSettings == nil && emptyTokens.values.isEmpty)
        print("PASS: phone Sit(x) settings mirror, restart persistence, offline Needs iPhone, resync and removal without credentials")
        let client = SitxClient(settings: settings, session: session, defaults: defaults, tokenStore: tokens)

        await withCheckedContinuation { continuation in
            client.onReady = { continuation.resume() }
            client.resumeAuthorization()
        }
        client.onReady = nil
        precondition(client.groups.count == 1 && client.selectedGroupID == "group&A")
        precondition(tokens.values["refresh"] == "rotated-refresh")
        precondition(defaults.string(forKey: "WearTAK.sitxGroup") == "group&A")
        precondition(client.status != "Connected")
        let socketRequest = try await client.groupConnectionRequest()
        precondition(socketRequest.url?.absoluteString == "wss://sitx.invalid/cot")
        precondition(socketRequest.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access")
        precondition(tokens.values["refresh"] == "group-refresh")
        let requests = MockSitxHTTP.lock.withLock { MockSitxHTTP.requests }
        precondition(requests[0].httpMethod == "POST")
        precondition(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer fixture-refresh")
        precondition(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer rotated-refresh")
        let formRequest = requests[2]
        let formData: Data
        if let body = formRequest.httpBody {
            formData = body
        } else if let stream = formRequest.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            let count = stream.read(&bytes, maxLength: bytes.count)
            formData = Data(bytes.prefix(max(count, 0)))
        } else { fatalError("Missing access-token form") }
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: formData, as: UTF8.self)
        precondition(components.queryItems?.contains(URLQueryItem(name: "resource_key", value: "group&A")) == true)
        print("PASS: group discovery, refresh rotation, access-token form and WebSocket authentication")

        client.currentLocation = CLLocation(latitude: 38, longitude: -77)
        try? await client.sendEmergencyAlert(state: .alert, type: "Injury & <help>")
        precondition(client.pendingEvents.count == 1)
        let alertXML = client.pendingEvents.values.first!
        let alert = try fields(alertXML)
        precondition(alert.attributes["event"]?.first?["type"] == "b-a-o")
        precondition(alert.attributes["contact"]?.first?["callsign"] == settings.callSign)
        let alertUID = alert.attributes["event"]!.first!["uid"]!
        try? await client.sendEmergencyAlert(state: .cancel, type: "Injury & <help>")
        precondition(client.pendingEvents.count == 1)
        let cancellation = try fields(client.pendingEvents.values.first!)
        precondition(cancellation.attributes["event"]?.first?["uid"] == alertUID)
        precondition(cancellation.attributes["event"]?.first?["type"] == "b-a-o-can")
        precondition(cancellation.attributes["emergency"]?.first?["cancel"] == "true")
        print("PASS: escaped alert payload and cancellation superseding queued activation")

        let marker = WatchMarker(id: UUID(), kind: .neutral, latitude: 38.1, longitude: -77.1,
                                 title: "Point <&>", remark: "Watch's \"remark\"")
        let callsignBeforeDrop = settings.callSign
        try? await client.sendMarker(marker)
        let sentMarkerXML = client.pendingEvents[marker.id.uuidString]!
        let markerFields = try fields(sentMarkerXML)
        precondition(settings.callSign == callsignBeforeDrop)
        precondition(markerFields.attributes["event"]?.first?["uid"] != SitxClient.deviceID())
        precondition(markerFields.attributes["contact"]?.first?["callsign"] == marker.displayTitle)
        precondition(markerFields.attributes["link"]?.first?["uid"] == SitxClient.deviceID())
        let parsed = SitxCoT.parse(Data(sentMarkerXML.utf8), excluding: "self")
        precondition(parsed.count == 1 && parsed[0].uid == marker.id.uuidString && parsed[0].type == "a-n-G")
        precondition(SitxCoT.parse(Data(sentMarkerXML.utf8), excluding: marker.id.uuidString).isEmpty)
        try? await client.deleteMarker(uid: marker.id.uuidString)
        let deletion = try fields(client.pendingEvents[marker.id.uuidString]!)
        precondition(deletion.attributes["event"]?.first?["type"] == "t-x-d-d")
        precondition(deletion.attributes["link"]?.first?["uid"] == marker.id.uuidString)
        precondition(deletion.attributes["__forcedelete"] != nil)
        let defaultMarkerTitles: [String?] = [nil, ""]
        for title in defaultMarkerTitles {
            let defaultMarker = WatchMarker(id: UUID(), kind: .friendly, latitude: 38.1, longitude: -77.1,
                                            title: title, remark: nil)
            try? await client.sendMarker(defaultMarker)
            let defaultFields = try fields(client.pendingEvents[defaultMarker.id.uuidString]!)
            precondition(defaultFields.attributes["contact"]?.first?["callsign"] == "Friendly 2525D point")
        }
        let expired = SitxCoT.event(uid: "expired", type: "a-f-G-U-C", coordinate: marker.coordinate,
                                    detail: "", lifetime: 0, now: Date(timeIntervalSince1970: 0))
        precondition(SitxCoT.parse(Data(expired.utf8), excluding: "self").isEmpty)
        precondition(SitxCoT.parse(Data("<event>broken".utf8), excluding: "self").isEmpty)
        client.selectGroup(SitxGroup(flowTag: "another", name: "Other Team"))
        precondition(client.pendingEvents.isEmpty)
        print("PASS: marker encoding, deletion, incoming CoT, self/expired rejection and group isolation")

        client.setTAKEnabled(false)
        precondition(!settings.sitxEnabled && client.status == "Off")
        precondition(tokens.values["refresh"] == "group-refresh")
        precondition(AppSettings(defaults: defaults).sitxEnabled == false)
        try? await client.sendEmergencyAlert(state: .alert, type: "Off test")
        precondition(client.pendingEvents.isEmpty)
        do {
            _ = try await client.groupConnectionRequest()
            fatalError("Off must block data-session provisioning")
        } catch {}
        settings.sitxEnabled = true
        print("PASS: persisted TAK toggle blocks delivery without removing credentials")

        client.setTAKEnabled(false)
        let output = FixtureCoTOutput()
        client.additionalOutput = output
        try await client.connect()
        precondition(client.hasReadyOutput)
        client.biometrics = WatchBiometrics(heartRate: 88, exertion: 47, measuredAt: Date())
        try await client.sendPLI(coordinate: marker.coordinate)
        try await client.sendEmergencyAlert(state: .alert, type: "Multicast alert")
        try await client.sendEmergencyAlert(state: .cancel, type: "Multicast alert")
        try await client.sendMarker(marker)
        try await client.deleteMarker(uid: marker.id.uuidString)
        precondition(output.messages.count == 5 && client.pendingEvents.isEmpty)
        let pli = try fields(output.messages[0])
        precondition(pli.attributes["event"]?.first?["type"] == "a-f-G-U-C")
        precondition(pli.attributes["event"]?.first?["uid"] == SitxClient.deviceID())
        precondition(pli.attributes["contact"]?.first?["callsign"] == settings.callSign)
        precondition(pli.attributes["contact"]?.first?["endpoint"] == "*:-1:stcp")
        precondition(pli.attributes["__group"]?.first?["name"] == settings.teamColor.rawValue)
        precondition(pli.attributes["__group"]?.first?["role"]?.isEmpty == false)
        precondition(pli.attributes["takv"]?.first?["platform"] == "WearTAK")
        precondition(pli.attributes["uid"]?.first?["Droid"] == settings.callSign)
        precondition(output.messages[0].contains("<remarks>Exert:47%;HR:88</remarks>"), output.messages[0])
        precondition(output.messages[0].contains("<biometrics><device><model>WATCHOS</model><uid>\(SitxClient.deviceID())</uid><hr>88</hr><exert>47</exert></device></biometrics>"))
        precondition(output.messages[1].contains("alertPriority=\"1\"") && output.messages[1].contains("alertCategory=\"Multicast alert\""))
        precondition(output.messages[1].contains("<hr>88</hr>") && output.messages[1].contains("<exert>47</exert>"))
        let multicastAlert = try fields(output.messages[1])
        let multicastCancel = try fields(output.messages[2])
        precondition(multicastAlert.attributes["event"]?.first?["uid"] == multicastCancel.attributes["event"]?.first?["uid"])
        precondition(multicastCancel.attributes["emergency"]?.first?["cancel"] == "true")
        output.failSend = true
        do {
            try await client.sendPLI(coordinate: marker.coordinate)
            fatalError("All failed outputs must report a failure")
        } catch {}
        output.failSend = false
        settings.sitxEnabled = true
        try await client.sendEmergencyAlert(state: .alert, type: "Dual output alert")
        precondition(client.pendingEvents.count == 1 && output.messages.count == 6)
        precondition(output.messages.last == client.pendingEvents.values.first)
        client.additionalOutput = nil
        client.setTAKEnabled(false)
        settings.sitxEnabled = true
        print("PASS: multicast-only PLI/alerts/points and successful output despite offline Sit(x)")
        let phoneOutput = FixtureCoTOutput()
        client.companionOutput = phoneOutput
        client.isPhoneReachable = true
        settings.sitxEnabled = false
        try await client.connect()
        try await client.sendPLI(coordinate: marker.coordinate)
        try await client.sendEmergencyAlert(state: .alert, type: "Companion test")
        precondition(phoneOutput.messages.count == 2 && client.hasReadyOutput)
        let relayedPLI = try fields(phoneOutput.messages[0])
        precondition(relayedPLI.attributes["event"]?.first?["uid"] == SitxClient.deviceID())
        precondition(relayedPLI.attributes["event"]?.first?["type"] == "a-f-G-U-C")
        precondition(relayedPLI.attributes["contact"]?.first?["endpoint"] == "*:-1:stcp")
        precondition(relayedPLI.attributes["__group"] != nil && relayedPLI.attributes["takv"] != nil)
        phoneOutput.isReady = false
        precondition(!client.hasReadyOutput)
        client.companionOutput = nil
        client.isPhoneReachable = false
        settings.sitxEnabled = true
        print("PASS: Companion-only readiness and PLI/alert delivery without Sit(x) or multicast")

        MockSitxHTTP.lock.withLock { MockSitxHTTP.failRefresh = true }
        let failureClient = SitxClient(settings: settings, session: session, defaults: defaults, tokenStore: tokens)
        var statuses = failureClient.$status.values.makeAsyncIterator()
        failureClient.resumeAuthorization()
        while let status = await statuses.next() {
            if status.contains("500") { break }
        }
        precondition(tokens.values["refresh"] == "group-refresh")
        settings.sitxApiHost = "https://different.invalid"
        precondition(tokens.values.isEmpty && client.pendingEvents.isEmpty)
        client.forgetAuthorization()
        failureClient.setAppActive(false)
        precondition(tokens.values.isEmpty && client.groups.isEmpty && client.selectedGroupID.isEmpty)
        print("PASS: transient refresh failure retains credentials; host change/Clear Sit(x) remove authorization")
        print("All Sit(x) protocol checks passed")
    }

    static func fields(_ xml: String) throws -> XMLFields {
        let fields = XMLFields()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = fields
        guard parser.parse() else { throw parser.parserError! }
        return fields
    }
}