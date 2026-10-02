import Combine
import CoreLocation
import Foundation

enum PLIReportingRoute { case phoneRelay, standaloneSitx }
enum TAKTransportError: Error { case notConfigured }
enum EmergencyState: String, Codable { case alert = "ALERT", cancel = "CANCEL" }
enum MarkerKind { case friendly, hostile, neutral, unknown }

struct WatchMarker {
    let id: UUID
    let kind: MarkerKind
    let latitude: Double
    let longitude: Double
    let title: String
    let remark: String?
    var displayTitle: String { title }
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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockSitxHTTP.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let tokens = MemoryTokens()
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
        try? await client.sendMarker(marker)
        let markerXML = client.pendingEvents[marker.id.uuidString]!
        let parsed = SitxCoT.parse(Data(markerXML.utf8), excluding: "self")
        precondition(parsed.count == 1 && parsed[0].uid == marker.id.uuidString && parsed[0].type == "a-n-G")
        precondition(SitxCoT.parse(Data(markerXML.utf8), excluding: marker.id.uuidString).isEmpty)
        try? await client.deleteMarker(uid: marker.id.uuidString)
        let deletion = try fields(client.pendingEvents[marker.id.uuidString]!)
        precondition(deletion.attributes["event"]?.first?["type"] == "t-x-d-d")
        precondition(deletion.attributes["link"]?.first?["uid"] == marker.id.uuidString)
        precondition(deletion.attributes["__forcedelete"] != nil)
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
        try await client.sendPLI(coordinate: marker.coordinate)
        try await client.sendEmergencyAlert(state: .alert, type: "Multicast alert")
        try await client.sendEmergencyAlert(state: .cancel, type: "Multicast alert")
        try await client.sendMarker(marker)
        try await client.deleteMarker(uid: marker.id.uuidString)
        precondition(output.messages.count == 5 && client.pendingEvents.isEmpty)
        let pli = try fields(output.messages[0])
        precondition(pli.attributes["event"]?.first?["type"] == "a-f-G-U-C")
        precondition(pli.attributes["contact"]?.first?["callsign"] == settings.callSign)
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