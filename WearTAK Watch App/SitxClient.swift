import Combine
import CoreLocation
import Foundation
import Security

struct SitxGroup: Decodable, Identifiable {
    let flowTag: String
    let name: String
    var id: String { flowTag }

    enum CodingKeys: String, CodingKey {
        case flowTag = "flow_tag"
        case name
    }
}

protocol SitxTokenStore {
    func read(account: String) -> String?
    func save(_ value: String, account: String) throws
    func delete(account: String)
}

@MainActor
final class SitxClient: ObservableObject, TAKTransport {
    private enum State {
        static let unconfigured = "Not connected"
        static let requestingCode = "Requesting device code"
        static let awaitingAuthorization = "Waiting for authorization"
        static let refreshing = "Refreshing token"
        static let checking = "Checking account"
        static let connected = "Connected"
        static let expired = "Code expired; retry"
    }

    private static let clientID = "D4RTE81TJjccxlc8LPD7QQ"
    private let settings: AppSettings
    private let session: URLSession
    private let tokenStore: any SitxTokenStore
    private let defaults: UserDefaults
    private var hostSubscription: AnyCancellable?
    private var accessToken: String?
    private var refreshToken: String?
    private var deviceCode: String?
    private var expiresAt: Date?
    private var pollInterval: TimeInterval = 5
    private var pairingTask: Task<Void, Never>?
    private var tokenHost: String?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var entityContinuation: AsyncStream<EntityRelayPayload>.Continuation?
    @Published private(set) var pendingEvents: [String: String] = [:]
    private var connectionGeneration = 0
    private var isAppActive = true
    var onReady: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var currentLocation: CLLocation?
    var additionalOutput: (any CoTOutput)?
    var companionOutput: (any CoTOutput)?
    var isSitxConnected: Bool {
        settings.sitxEnabled && !isPhoneReachable && socket != nil && status == State.connected
    }
    var hasReadyOutput: Bool {
        additionalOutput?.isReady == true || companionOutput?.isReady == true || isSitxConnected
    }
    var isPhoneReachable = false {
        didSet {
            guard isPhoneReachable != oldValue else { return }
            disconnect()
            if isPhoneReachable {
                status = "Phone relay reachable; Sit(x) paused"
            } else if settings.sitxEnabled, !selectedGroupID.isEmpty {
                onReady?()
            }
        }
    }
    var pliReportingRoute: PLIReportingRoute { .standaloneSitx }

    @Published private(set) var authorizationCode = ""
    @Published private(set) var verificationURL = ""
    @Published private(set) var status = State.unconfigured
    @Published private(set) var groups: [SitxGroup] = []
    @Published private(set) var selectedGroupID: String

    func selectGroup(_ group: SitxGroup) {
        if selectedGroupID != group.id { pendingEvents = [:] }
        disconnect()
        selectedGroupID = group.id
        defaults.set(group.id, forKey: "WearTAK.sitxGroup")
        if settings.sitxEnabled { onReady?() }
    }

    func resumeAuthorization() {
        guard settings.sitxEnabled, isAppActive, refreshToken != nil, !isPhoneReachable, socket == nil, pairingTask == nil else { return }
        pairingTask = Task {
            await beginPairing()
            pairingTask = nil
            if status.contains("failed") || status.contains("HTTP") {
                scheduleReconnect()
            }
        }
    }

    func setTAKEnabled(_ enabled: Bool) {
        settings.sitxEnabled = enabled
        if enabled {
            if refreshToken != nil { resumeAuthorization() }
            else { refreshAuthorizationCode() }
        } else {
            pairingTask?.cancel()
            pairingTask = nil
            disconnect()
            pendingEvents = [:]
            authorizationCode = ""
            verificationURL = ""
            status = "Off"
        }
    }

    func setAppActive(_ active: Bool) {
        isAppActive = active
        if !active {
            pairingTask?.cancel()
            pairingTask = nil
            disconnect()
            status = !settings.sitxEnabled ? "Off" : refreshToken == nil ? State.unconfigured : "Authorized; app inactive"
        }
    }

