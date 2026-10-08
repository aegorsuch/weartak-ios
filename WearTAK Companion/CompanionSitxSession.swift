import Foundation
import os
import Security

/// Sit(x) TAK on the phone. Holds the Sit(x) WebSocket for the watch (watchOS hardware blocks WebSockets), and
/// can be set up either on the watch (the watch hands over its refresh token) or here with the same flow as the watch.
@MainActor
final class CompanionSitxSession: ObservableObject {
    struct Config: Equatable {
        var host: String
        var flowTag: String
        var groupName: String?
    }

    private struct Stored: Codable {
        var host: String?
        var flowTag: String?
        var groupName: String?
        var enabled: Bool?
    }

    enum Status {
        static let unconfigured = "Not connected"
        static let requestingCode = "Requesting device code"
        static let awaitingAuthorization = "Waiting for authorization"
        static let checking = "Checking account"
        static let expired = "Code expired; retry"
        static let selectGroup = "Authorized; select TAK group"
        static let noGroups = "No permitted TAK groups"
        static let off = "Off"
        static let needsAddress = "Enter Sit(x) API host"
        static let reauth = "Sit(x) authorization expired; select Re-auth"
    }

    var onState: ((PhoneBridgeModel.ServerState) -> Void)?
    var onCoT: ((String) -> Void)?
    @Published private(set) var state = PhoneBridgeModel.ServerState(configured: false, connected: false, detail: Status.unconfigured)
    @Published private(set) var host = ""
    @Published private(set) var enabled = false
    @Published private(set) var groups: [SitxGroup] = []
    @Published private(set) var selectedFlowTag = ""
    @Published private(set) var authorizationCode = ""
    @Published private(set) var verificationURL = ""
    @Published private(set) var hasAuthorization = false
    private var groupName: String?
    private var active = true
    private let session: URLSession
    private let defaults: UserDefaults
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var pairingTask: Task<Void, Never>?
    private var connecting = false
    private var tokenChain: Task<Void, Never>?
    private var generation = 0
    private var releasedToken: String?
    private var lastLoggedDetail = ""
    private let logger = Logger(subsystem: "com.aegorsuch.weartak", category: "Sitx")
    private static let configKey = "WearTAK.companion.sitx"
    private static let groupsKey = "WearTAK.companion.sitxGroups"
    private static let deviceIDKey = "WearTAK.companion.sitxDeviceID"
    private static let tokenService = "com.aegorsuch.weartak.companion.sitx"

    /// The active stream settings; nil while Off, unauthorized, or without a group.
    var config: Config? {
        guard enabled, hasAuthorization, !host.isEmpty, !selectedFlowTag.isEmpty else { return nil }
        return Config(host: host, flowTag: selectedFlowTag, groupName: groupName)
    }

    /// True when Sit(x) is a live relay source for the watch.
    var isConfigured: Bool { config != nil }
    /// True when the phone holds (or is obtaining) Sit(x) authorization, so its state is worth reporting to the watch.
    var isSetUp: Bool { hasAuthorization || pairingTask != nil }
    var selectedGroupName: String? { groups.first { $0.id == selectedFlowTag }?.name ?? groupName }

