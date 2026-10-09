import Combine
import CoreLocation
import Foundation
import Security

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

    private static let clientID = SitxAPI.clientID
    private let settings: AppSettings
    private let session: URLSession
    private let tokenStore: any SitxTokenStore
    private let defaults: UserDefaults
    private var hostSubscription: AnyCancellable?
    private var accessToken: String?
    /// The watch's own Sit(x) account; phone-managed setups report theirs via `phoneSettings`.
    var isConnected: Bool { status == State.connected }

    var linkedAccount: SitxLinkedAccount? {
        guard let refresh = SitxLinkedAccount(jwt: refreshToken) else { return nil }
        return SitxLinkedAccount(jwt: accessToken)?.updated(with: refresh) ?? refresh
    }
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
    private var connectInFlight = false
    private var relayTask: Task<Void, Never>?
    private var discardRelayedToken = false
    private var removingConnection = false
    private(set) var relayedHost: String?
    private var relayedGroup: String?
    /// Sends Sit(x) relay settings to Companion; set by the session model.
    var relayHandler: ((SitxRelayConfig) async throws -> BridgeWire.Message)?
    var onRelayChange: (() -> Void)?
    /// WatchConnectivity reachability, independent of whether Companion has a connected TAK server.
    var canReachPhone = false {
        didSet { if canReachPhone != oldValue { reconcileRelay() } }
    }
    var phoneRelayStatus: String? {
        didSet { if phoneRelayStatus != oldValue { updateRelayStatus() } }
    }
    private static let phoneSettingsKey = "WearTAK.sitxPhoneSettings"
    @Published private(set) var phoneSettings: SitxSettingsSnapshot?
    var phoneManagedSettings: SitxSettingsSnapshot? {
        guard let phoneSettings, phoneSettings.isPresent else { return nil }
        return phoneSettings
    }

    func applyPhoneSettings(_ snapshot: SitxSettingsSnapshot?) {
        guard let snapshot else { return }
        do {
            if snapshot.isPresent {
                defaults.set(try JSONEncoder().encode(snapshot), forKey: Self.phoneSettingsKey)
            } else {
                defaults.removeObject(forKey: Self.phoneSettingsKey)
            }
            phoneSettings = snapshot
            updateRelayStatus()
        } catch {
            status = "Sit(x) settings sync failed: \(error.localizedDescription)"
        }
    }
    var isRelayedViaPhone: Bool { relayedHost != nil }
    var onReady: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onChat: ((TAKChatMessage) -> Void)?
    var currentLocation: CLLocation?
    var additionalOutput: (any CoTOutput)?
    var companionOutput: (any CoTOutput)?
    /// Latest watch vitals; stale readings are sent as N/A.
    var biometrics = WatchBiometrics()
    private var biometricsReportingInterval: TimeInterval = 60
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
            if phoneManagedSettings != nil { updateRelayStatus() }
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
        reconcileRelay()
    }

    /// Keeps Companion's Sit(x) relay in step with the watch's settings. The refresh token has a single owner:
    /// the watch deletes its copy once the phone accepts it, and takes it back when Sit(x) is turned Off.
    func reconcileRelay() {
        guard !removingConnection else { return }
        guard canReachPhone, relayTask == nil, let relayHandler else { updateRelayStatus(); return }
        let host = Self.normalizedHost(settings.sitxApiHost)
        let ownsToken = refreshToken != nil && tokenHost == host
        if settings.sitxEnabled, let host, !selectedGroupID.isEmpty, ownsToken || relayedHost == host {
            let token = ownsToken ? refreshToken : nil
            if token != nil, pairingTask != nil || connectInFlight { return }
            guard token != nil || relayedGroup != selectedGroupID else { updateRelayStatus(); return }
            let group = selectedGroupID
            let config = SitxRelayConfig(enabled: true, host: host, flowTag: group,
                                         groupName: groups.first { $0.id == group }?.name, refreshToken: token)
            status = "Handing Sit(x) to iPhone"
            relayTask = Task {
                do {
                    let reply = try await relayHandler(config)
                    if let token, refreshToken == token {
                        disconnect()
                        pendingEvents = [:]
                        accessToken = nil
                        clearTokens()
                    }
                    setRelayed(host: host, group: group)
                    relayTask = nil
                    if let sitxStatus = reply.sitxStatus { phoneRelayStatus = sitxStatus }
                    updateRelayStatus()
                    reconcileRelay()
                } catch {
                    relayTask = nil
                    if relayedHost == nil { discardRelayedToken = false }
                    status = "iPhone relay setup failed: \(error.localizedDescription)"
                }
            }
        } else if let relayedHost {
            let keepToken = !discardRelayedToken && host == relayedHost && refreshToken == nil
            let config = SitxRelayConfig(enabled: false, host: relayedHost, flowTag: relayedGroup ?? "")
            relayTask = Task {
                do {
                    let reply = try await relayHandler(config)
                    if keepToken, refreshToken == nil, let token = reply.sitxConfig?.refreshToken, !token.isEmpty {
                        try saveToken(token, account: "refresh")
                        try saveToken(relayedHost, account: "host")
                        refreshToken = token
                        tokenHost = relayedHost
                    }
                    setRelayed(host: nil, group: nil)
                    relayTask = nil
                    if !settings.sitxEnabled { status = "Off" }
                    reconcileRelay()
                } catch {
                    relayTask = nil
                    status = "iPhone relay update failed: \(error.localizedDescription)"
                }
            }
        } else {
            updateRelayStatus()
        }
    }

    private func setRelayed(host: String?, group: String?) {
        relayedHost = host
        relayedGroup = group
        if host == nil { discardRelayedToken = false }
        defaults.set(host, forKey: "WearTAK.sitxRelayedHost")
        defaults.set(group, forKey: "WearTAK.sitxRelayedGroup")
        onRelayChange?()
    }

    private func updateRelayStatus() {
        if let phone = phoneManagedSettings {
            status = canReachPhone ? Self.phoneSetupPrefix + phone.status : Self.streamBlockedStatus
            return
        }
        if relayedHost == nil, refreshToken == nil, relayTask == nil, pairingTask == nil, authorizationCode.isEmpty {
            // Sit(x) set up in Companion itself: the watch holds no credentials and just reports the phone's state.
            if let phoneRelayStatus, !phoneRelayStatus.isEmpty {
                status = Self.phoneSetupPrefix + phoneRelayStatus
            } else if status.hasPrefix(Self.phoneSetupPrefix) {
                status = settings.sitxEnabled ? State.unconfigured : "Off"
            }
            return
        }
        guard relayedHost != nil, settings.sitxEnabled, relayTask == nil else { return }
        guard let phoneRelayStatus else {
            status = "Via iPhone; phone not reachable"
            return
        }
        if phoneRelayStatus.isEmpty {
            // Companion dropped the relay (removed on the phone or authorization ended); a new auth is needed.
            setRelayed(host: nil, group: nil)
            if refreshToken == nil { status = "iPhone relay ended; select Re-auth" }
            return
        }
        status = "Via iPhone: \(phoneRelayStatus)"
    }

    func resumeAuthorization() {
        guard settings.sitxEnabled, isAppActive, refreshToken != nil, !isPhoneReachable, socket == nil, pairingTask == nil else { return }
        pairingTask = Task {
            await beginPairing()
            pairingTask = nil
            if status.contains("failed") || status.contains("HTTP") {
                scheduleReconnect()
            }
            reconcileRelay()
        }
    }

    func setTAKEnabled(_ enabled: Bool) {
        settings.sitxEnabled = enabled
        if enabled {
            if refreshToken != nil { resumeAuthorization() }
            else if relayedHost == nil { refreshAuthorizationCode() }
            reconcileRelay()
        } else {
            pairingTask?.cancel()
            pairingTask = nil
            disconnect()
            pendingEvents = [:]
            authorizationCode = ""
            verificationURL = ""
            status = "Off"
            reconcileRelay()
        }
    }

    func setAppActive(_ active: Bool) {
        isAppActive = active
        if !active {
            pairingTask?.cancel()
            pairingTask = nil
            disconnect()
            status = !settings.sitxEnabled ? "Off" : relayedHost != nil ? "Via iPhone" :
                refreshToken == nil ? State.unconfigured : "Authorized; app inactive"
        }
        if phoneManagedSettings != nil { updateRelayStatus() }
    }

    func connect() async throws {
        // Prefer the phone: watchOS hardware blocks the Sit(x) WebSocket, and Companion can hold it instead.
        if relayedHost != nil || (canReachPhone && relayHandler != nil && refreshToken != nil) {
            reconcileRelay()
            if hasReadyOutput { return }
            throw TAKTransportError.notConfigured
        }
        guard settings.sitxEnabled, isAppActive, !isPhoneReachable, !selectedGroupID.isEmpty else {
            if hasReadyOutput { return }
            throw TAKTransportError.notConfigured
        }
        if socket != nil { return }
        let generation = connectionGeneration
        reconnectTask?.cancel()
        status = "Connecting TAK group"
        var streamRequested = false
        do {
            connectInFlight = true
            let request: URLRequest
            do {
                request = try await groupConnectionRequest()
                connectInFlight = false
            } catch {
                connectInFlight = false
                throw error
            }
            guard isAppActive, !isPhoneReachable, generation == connectionGeneration else { throw CancellationError() }
            streamRequested = true
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
                        self.handleIncoming(data)
                    }
                } catch {
                    guard let self, self.socket === task else { return }
                    self.connectionFailed(error)
                }
            }
            for (key, xml) in pendingEvents {
                try await sendEvent(xml, key: key)
            }
            Task { [weak self] in await self?.fetchStoredMessages(generation: generation) }
        } catch {
            if generation == connectionGeneration {
                if streamRequested, Self.isWatchOSStreamBlocked(error) {
                    disconnect()
                    status = Self.streamBlockedStatus
                    reconcileRelay()
                } else {
                    connectionFailed(error)
                }
            }
            if additionalOutput?.isReady == true { return }
            throw error
        }
    }

    private func handleIncoming(_ data: Data) {
        if let chat = TAKChatMessage.parse(String(decoding: data, as: UTF8.self), ownUID: Self.deviceID()) {
            onChat?(chat)
            return
        }
        for entity in SitxCoT.parse(data, excluding: Self.deviceID()) {
            entityContinuation?.yield(entity)
        }
    }

    /// Delivers GeoChat and other CoT that Sit(x) Store and Forward held while offline, then acknowledges each.
    /// Best effort: failures leave the messages on the server for the next connection.
    private func fetchStoredMessages(generation: Int) async {
        guard let host = Self.normalizedHost(settings.sitxApiHost), tokenHost == host, !selectedGroupID.isEmpty,
              let listURL = SitxStoredMessage.listURL(host: host, flowTag: selectedGroupID) else { return }
        let flowTag = selectedGroupID
        do {
            let data = try await storedMessagesRequest(listURL, method: "GET")
            for message in SitxStoredMessage.parse(data, flowTag: flowTag) {
                guard generation == connectionGeneration, socket != nil else { return }
                handleIncoming(Data(message.payload.utf8))
                if let ackURL = SitxStoredMessage.acknowledgeURL(host: host, id: message.id) {
                    _ = try? await storedMessagesRequest(ackURL, method: "PATCH")
                }
            }
        } catch {}
    }

    private func storedMessagesRequest(_ url: URL, method: String) async throws -> Data {
        guard let refreshToken else { throw SitxError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("Bearer \(refreshToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SitxError.invalidResponse
        }
        return data
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
        // A sequestered device stays muted until resolved in the portal, so poll it less often.
        if case .sequestered? = error as? SitxError { scheduleReconnect(after: 60) } else { scheduleReconnect() }
    }

    private func scheduleReconnect(after delay: Double = 10) {
        guard settings.sitxEnabled, isAppActive, !isPhoneReachable, refreshToken != nil else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
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

    func sendContactChat(_ xml: String) async throws {
        guard isSitxConnected else { throw TAKTransportError.notConfigured }
        try await sendXML(xml)
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

    func sendPLI(coordinate: CLLocationCoordinate2D, reportingInterval: TimeInterval = 60) async throws {
        biometricsReportingInterval = reportingInterval
        let now = Date()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let detail = SitxCoT.pliDetail(
            uid: Self.deviceID(), callSign: settings.callSign, team: settings.teamColor.rawValue, role: settings.role,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            osVersion: "watchOS \(os.majorVersion).\(os.minorVersion)") +
            biometrics.fresh(reportingInterval: reportingInterval, now: now)
                .pliDetail(uid: Self.deviceID(), now: now, reportingInterval: reportingInterval)
        let lifetime = WatchBiometrics.staleLifetime(reportingInterval: reportingInterval)
        try await deliver(SitxCoT.event(uid: Self.deviceID(), type: SitxCoT.pliType, coordinate: coordinate,
                                      detail: detail, lifetime: lifetime, now: now))
    }

    func sendMarker(_ marker: WatchMarker) async throws {
        try await deliver(markerXML(marker), eventKey: marker.id.uuidString)
    }

    func markerXML(_ marker: WatchMarker) -> String {
        let affiliation: String
        switch marker.kind {
        case .friendly: affiliation = "f"
        case .hostile: affiliation = "h"
        case .neutral: affiliation = "n"
        case .unknown: affiliation = "u"
        }
        let callSign = marker.title.flatMap { $0.isEmpty ? nil : $0 } ?? "\(marker.kind.rawValue) 2525D point"
        let detail = "<contact callsign=\"\(SitxCoT.escape(callSign))\"/><remarks>\(SitxCoT.escape(marker.remark ?? ""))</remarks><link uid=\"\(Self.deviceID())\" type=\"a-f-G-U-C\" relation=\"p-p\"/>"
        return SitxCoT.event(uid: marker.id.uuidString, type: "a-\(affiliation)-G", coordinate: marker.coordinate,
                            detail: detail, lifetime: 86_400)
    }

    func deleteMarker(uid: String) async throws {
        try await deliver(deleteMarkerXML(uid: uid), eventKey: uid)
    }

    func deleteMarkerXML(uid: String) -> String {
        let detail = "<link uid=\"\(SitxCoT.escape(uid))\" relation=\"p-p\"/><__forcedelete/>"
        return SitxCoT.event(uid: uid + "-delete", type: "t-x-d-d", coordinate: currentLocation?.coordinate ?? CLLocationCoordinate2D(latitude: 0, longitude: 0),
                            detail: detail, lifetime: 86_400)
    }

    func sendEmergencyAlert(state: EmergencyState, type: String) async throws {
        try await deliver(emergencyXML(state: state, type: type), eventKey: Self.deviceID() + "-alert-" + type)
    }

    func emergencyXML(state: EmergencyState, type: String) -> String {
        let uid = Self.deviceID() + "-alert-" + type
        let cancel = state == .cancel
        let emergency = cancel ? "<emergency cancel=\"true\">\(SitxCoT.escape(settings.callSign))</emergency>"
            : "<emergency type=\"\(SitxCoT.escape(type))\">\(SitxCoT.escape(settings.callSign))</emergency>"
        let detail = "<contact callsign=\"\(SitxCoT.escape(settings.callSign))\"/><link uid=\"\(Self.deviceID())\" type=\"a-f-G-U-C\" relation=\"p-p\"/><remarks>\(SitxCoT.escape(type))</remarks>" +
            biometrics.fresh(reportingInterval: biometricsReportingInterval).biometricsElement(uid: Self.deviceID(),
                alertAttributes: " alertUid=\"\(SitxCoT.escape(uid))\" alertState=\"\(state.rawValue)\" alertCategory=\"\(SitxCoT.escape(type))\" alertPriority=\"1\" alertDescription=\"\(SitxCoT.escape(type))\"") + emergency
        return SitxCoT.event(uid: uid, type: cancel ? "b-a-o-can" : "b-a-o", coordinate: currentLocation?.coordinate ?? CLLocationCoordinate2D(latitude: 0, longitude: 0),
                            detail: detail, lifetime: 86_400)
    }

    /// The durable session outbox owns retries; do not also retain events in the transient Sit(x) queue.
    func sendQueuedEvent(_ xml: String) async throws {
        try await deliver(xml)
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
        if let rotated = response["refresh_token"] as? String {
            self.refreshToken = rotated
            try saveToken(rotated, account: "refresh")
        }
        if let reason = SitxAPI.sequesteredReason(response["sequestered_status"]) { throw SitxError.sequestered(reason) }
        guard let endpoint = response["end_point"] as? String,
              let url = URL(string: endpoint), url.scheme == "wss",
              let token = response["access_token"] as? String else { throw SitxError.invalidResponse }
        var socketRequest = URLRequest(url: url)
        socketRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return socketRequest
    }

    var menuLabel: String {
        if status == State.connected || status == "Authorized; select Connect / Pair to verify" {
            return "Sit(x) Enabled"
        }
        if status.hasPrefix("Via iPhone: Connected") || status.hasPrefix(Self.phoneSetupPrefix + "Connected") {
            return "Sit(x) via iPhone"
        }
        if status == Self.streamBlockedStatus { return "Sit(x) Needs iPhone" }
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
        relayedHost = defaults.string(forKey: "WearTAK.sitxRelayedHost")
        relayedGroup = defaults.string(forKey: "WearTAK.sitxRelayedGroup")
        if let data = defaults.data(forKey: "WearTAK.sitxGroups"),
           let saved = try? JSONDecoder().decode([SitxGroup].self, from: data) {
            groups = saved
        }
        if accessToken != nil || refreshToken != nil {
            status = "Authorized; select Connect / Pair to verify"
        } else if relayedHost != nil {
            status = "Via iPhone; phone not reachable"
        }
        hostSubscription = settings.$sitxApiHost.dropFirst().sink { [weak self] host in
            guard let self, let current = self.tokenHost ?? self.relayedHost,
                  current != Self.normalizedHost(host) else { return }
            self.forgetAuthorization()
        }
        if !settings.sitxEnabled { status = "Off" }
        if let data = defaults.data(forKey: Self.phoneSettingsKey) {
            do {
                phoneSettings = try JSONDecoder().decode(SitxSettingsSnapshot.self, from: data)
                updateRelayStatus()
            } catch {
                status = "Sit(x) saved settings could not be loaded: \(error.localizedDescription)"
            }
        }
    }

    func refreshAuthorizationCode() {
        guard settings.sitxEnabled else { return }
        forgetAuthorization()
        pairingTask = Task {
            await beginPairing()
            pairingTask = nil
            reconcileRelay()
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
        defaults.removeObject(forKey: "WearTAK.sitxGroups")
        selectedGroupID = ""
        defaults.removeObject(forKey: "WearTAK.sitxGroup")
        status = State.unconfigured
        if relayedHost != nil || relayTask != nil {
            // Also covers Re-auth during a pending handoff: the token reaching the phone must not come back.
            discardRelayedToken = true
            reconcileRelay()
        }

    }

    func removeConnection() async throws {
        removingConnection = true
        defer { removingConnection = false }
        let pendingPairing = pairingTask
        pendingPairing?.cancel()
        disconnect()
        await pendingPairing?.value
        if let relayTask { await relayTask.value }
        if relayedHost != nil || phoneManagedSettings != nil || !(phoneRelayStatus ?? "").isEmpty {
            guard canReachPhone, let relayHandler else {
                throw NSError(domain: "WearTAK.SitxRemoval", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Open Companion on the paired iPhone to remove the relayed Sit(x) connection."])
            }
            let reply = try await relayHandler(SitxRelayConfig(enabled: false, host: relayedHost ?? "",
                flowTag: relayedGroup ?? "", removeConnection: true))
            guard reply.kind == .acknowledgement, reply.ready == true,
                  reply.sitxConfig?.removeConnection == true else {
                throw NSError(domain: "WearTAK.SitxRemoval", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: reply.detail ?? "The iPhone did not confirm Sit(x) removal."])
            }
        }
        setRelayed(host: nil, group: nil)
        settings.sitxEnabled = false
        forgetAuthorization()
        settings.sitxApiHost = ""
        deviceCode = nil
        expiresAt = nil
        phoneRelayStatus = ""
        phoneSettings = nil
        defaults.removeObject(forKey: Self.phoneSettingsKey)
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
            defaults.removeObject(forKey: "WearTAK.sitxGroups")
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
            authorizationCode = SitxAPI.displayUserCode(userCode)
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
        var retry = SitxAuthorizationRetry()
        var retryDelay: TimeInterval?
        while !Task.isCancelled, let deviceCode, let expiresAt {
            guard Date() < expiresAt else {
                status = State.expired
                self.deviceCode = nil
                return
            }
            do {
                let delay = min(retryDelay ?? pollInterval, max(0, expiresAt.timeIntervalSinceNow))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                try Task.checkCancellation()
                guard Date() < expiresAt else { continue }
                retryDelay = nil
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
                if let reason = SitxAPI.sequesteredReason(response["sequestered_status"]), status != State.connected {
                    status = reason
                }
                return
            } catch is CancellationError {
                return
            } catch let error as SitxError where error == .authorizationPending {
                status = State.awaitingAuthorization
                continue
            } catch let error as SitxError where error == .slowDown {
                pollInterval += 5
                status = State.awaitingAuthorization
            } catch let error as SitxError where error == .authorizationExpired {
                status = State.expired
                self.deviceCode = nil
                return
            } catch {
                guard !Task.isCancelled else { return }
                if let delay = retry.delay(for: error, pollingInterval: pollInterval) {
                    retryDelay = delay
                    status = SitxAuthorizationRetry.status(Self.errorSummary(error, context: "Sit(x) token exchange"))
                    continue
                }
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
            if let reason = SitxAPI.sequesteredReason(response["sequestered_status"]), status != State.connected {
                status = reason
            }
        } catch {
            if let code = (error as? SitxError)?.statusCode, code == 401 || code == 403 {
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
            if let encoded = try? JSONEncoder().encode(groups) { defaults.set(encoded, forKey: "WearTAK.sitxGroups") }
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
        if case .sequestered(let reason)? = error as? SitxError { return reason }
        if let sitxError = error as? SitxError {
            return "\(context) failed: \(sitxError.localizedDescription)"
        }
        let nsError = error as NSError
        if let urlError = error as? URLError {
            return "\(context) network error \(urlError.code.rawValue) (\(networkReason(urlError.code)))"
        }
        return "\(context) failed (\(nsError.domain) \(nsError.code))"
    }

    private static func networkReason(_ code: URLError.Code) -> String { SitxAPI.networkReason(code) }

    /// Real watchOS hardware rejects URLSessionWebSocketTask (TN3135) even though HTTPS works,
    /// surfacing as "not connected to internet" right after the access-token request succeeded.
    static func isWatchOSStreamBlocked(_ error: Error) -> Bool {
        #if os(watchOS) && !targetEnvironment(simulator)
        return (error as? URLError)?.code == .notConnectedToInternet
        #else
        return false
        #endif
    }

    static let phoneSetupPrefix = "On iPhone: "
    static let streamBlockedStatus = "Live stream needs WearTAK Companion; watchOS blocks direct Sit(x) streaming"

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
            if let message = Self.serverMessage(from: data) {
                throw SitxError.httpFailure(http.statusCode, message)
            }
            throw SitxError.httpStatus(http.statusCode)
        }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func serverMessage(from data: Data) -> String? { SitxAPI.serverMessage(from: data) }

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

    static func normalizedHost(_ value: String) -> String? { SitxAPI.normalizedHost(value) }

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
    case httpFailure(Int, String)
    case sequestered(String)
    case keychain(OSStatus)

    var statusCode: Int? {
        switch self {
        case .httpStatus(let code), .httpFailure(let code, _): return code
        default: return nil
        }
    }

    var localizedDescription: String {
        switch self {
        case .authorizationPending: return "Waiting for authorization"
        case .slowDown: return "Authorization server requested slower polling"
        case .authorizationExpired: return "Code expired; retry"
        case .accountVerificationFailed: return "Account verification failed"
        case .invalidResponse: return "Invalid Sit(x) response"
        case .httpStatus(let code): return "Sit(x) HTTP \(code)"
        case .httpFailure(let code, let message): return "Sit(x) HTTP \(code): \(message)"
        case .sequestered(let reason): return reason
        case .keychain(let status): return "Secure token storage failed (\(status))"
        }
    }
}