    func connect() async throws {
        guard settings.sitxEnabled, isAppActive, !isPhoneReachable, !selectedGroupID.isEmpty else {
            if hasReadyOutput { return }
            throw TAKTransportError.notConfigured
        }
        if socket != nil { return }
        let generation = connectionGeneration
        reconnectTask?.cancel()
        status = "Connecting TAK group"
        do {
            let request = try await groupConnectionRequest()
            guard isAppActive, !isPhoneReachable, generation == connectionGeneration else { throw CancellationError() }
            let task = session.webSocketTask(with: request)
            socket = task
            task.resume()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                task.sendPing { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            guard socket === task, !isPhoneReachable else { throw CancellationError() }
            status = State.connected
            receiveTask = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        guard let self, self.socket === task else { return }
                        let data: Data
                        switch message {
                        case .string(let text): data = Data(text.utf8)
                        case .data(let bytes): data = bytes
                        @unknown default: continue
                        }
                        for entity in SitxCoT.parse(data, excluding: Self.deviceID()) {
                            self.entityContinuation?.yield(entity)
                        }
                    }
                } catch {
                    guard let self, self.socket === task else { return }
                    self.connectionFailed(error)
                }
            }
            for (key, xml) in pendingEvents {
                try await sendEvent(xml, key: key)
            }
        } catch {
            if generation == connectionGeneration { connectionFailed(error) }
            if additionalOutput?.isReady == true { return }
            throw error
        }
    }

    private func disconnect() {
        connectionGeneration += 1
        reconnectTask?.cancel()
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        onDisconnected?()
    }

    private func connectionFailed(_ error: Error) {
        disconnect()
        status = Self.errorSummary(error, context: "TAK connection")
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard settings.sitxEnabled, isAppActive, !isPhoneReachable, refreshToken != nil else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self else { return }
            self.resumeAuthorization()
        }
    }

    private func sendXML(_ xml: String) async throws {
                guard settings.sitxEnabled, isAppActive, !isPhoneReachable,
                            tokenHost == Self.normalizedHost(settings.sitxApiHost), let socket else { throw TAKTransportError.notConfigured }
        do { try await socket.send(.string(xml)) }
        catch {
                        if self.socket === socket { connectionFailed(error) }
            throw error
        }
    }

    private func sendEvent(_ xml: String, key: String) async throws {
          guard settings.sitxEnabled, refreshToken != nil, tokenHost == Self.normalizedHost(settings.sitxApiHost),
              !selectedGroupID.isEmpty else { throw TAKTransportError.notConfigured }
        guard pendingEvents[key] != nil || pendingEvents.count < 200 else { throw SitxError.invalidResponse }
        pendingEvents[key] = xml
        try await sendXML(xml)
        if pendingEvents[key] == xml { pendingEvents.removeValue(forKey: key) }
    }

    private func deliver(_ xml: String, eventKey: String? = nil) async throws {
        var delivered = false
        var failure: Error = TAKTransportError.notConfigured
        if let companionOutput, companionOutput.isReady {
            do { try await companionOutput.send(xml); delivered = true }
            catch { failure = error }
        }
        if let additionalOutput, additionalOutput.isReady {
            do { try await additionalOutput.send(xml); delivered = true }
            catch { failure = error }
        }
        if settings.sitxEnabled && !isPhoneReachable {
            do {
                if let eventKey { try await sendEvent(xml, key: eventKey) }
                else { try await sendXML(xml) }
                delivered = true
            } catch { failure = error }
        }
        if !delivered { throw failure }
    }

    func sendPLI(coordinate: CLLocationCoordinate2D) async throws {
        let detail = "<contact callsign=\"\(SitxCoT.escape(settings.callSign))\" endpoint=\"*:-1:stcp\"/><__group name=\"\(SitxCoT.escape(settings.teamColor.rawValue))\" role=\"\(SitxCoT.escape(settings.role))\"/>"
        let lifetime = TimeInterval(max(settings.stationaryReportingInterval, settings.constantReportingInterval,
                                        settings.onFootReportingInterval, settings.vehicleReportingInterval)) * 6 + 120
        try await deliver(SitxCoT.event(uid: Self.deviceID(), type: "a-f-G-U-C", coordinate: coordinate,
                                      detail: detail, lifetime: lifetime))
    }

    func sendMarker(_ marker: WatchMarker) async throws {
        let affiliation: String
        switch marker.kind {
        case .friendly: affiliation = "f"
        case .hostile: affiliation = "h"
        case .neutral: affiliation = "n"
        case .unknown: affiliation = "u"
        }
        let detail = "<contact callsign=\"\(SitxCoT.escape(marker.displayTitle))\"/><remarks>\(SitxCoT.escape(marker.remark ?? ""))</remarks><link uid=\"\(Self.deviceID())\" type=\"a-f-G-U-C\" relation=\"p-p\"/>"
        try await deliver(SitxCoT.event(uid: marker.id.uuidString, type: "a-\(affiliation)-G", coordinate: marker.coordinate,
                          detail: detail, lifetime: 86_400), eventKey: marker.id.uuidString)
    }

    func deleteMarker(uid: String) async throws {
        let detail = "<link uid=\"\(SitxCoT.escape(uid))\" relation=\"p-p\"/><__forcedelete/>"
        try await deliver(SitxCoT.event(uid: uid + "-delete", type: "t-x-d-d", coordinate: currentLocation?.coordinate ?? CLLocationCoordinate2D(latitude: 0, longitude: 0),
                          detail: detail, lifetime: 300), eventKey: uid)
    }

    func sendEmergencyAlert(state: EmergencyState, type: String) async throws {
        let uid = Self.deviceID() + "-alert-" + type
        let cancel = state == .cancel
        let emergency = cancel ? "<emergency cancel=\"true\">\(SitxCoT.escape(settings.callSign))</emergency>"
            : "<emergency type=\"\(SitxCoT.escape(type))\">\(SitxCoT.escape(settings.callSign))</emergency>"
        let detail = "<contact callsign=\"\(SitxCoT.escape(settings.callSign))\"/><link uid=\"\(Self.deviceID())\" type=\"a-f-G-U-C\" relation=\"p-p\"/><remarks>\(SitxCoT.escape(type))</remarks><biometrics alertUid=\"\(SitxCoT.escape(uid))\" alertState=\"\(state.rawValue)\" alertDescription=\"\(SitxCoT.escape(type))\"/>" + emergency
        try await deliver(SitxCoT.event(uid: uid, type: cancel ? "b-a-o-can" : "b-a-o", coordinate: currentLocation?.coordinate ?? CLLocationCoordinate2D(latitude: 0, longitude: 0),
                          detail: detail, lifetime: 86_400), eventKey: uid)
    }

    func incomingEntities() -> AsyncStream<EntityRelayPayload> {
        entityContinuation?.finish()
        return AsyncStream(bufferingPolicy: .bufferingNewest(50)) { entityContinuation = $0 }
    }

    func groupConnectionRequest() async throws -> URLRequest {
        guard settings.sitxEnabled, let host = Self.normalizedHost(settings.sitxApiHost), tokenHost == host,
              let refreshToken else { throw SitxError.invalidResponse }
        var request = URLRequest(url: URL(string: host + "/api/v1/access/token")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(refreshToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "access"),
            URLQueryItem(name: "resource_type", value: "TAKSERVER"),
            URLQueryItem(name: "resource_key", value: selectedGroupID)
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let response = try await send(request)
        guard let endpoint = response["end_point"] as? String,
              let url = URL(string: endpoint), url.scheme == "wss",
              let token = response["access_token"] as? String else { throw SitxError.invalidResponse }
        if let rotated = response["refresh_token"] as? String {
            self.refreshToken = rotated
            try saveToken(rotated, account: "refresh")
        }
        var socketRequest = URLRequest(url: url)
        socketRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return socketRequest
    }

    var menuLabel: String {
        if status == State.connected || status == "Authorized; select Connect / Pair to verify" {
            return "Sit(x) Enabled"
        }
        let lowercasedStatus = status.lowercased()
        if lowercasedStatus.contains("error") || lowercasedStatus.contains("failed") ||
            lowercasedStatus.contains("http ") || lowercasedStatus.contains("expired") {
            return "Sit(x) Error"
        }
        return "Sit(x) Disabled"
    }

    init(settings: AppSettings, session: URLSession = .shared,
            defaults: UserDefaults = .standard, tokenStore: (any SitxTokenStore)? = nil) {
        self.settings = settings
        self.session = session
        self.defaults = defaults
        self.tokenStore = tokenStore ?? KeychainSitxTokenStore()
        selectedGroupID = defaults.string(forKey: "WearTAK.sitxGroup") ?? ""
        accessToken = self.tokenStore.read(account: "access")
        refreshToken = self.tokenStore.read(account: "refresh")
        tokenHost = self.tokenStore.read(account: "host")
        if accessToken != nil || refreshToken != nil {
            status = "Authorized; select Connect / Pair to verify"
        }
        hostSubscription = settings.$sitxApiHost.dropFirst().sink { [weak self] host in
            guard let self, self.tokenHost != nil,
                  self.tokenHost != Self.normalizedHost(host) else { return }
            self.forgetAuthorization()
        }
        if !settings.sitxEnabled { status = "Off" }
    }

    func refreshAuthorizationCode() {
        guard settings.sitxEnabled else { return }
        forgetAuthorization()
        pairingTask = Task {
            await beginPairing()
            pairingTask = nil
        }
    }

    func forgetAuthorization() {
        disconnect()
        pairingTask?.cancel()
        pairingTask = nil
        clearTokens()
        pendingEvents = [:]
        authorizationCode = ""
        verificationURL = ""
        groups = []
        selectedGroupID = ""
        defaults.removeObject(forKey: "WearTAK.sitxGroup")
        status = State.unconfigured
    }

    private func beginPairing() async {
        guard settings.sitxEnabled else { return }
        guard let host = Self.normalizedHost(settings.sitxApiHost) else {
            status = settings.sitxApiHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Enter Sit(x) API host"
                : "Enter a valid HTTPS host"
            return
        }
        settings.sitxApiHost = host
        if tokenHost != host {
            disconnect()
            groups = []
            selectedGroupID = ""
            pendingEvents = [:]
            defaults.removeObject(forKey: "WearTAK.sitxGroup")
            clearTokens()
        }
        if let refreshToken {
            await refreshAccessToken(refreshToken, host: host)
        } else {
            await requestDeviceCode(host: host)
        }
    }

    private func requestDeviceCode(host: String) async {
        status = State.requestingCode
        do {
            let deviceID = Self.deviceID()
            let scope = "role:org_user callsign:WEARTAK-\(deviceID.prefix(8)) device_name:\(settings.watchLabel) device_id:\(deviceID)"
            let response = try await postJSON(
                host: host,
                path: "/api/v1/device/authorization/code",
                body: ["scope": scope, "client_id": Self.clientID]
            )
            guard let code = response["device_code"] as? String,
                  let userCode = response["user_code"] as? String else {
                throw SitxError.invalidResponse
            }
            deviceCode = code
            authorizationCode = userCode
            verificationURL = response["verification_uri"] as? String
                ?? response["verification_url"] as? String
                ?? ""
            pollInterval = max(1, response["interval"] as? Double ?? 5)
            expiresAt = Date().addingTimeInterval(response["expires_in"] as? Double ?? 600)
            status = State.awaitingAuthorization
            await pollForAuthorization(host: host)
        } catch is CancellationError {
            return
        } catch {
            status = Self.errorSummary(error, context: "Sit(x) device authorization")
        }
    }

    private func pollForAuthorization(host: String) async {
        while !Task.isCancelled, let deviceCode, let expiresAt {
            guard Date() < expiresAt else {
                status = State.expired
                self.deviceCode = nil
                return
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                let response = try await postForm(
                    host: host,
                    path: "/api/v1/device/authorization/token",
                    fields: [
                        "client_id": Self.clientID,
                        "device_code": deviceCode,
                        "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
                    ]
                )
                guard let token = response["access_token"] as? String else {
                    throw SitxError.invalidResponse
                }
                accessToken = token
                refreshToken = response["refresh_token"] as? String
                try saveToken(token, account: "access")
                if let refreshToken { try saveToken(refreshToken, account: "refresh") }
                try saveToken(host, account: "host")
                tokenHost = host
                authorizationCode = ""
                verificationURL = ""
                self.deviceCode = nil
                await verifyAccount(host: host)
                return
            } catch is CancellationError {
                return
            } catch let error as SitxError where error == .authorizationPending {
                continue
            } catch let error as SitxError where error == .slowDown {
                pollInterval += 5
            } catch {
                status = Self.errorSummary(error, context: "Sit(x) token exchange")
                return
            }
        }
    }

    private func refreshAccessToken(_ refreshToken: String, host: String) async {
        status = State.refreshing
        do {
            var request = URLRequest(url: URL(string: host + "/api/v1/refresh/token")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(refreshToken)", forHTTPHeaderField: "Authorization")
            let response = try await send(request)
            self.refreshToken = response["refresh_token"] as? String ?? refreshToken
            if let newRefreshToken = self.refreshToken { try saveToken(newRefreshToken, account: "refresh") }
            try saveToken(host, account: "host")
            tokenHost = host
            await verifyAccount(host: host)
        } catch {
            if error as? SitxError == .httpStatus(401) || error as? SitxError == .httpStatus(403) {
                clearTokens()
                await requestDeviceCode(host: host)
            } else {
                status = Self.errorSummary(error, context: "Token refresh")
            }
        }
    }

    private func verifyAccount(host: String) async {
        status = State.checking
        do {
            var request = URLRequest(url: URL(string: host + "/api/v1/tak_servers")!)
            request.httpMethod = "GET"
            request.setValue("Bearer \(refreshToken ?? "")", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                status = "Authorized; profile check returned no HTTP response"
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                status = "Authorized; profile check HTTP \(http.statusCode)"
                return
            }
            groups = try JSONDecoder().decode([SitxGroup].self, from: data)
            if !groups.contains(where: { $0.id == selectedGroupID }) {
                selectedGroupID = ""
                defaults.removeObject(forKey: "WearTAK.sitxGroup")
            }
            status = groups.isEmpty ? "No permitted TAK groups" : "Authorized; select TAK group"
            if groups.count == 1, let group = groups.first { selectGroup(group) }
            else if !selectedGroupID.isEmpty { onReady?() }
        } catch {
            status = "Authorized; " + Self.errorSummary(error, context: "profile check")
        }
    }

    private static func errorSummary(_ error: Error, context: String) -> String {
        if let sitxError = error as? SitxError {
            return "\(context) failed: \(sitxError.localizedDescription)"
        }
        let nsError = error as NSError
        if let urlError = error as? URLError {
            return "\(context) network error \(urlError.code.rawValue)"
        }
        return "\(context) failed (\(nsError.domain) \(nsError.code))"
    }

    private func postJSON(host: String, path: String, body: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: host + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func postForm(host: String, path: String, fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: host + path)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SitxError.invalidResponse }
        if http.statusCode == 400 {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            switch body?["error"] as? String {
            case "authorization_pending": throw SitxError.authorizationPending
            case "slow_down": throw SitxError.slowDown
            case "expired_token": throw SitxError.authorizationExpired
            default: break
            }
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SitxError.httpStatus(http.statusCode)
        }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func clearTokens() {
        accessToken = nil
        refreshToken = nil
        tokenHost = nil
        for account in ["access", "refresh", "host"] { deleteToken(account: account) }
    }

    static func deviceID() -> String {
        let key = "WearTAK.sitxDeviceID"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    static func normalizedHost(_ value: String) -> String? {
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !input.isEmpty else { return nil }
        let urlText = input.contains("://") ? input : "https://" + input
        guard var components = URLComponents(string: urlText),
              components.scheme == "https" || components.scheme == "http",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              var hostname = components.host else { return nil }
        if hostname != "sitx.io", !hostname.hasSuffix(".sitx.io") {
            hostname += ".sitx.io"
        }
        let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
        guard hostname.count <= 253, labels.allSatisfy({ label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { byte in
                (97...122).contains(byte) || (48...57).contains(byte) || byte == 45
            }
        }) else { return nil }
        components.scheme = "https"
        components.host = hostname
        components.path = ""
        return components.string
    }

    private func saveToken(_ value: String, account: String) throws {
        try tokenStore.save(value, account: account)
    }

    private func deleteToken(account: String) {
        tokenStore.delete(account: account)
    }
}

struct KeychainSitxTokenStore: SitxTokenStore {
    private let service = "com.aegorsuch.weartak.sitx"

    func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ value: String, account: String) throws {
        delete(account: account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw SitxError.keychain(status) }
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private enum SitxError: Error, Equatable {
    case authorizationPending
    case slowDown
    case authorizationExpired
    case accountVerificationFailed
    case invalidResponse
    case httpStatus(Int)
    case keychain(OSStatus)

    var localizedDescription: String {
        switch self {
        case .authorizationPending: return "Waiting for authorization"
        case .slowDown: return "Authorization server requested slower polling"
        case .authorizationExpired: return "Code expired; retry"
        case .accountVerificationFailed: return "Account verification failed"
        case .invalidResponse: return "Invalid Sit(x) response"
        case .httpStatus(let code): return "Sit(x) HTTP \(code)"
        case .keychain(let status): return "Secure token storage failed (\(status))"
        }
    }
}