    var settingsSnapshot: SitxSettingsSnapshot {
        SitxSettingsSnapshot(enabled: enabled, host: host, groupName: selectedGroupName, status: state.detail)
    }

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        let stored = defaults.data(forKey: Self.configKey).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        host = stored?.host ?? ""
        selectedFlowTag = stored?.flowTag ?? ""
        groupName = stored?.groupName
        enabled = stored?.enabled ?? (stored?.flowTag != nil)
        groups = defaults.data(forKey: Self.groupsKey).flatMap { try? JSONDecoder().decode([SitxGroup].self, from: $0) } ?? []
        hasAuthorization = Self.readToken() != nil
        state.detail = !enabled ? (stored == nil ? Status.unconfigured : Status.off)
            : !hasAuthorization ? Status.unconfigured
            : selectedFlowTag.isEmpty ? Status.selectGroup : "Waiting to connect"
        state.configured = isConfigured
    }

    // MARK: - Setup on the phone (same flow as the watch)

    func setEnabled(_ on: Bool) {
        enabled = on
        save()
        if on {
            if hasAuthorization {
                if selectedFlowTag.isEmpty { setStatus(Status.selectGroup) }
                connect()
                if groups.isEmpty { refreshGroups() }
            } else {
                reauthorize()
            }
        } else {
            cancelPairing()
            disconnect(detail: Status.off)
        }
    }

    func setAddress(_ newHost: String) {
        guard newHost != host else { return }
        forgetAuthorization(detail: Status.unconfigured)
        host = newHost
        save()
        if enabled { reauthorize() }
    }

    func selectGroup(_ group: SitxGroup) {
        guard group.id != selectedFlowTag || socket == nil else { return }
        selectedFlowTag = group.id
        groupName = group.name
        save()
        disconnect(detail: "Connecting")
        connect()
    }

    /// Re-auth: discards the old credentials and starts a new device authorization.
    func reauthorize() {
        forgetAuthorization(detail: Status.unconfigured)
        guard enabled else { return }
        guard !host.isEmpty else { setStatus(Status.needsAddress); return }
        let host = self.host
        pairingTask = Task { [weak self] in
            await self?.pair(host: host)
            self?.pairingTask = nil
            self?.publish()
        }
        publish()
    }

    /// Reloads the permitted groups, e.g. after the watch handed over its authorization.
    func refreshGroups() {
        guard hasAuthorization, !host.isEmpty, pairingTask == nil else { return }
        let host = self.host
        pairingTask = Task { [weak self] in
            await self?.loadGroups(host: host)
            self?.pairingTask = nil
            self?.publish()
        }
    }

    private func pair(host: String) async {
        setStatus(Status.requestingCode)
        var stage = "Sit(x) device authorization"
        do {
            let deviceID = Self.deviceID(defaults)
            let scope = "role:org_user callsign:WEARTAK-\(deviceID.prefix(8)) device_name:WearTAK-iPhone device_id:\(deviceID)"
            let code = try await post(host + "/api/v1/device/authorization/code", json: ["scope": scope, "client_id": SitxAPI.clientID])
            guard let deviceCode = code["device_code"] as? String, let userCode = code["user_code"] as? String else {
                throw SitxHTTPError.invalidResponse
            }
            authorizationCode = userCode
            verificationURL = code["verification_uri"] as? String ?? code["verification_url"] as? String ?? ""
            var interval = max(1, code["interval"] as? Double ?? 5)
            let expiresAt = Date().addingTimeInterval(code["expires_in"] as? Double ?? 600)
            setStatus(Status.awaitingAuthorization)
            stage = "Sit(x) token exchange"
            var retry = SitxAuthorizationRetry()
            var retryDelay: TimeInterval?
            while true {
                guard Date() < expiresAt else {
                    authorizationCode = ""
                    verificationURL = ""
                    setStatus(Status.expired)
                    return
                }
                try await Task.sleep(for: .seconds(min(retryDelay ?? interval, max(0, expiresAt.timeIntervalSinceNow))))
                try Task.checkCancellation()
                guard Date() < expiresAt else { continue }
                retryDelay = nil
                do {
                    let token = try await post(host + "/api/v1/device/authorization/token", form: [
                        "client_id": SitxAPI.clientID,
                        "device_code": deviceCode,
                        "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
                    ])
                    guard let refresh = token["refresh_token"] as? String, !refresh.isEmpty else { throw SitxHTTPError.invalidResponse }
                    try Task.checkCancellation()
                    try Self.saveToken(refresh)
                    releasedToken = nil
                    hasAuthorization = true
                    authorizationCode = ""
                    verificationURL = ""
                    await loadGroups(host: host)
                    if let reason = SitxAPI.sequesteredReason(token["sequestered_status"]), !state.connected {
                        logger.warning("Sit(x) device sequestered after authorization: \(reason, privacy: .public)")
                        setStatus(reason)
                    }
                    return
                } catch SitxHTTPError.authorizationPending {
                    setStatus(Status.awaitingAuthorization)
                    continue
                } catch SitxHTTPError.slowDown {
                    interval += 5
                    setStatus(Status.awaitingAuthorization)
                } catch {
                    try Task.checkCancellation()
                    guard let delay = retry.delay(for: error, pollingInterval: interval) else { throw error }
                    retryDelay = delay
                    setStatus(SitxAuthorizationRetry.status(Self.errorSummary(error, context: stage)))
                }
            }
        } catch is CancellationError {
            return
        } catch SitxHTTPError.expired {
            authorizationCode = ""
            verificationURL = ""
            setStatus(Status.expired)
        } catch {
            authorizationCode = ""
            verificationURL = ""
            setStatus(Self.errorSummary(error, context: stage))
        }
    }

    private func loadGroups(host: String) async {
        setStatus(Status.checking)
        do {
            let data = try await withToken { [session] refresh -> Data in
                var request = URLRequest(url: URL(string: host + "/api/v1/tak_servers")!, timeoutInterval: 15)
                request.setValue("Bearer \(refresh)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await session.data(for: request)
                try Self.check(response, data: data)
                return data
            }
            guard host == self.host, !Task.isCancelled else { return }
            groups = try JSONDecoder().decode([SitxGroup].self, from: data)
            defaults.set(try? JSONEncoder().encode(groups), forKey: Self.groupsKey)
            if !selectedFlowTag.isEmpty, !groups.contains(where: { $0.id == selectedFlowTag }) {
                selectedFlowTag = ""
                groupName = nil
                save()
                disconnect(detail: Status.selectGroup)
            }
            if groups.count == 1, let group = groups.first, selectedFlowTag.isEmpty {
                selectGroup(group)
            } else if selectedFlowTag.isEmpty {
                setStatus(groups.isEmpty ? Status.noGroups : Status.selectGroup)
            } else if state.connected {
                setStatus("Connected" + (selectedGroupName.map { " (\($0))" } ?? ""))
            } else if connecting {
                setStatus("Connecting")
            } else if socket == nil {
                connect()
            }
        } catch is CancellationError {
            return
        } catch SitxHTTPError.unauthorized {
            forgetAuthorization(detail: Status.reauth)
        } catch {
            setStatus("Authorized; " + Self.errorSummary(error, context: "profile check"))
        }
    }

    private func forgetAuthorization(detail: String) {
        cancelPairing()
        Self.deleteToken()
        releasedToken = nil
        hasAuthorization = false
        groups = []
        defaults.removeObject(forKey: Self.groupsKey)
        selectedFlowTag = ""
        groupName = nil
        save()
        disconnect(detail: detail)
    }

    private func cancelPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        authorizationCode = ""
        verificationURL = ""
    }

    // MARK: - Watch hand-off

    func apply(_ relay: SitxRelayConfig) throws {
        guard relay.enabled else { clear(); return }
        releasedToken = nil
        if let token = relay.refreshToken {
            cancelPairing()
            try Self.saveToken(token)
            hasAuthorization = true
        } else {
            guard hasAuthorization, host == relay.host else {
                throw CompanionFailure.message("Sit(x) needs Re-auth on the watch.")
            }
        }
        let changed = host != relay.host || selectedFlowTag != relay.flowTag || relay.refreshToken != nil || !enabled
        if host != relay.host { groups = []; defaults.removeObject(forKey: Self.groupsKey) }
        host = relay.host
        selectedFlowTag = relay.flowTag
        groupName = relay.groupName
        enabled = true
        if !groups.contains(where: { $0.id == relay.flowTag }) {
            groups.append(SitxGroup(flowTag: relay.flowTag, name: relay.groupName ?? relay.flowTag))
        }
        save()
        if changed {
            disconnect(detail: "Connecting")
            connect()
        } else if socket == nil, !connecting {
            retryTask?.cancel()
            retryTask = nil
            connect()
        }
    }

    /// Removes Sit(x) from the phone: credentials and group are forgotten and streaming stops.
    func clear() {
        forgetAuthorization(detail: Status.unconfigured)
        enabled = false
        save()
        publish()
    }

    func removeConnection() async {
        let pendingPairing = pairingTask
        cancelPairing()
        enabled = false
        disconnect(detail: Status.unconfigured)
        await pendingPairing?.value
        await tokenChain?.value
        clear()
        host = ""
        releasedToken = nil
        defaults.removeObject(forKey: Self.configKey)
        defaults.removeObject(forKey: Self.groupsKey)
        defaults.removeObject(forKey: Self.deviceIDKey)
        publish()
    }

    /// Stops streaming and returns the refresh token so the watch can own it again. Waits for any in-flight
    /// token request first, because that request may rotate the token. The returned token is kept in
    /// memory so a retried release (lost reply, or a failed watch Keychain write) can return it again.
    func release() async -> String? {
        await tokenChain?.value
        guard let token = Self.readToken() else { return releasedToken }
        clear()
        releasedToken = token
        return token
    }

    // MARK: - Streaming

    func setActive(_ active: Bool) {
        let changed = active != self.active
        self.active = active
        if active { connect() } else if changed, config != nil { disconnect(detail: "Paused in background") }
    }

    func send(_ xml: String) async throws {
        guard state.connected, let socket else { throw CompanionFailure.message("Sit(x) is not connected.") }
        do { try await socket.send(.string(xml)) }
        catch {
            if self.socket === socket { fail("Sit(x) write failed: \(error.localizedDescription)") }
            throw error
        }
    }

    private func connect() {
        guard active, let config, socket == nil, !connecting, retryTask == nil else { return }
        connecting = true
        let generation = self.generation
        setStatus("Connecting")
        Task {
            defer { if generation == self.generation { self.connecting = false } }
            do {
                let request = try await withToken { [session] refresh in
                    try await Self.socketRequest(config, refresh: refresh, session: session)
                }
                guard generation == self.generation, active else { return }
                let task = session.webSocketTask(with: request)
                socket = task
                task.resume()
                // A hung handshake never answers the ping, so bound it and retry like any other failure.
                let timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled, let self, self.socket === task, !self.state.connected else { return }
                    task.cancel(with: .goingAway, reason: nil)
                }
                defer { timeout.cancel() }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    task.sendPing { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
                guard socket === task else { return }
                state.connected = true
                setStatus("Connected" + (config.groupName.map { " (\($0))" } ?? ""))
                receive(task)
                await fetchStoredMessages(config, generation: generation)
            } catch SitxHTTPError.sequestered(let reason) {
                guard generation == self.generation else { return }
                logger.warning("Sit(x) device sequestered: \(reason, privacy: .public)")
                fail(reason, retryAfter: 60)
            } catch SitxHTTPError.unauthorized {
                guard generation == self.generation else { return }
                forgetAuthorization(detail: Status.reauth)
            } catch {
                guard generation == self.generation else { return }
                fail("Sit(x) connection failed: \(Self.errorSummary(error, context: "TAK group"))")
            }
        }
    }

    /// Delivers GeoChat and other CoT that Sit(x) Store and Forward held while this device was offline, then
    /// acknowledges each so it is not delivered again. Failures are logged; live streaming is unaffected.
    /// Data Sync (Mission API) request on Sit(x); `path` is relative to `/api/v1` and already percent-encoded.
    func missionRequest(path: String, method: String = "GET", query: [URLQueryItem] = []) async throws -> Data {
        guard let config, state.connected, var components = URLComponents(string: config.host) else {
            throw CompanionFailure.message("Sit(x) is not connected.")
        }
        components.percentEncodedPath = "/api/v1" + path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw CompanionFailure.message("Invalid Sit(x) Data Sync URL.") }
        do {
            return try await withToken { [session] refresh -> Data in
                var request = URLRequest(url: url, timeoutInterval: 20)
                request.httpMethod = method
                request.setValue("Bearer \(refresh)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await session.data(for: request)
                try Self.check(response, data: data)
                guard data.count <= 4_194_304 else { throw CompanionFailure.message("Sit(x) Data Sync response is too large.") }
                return data
            }
        } catch let error as CompanionFailure {
            throw error
        } catch {
            throw CompanionFailure.message("Sit(x) Data Sync: \(Self.errorSummary(error, context: "Data Sync"))")
        }
    }

    private func fetchStoredMessages(_ config: Config, generation: Int) async {
        guard let listURL = SitxStoredMessage.listURL(host: config.host, flowTag: config.flowTag) else { return }
        do {
            let data = try await withToken { [session] refresh -> Data in
                var request = URLRequest(url: listURL, timeoutInterval: 15)
                request.setValue("Bearer \(refresh)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await session.data(for: request)
                try Self.check(response, data: data)
                return data
            }
            let messages = SitxStoredMessage.parse(data, flowTag: config.flowTag)
            guard generation == self.generation else { return }
            guard !messages.isEmpty else {
                logger.info("Sit(x) Store and Forward: no pending messages")
                return
            }
            logger.notice("Sit(x) delivering \(messages.count) stored message(s)")
            for message in messages {
                guard generation == self.generation else { return }
                onCoT?(message.payload)
                guard let ackURL = SitxStoredMessage.acknowledgeURL(host: config.host, id: message.id) else { continue }
                _ = try? await withToken { [session] refresh -> Data in
                    var request = URLRequest(url: ackURL, timeoutInterval: 15)
                    request.httpMethod = "PATCH"
                    request.setValue("Bearer \(refresh)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    let (data, response) = try await session.data(for: request)
                    try Self.check(response, data: data)
                    return data
                }
            }
        } catch {
            logger.error("Sit(x) stored messages unavailable: \(Self.errorSummary(error, context: "Store and Forward"), privacy: .public)")
        }
    }

    /// Runs token-using requests one at a time. Sit(x) rotates refresh tokens and reusing an old one revokes the
    /// whole token family, so a request must never read the token while another request may be rotating it.
    private func withToken<T: Sendable>(_ operation: @escaping @MainActor (String) async throws -> T) async throws -> T {
        let previous = tokenChain
        let task = Task { @MainActor () throws -> T in
            await previous?.value
            guard let refresh = Self.readToken() else { throw SitxHTTPError.unauthorized }
            return try await operation(refresh)
        }
        tokenChain = Task { _ = try? await task.value }
        return try await task.value
    }

    private static func socketRequest(_ config: Config, refresh: String, session: URLSession) async throws -> URLRequest {
        var request = URLRequest(url: URL(string: config.host + "/api/v1/access/token")!, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("Bearer \(refresh)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "access"),
            URLQueryItem(name: "resource_type", value: "TAKSERVER"),
            URLQueryItem(name: "resource_key", value: config.flowTag)
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        try check(response, data: data)
        let body = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let rotated = body["refresh_token"] as? String, !rotated.isEmpty { try saveToken(rotated) }
        if let reason = SitxAPI.sequesteredReason(body["sequestered_status"]) { throw SitxHTTPError.sequestered(reason) }
        guard let endpoint = body["end_point"] as? String, let socketURL = URL(string: endpoint), socketURL.scheme == "wss",
              let access = body["access_token"] as? String else {
            throw SitxHTTPError.invalidResponse
        }
        var socketRequest = URLRequest(url: socketURL)
        socketRequest.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        return socketRequest
    }

    // MARK: - HTTP helpers

    private enum SitxHTTPError: LocalizedError {
        case authorizationPending, slowDown, expired, unauthorized, invalidResponse
        case status(Int, String?)
        case sequestered(String)

        var errorDescription: String? {
            switch self {
            case .authorizationPending: return "authorization pending"
            case .slowDown: return "polling too fast"
            case .expired: return Status.expired
            case .sequestered(let reason): return reason
            case .unauthorized: return "authorization rejected"
            case .invalidResponse: return "invalid server response"
            case .status(let code, let message): return message.map { "HTTP \(code): \($0)" } ?? "HTTP \(code)"
            }
        }
    }

    private func post(_ url: String, json: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return try await perform(request)
    }

    private func post(_ url: String, form fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 400 {
            switch ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String {
            case "authorization_pending": throw SitxHTTPError.authorizationPending
            case "slow_down": throw SitxHTTPError.slowDown
            case "expired_token": throw SitxHTTPError.expired
            default: break
            }
        }
        try Self.check(response, data: data)
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private nonisolated static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw SitxHTTPError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw SitxHTTPError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw SitxHTTPError.status(http.statusCode, SitxAPI.serverMessage(from: data))
        }
    }

    private static func errorSummary(_ error: Error, context: String) -> String {
        if let urlError = error as? URLError {
            return "\(context) network error \(urlError.code.rawValue) (\(SitxAPI.networkReason(urlError.code)))"
        }
        if let sitxError = error as? SitxHTTPError { return "\(context) failed: \(sitxError.localizedDescription)" }
        return "\(context) failed: \(error.localizedDescription)"
    }

    private static func deviceID(_ defaults: UserDefaults) -> String {
        if let saved = defaults.string(forKey: deviceIDKey) { return saved }
        let value = UUID().uuidString.lowercased()
        defaults.set(value, forKey: deviceIDKey)
        return value
    }

    private func save() {
        let stored = Stored(host: host.isEmpty ? nil : host, flowTag: selectedFlowTag.isEmpty ? nil : selectedFlowTag,
                            groupName: groupName, enabled: enabled)
        defaults.set(try? JSONEncoder().encode(stored), forKey: Self.configKey)
    }

    private func setStatus(_ detail: String) {
        state.detail = detail
        publish()
    }

    private func publish() {
        if state.detail != lastLoggedDetail {
            lastLoggedDetail = state.detail
            logger.notice("Sit(x) state: \(self.state.detail, privacy: .public) host=\(self.host, privacy: .public) group=\(self.selectedFlowTag, privacy: .public) enabled=\(self.enabled) auth=\(self.hasAuthorization)")
        }
        state.configured = isConfigured
        onState?(state)
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        receiveTask = Task { [weak self] in
            var framer = CoTStreamFramer()
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
                    let events = try framer.append(data)
                    if events.isEmpty {
                        self.logger.debug("Sit(x) frame buffered: \(data.count) bytes")
                    }
                    for event in events {
                        let xml = String(decoding: event, as: UTF8.self)
                        self.logger.notice("Sit(x) CoT received: \(String(xml.prefix(400)), privacy: .public)")
                        self.onCoT?(xml)
                    }
                }
            } catch {
                guard let self, self.socket === task else { return }
                self.fail("Sit(x) connection lost: \(error.localizedDescription)")
            }
        }
    }

    private func disconnect(detail: String) {
        generation += 1
        connecting = false
        retryTask?.cancel()
        retryTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        state.connected = false
        state.detail = detail
        publish()
    }

    private func fail(_ message: String, retryAfter: Double = 10) {
        disconnect(detail: message)
        guard active, config != nil else { return }
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(retryAfter)) } catch { return }
            self?.retryTask = nil
            self?.connect()
        }
    }

    private static func tokenQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: tokenService,
         kSecAttrAccount as String: "refresh"]
    }

    private static func readToken() -> String? {
        var query = tokenQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func saveToken(_ token: String) throws {
        deleteToken()
        var item = tokenQuery()
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw CompanionFailure.message("Unable to store Sit(x) token (\(status)).") }
    }

    private static func deleteToken() {
        SecItemDelete(tokenQuery() as CFDictionary)
    }
}
