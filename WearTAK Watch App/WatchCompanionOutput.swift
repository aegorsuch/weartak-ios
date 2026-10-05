import Combine
import Foundation
import WatchConnectivity

@MainActor
final class WatchCompanionOutput: NSObject, ObservableObject, CoTOutput, WCSessionDelegate {
    @Published private(set) var configured = false
    @Published private(set) var isPhoneReachable = false
    @Published private(set) var serverReady = false
    @Published private(set) var status = "Configure on phone"
    @Published private(set) var channelServers: [TAKChannelServer] = []
    @Published private(set) var channelsLoading = false
    @Published private(set) var channelError: String?
    @Published private(set) var mapRefreshing = false
    @Published private(set) var mapRefreshError: String?
    @Published private(set) var mapLastChecked: Date?
    @Published private(set) var phoneReportingStatus: String?
    @Published private(set) var phoneLocationEnabled = false
    @Published private(set) var identitySyncError: String?
    var onStateChange: (() -> Void)?
    var onCoT: ((BridgeWire.Message) -> Void)?
    var onSourceRefresh: ((UUID, Int) -> Void)?
    var onBridgeRestart: (() -> Void)?
    var onMapSnapshot: (([CompanionMapEvent], [UUID]) -> Void)?
    private var sessionID: UUID?

    private let settings: AppSettings
    private var active = false
    #if DEBUG
    private(set) var isChannelPreview = false
    #endif
    private var lastConfirmation: Date?
    private var timer: Timer?
    private var selection: AnyCancellable?
    private var identitySubscription: AnyCancellable?
    private var publishedIdentity: WatchReportingIdentity?
    private var alertActive = false
    private var biometrics = WatchBiometrics()
    private var publishedBiometricsAt: Date?
    private var handshakeInFlight = false
    private var pending: [UUID: CheckedContinuation<BridgeWire.Message, Error>] = [:]
    private var timeouts: [UUID: Task<Void, Never>] = [:]

    /// Sit(x) streaming is relayed through Companion, so it uses the phone even when another TAK relay is selected.
    var sitxRelayRequested = false {
        didSet {
            guard oldValue != sitxRelayRequested else { return }
            publishIdentity()
            refresh()
        }
    }
    /// Companion's Sit(x) relay state: nil when unknown, empty when the phone holds no Sit(x) configuration.
    @Published private(set) var sitxRelayStatus: String?
    /// Sit(x) set up in Companion itself, reported through the phone's application context.
    private var phoneSitxSetUp = false {
        didSet {
            guard oldValue != phoneSitxSetUp else { return }
            publishIdentity()
            refresh()
        }
    }
    private var usesCompanion: Bool { settings.relayProvider == .companion || sitxRelayRequested || phoneSitxSetUp }

    var isReady: Bool {
        guard active, usesCompanion, serverReady else { return false }
        #if DEBUG
        if isChannelPreview { return true }
        #endif
        return WCSession.default.isReachable && lastConfirmation.map { Date().timeIntervalSince($0) < 15 } == true
    }

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        selection = settings.$relayProvider.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        identitySubscription = settings.objectWillChange
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.publishIdentity() }
            }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func setActive(_ active: Bool) {
        let resumed = active && !self.active
        self.active = active
        if resumed { mapLastChecked = nil }
        if !active { invalidate() }
        else { publishIdentity(); refresh() }
    }

    func setAlertActive(_ active: Bool) {
        guard alertActive != active else { return }
        alertActive = active
        publishIdentity()
    }

    /// Phone-GPS PLI carries these vitals; context updates are limited to about one per 30 s.
    func setBiometrics(_ biometrics: WatchBiometrics) {
        guard self.biometrics != biometrics else { return }
        self.biometrics = biometrics
        guard usesCompanion, publishedBiometricsAt.map({ Date().timeIntervalSince($0) >= 25 }) ?? true else { return }
        publishIdentity(force: true)
    }

    /// Shares this watch's TAK UID, callsign, team, role and reporting settings so Companion can report
    /// phone GPS as this same user. Application context is delivered even when Companion is not running.
    func publishIdentity(force: Bool = false) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let identity = WatchReportingIdentity(uid: SitxClient.deviceID(), callSign: settings.callSign,
            team: settings.teamColor.rawValue, role: settings.role,
            companionSelected: usesCompanion,
            constantStrategy: settings.reportingStrategy == .constant,
            constantInterval: settings.constantReportingInterval,
            stationaryInterval: settings.stationaryReportingInterval,
            onFootInterval: settings.onFootReportingInterval,
            vehicleInterval: settings.vehicleReportingInterval, issuedAt: Date(),
            alertingInterval: settings.alertingReportingInterval, alertActive: alertActive)
        if !force, let published = publishedIdentity, published.hasSameSettings(as: identity),
           identity.issuedAt.timeIntervalSince(published.issuedAt) < 3_600 { return }
        do {
            // Application context replaces the whole dictionary, so identity and vitals are always sent together.
            try WCSession.default.updateApplicationContext([
                WatchReportingIdentity.contextKey: identity.contextValue(),
                WatchBiometrics.contextKey: biometrics.contextValue(),
            ])
            publishedIdentity = identity
            publishedBiometricsAt = Date()
            identitySyncError = nil
        } catch {
            identitySyncError = "Unable to share watch identity with Companion: \(error.localizedDescription)"
        }
    }

    private func refresh() {
        let reachable = WCSession.isSupported() &&
            WCSession.default.activationState == .activated && WCSession.default.isReachable
        if isPhoneReachable != reachable { isPhoneReachable = reachable }
        guard active, usesCompanion, WCSession.default.activationState == .activated,
              WCSession.default.isReachable else {
            if active, usesCompanion {
                mapRefreshError = "Phone unavailable. Showing cached positions."
            }
            invalidate()
            return
        }
        if lastConfirmation.map({ Date().timeIntervalSince($0) >= 15 }) ?? true {
            serverReady = false
            phoneLocationEnabled = false
            onStateChange?()
        }
        guard !handshakeInFlight else { return }
        handshakeInFlight = true
        Task {
            defer { handshakeInFlight = false }
            do {
                let reply = try await request(BridgeWire.Message(kind: .hello))
                guard active else { return }
                guard reply.kind == .status else { throw TAKTransportError.notConfigured }
                apply(reply)
                if mapLastChecked.map({ Date().timeIntervalSince($0) >= 30 }) ?? true {
                    Task { await self.refreshMap() }
                }
            } catch {
                mapRefreshError = "Phone unavailable: \(error.localizedDescription)"
                invalidate()
            }
        }
    }

    func refreshMap() async {
        guard active, usesCompanion, !mapRefreshing else { return }
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else {
            mapRefreshError = "Phone unavailable. Showing cached positions."
            return
        }
        mapRefreshing = true
        mapRefreshError = nil
        defer { mapRefreshing = false }
        do {
            let reply = try await request(BridgeWire.Message(kind: .mapSnapshot), timeoutSeconds: 28)
            guard active else { return }
            guard reply.kind == .mapSnapshot, let events = reply.mapEvents,
                  let enabled = reply.enabledServerIDs else {
                throw CompanionRefreshFailure.message(reply.detail ?? "Update both WearTAK apps to refresh the map.")
            }
            apply(reply)
            onMapSnapshot?(events, enabled)
            mapLastChecked = Date()
            mapRefreshError = reply.refreshError
            if reply.snapshotTruncated == true {
                mapRefreshError = [mapRefreshError, "Map snapshot was size-limited; some contacts were omitted."]
                    .compactMap { $0 }.joined(separator: "\n")
            }
        } catch {
            mapRefreshError = "Map refresh failed: \(error.localizedDescription). Showing cached positions."
        }
    }

    private func apply(_ message: BridgeWire.Message) {
        applySession(message)
        if let configured = message.configured { self.configured = configured }
        serverReady = message.ready == true
        if let reporting = message.phoneReporting { phoneReportingStatus = reporting }
        phoneLocationEnabled = message.phoneLocationEnabled == true
        if let sitxStatus = message.sitxStatus { sitxRelayStatus = sitxStatus }
        lastConfirmation = Date()
        status = message.detail ?? (serverReady ? "Connected" : "Not connected")
        onStateChange?()
        for event in message.chatEvents ?? [] {
            onCoT?(BridgeWire.Message(kind: .cot, xml: event.xml, sourceServerID: event.sourceServerID,
                sourceGeneration: event.sourceGeneration, sessionID: message.sessionID))
        }
    }

    private func applySession(_ message: BridgeWire.Message) {
        guard let incoming = message.sessionID, incoming != sessionID else { return }
        sessionID = incoming
        channelServers = []
        onBridgeRestart?()
    }

    private func invalidate() {
        serverReady = false
        sitxRelayStatus = nil
        phoneLocationEnabled = false
        lastConfirmation = nil
        status = configured ? "Companion not connected" : "Configure on phone"
        for task in timeouts.values { task.cancel() }
        timeouts = [:]
        let waiting = pending.values
        pending = [:]
        for continuation in waiting { continuation.resume(throwing: TAKTransportError.notConfigured) }
        onStateChange?()
    }

    func send(_ xml: String) async throws {
        guard isReady else { throw TAKTransportError.notConfigured }
        let reply = try await request(BridgeWire.Message(kind: .cot, xml: xml))
        guard reply.kind == .acknowledgement, reply.ready == true else {
            if reply.kind == .status { apply(reply) }
            throw TAKTransportError.notConfigured
        }
    }

    /// Hands Sit(x) streaming to Companion (enabled) or takes it back (disabled; the reply may return the token).
    func sendSitxConfig(_ config: SitxRelayConfig) async throws -> BridgeWire.Message {
        let reply = try await request(BridgeWire.Message(kind: .sitxConfig, sitxConfig: config), timeoutSeconds: 20)
        guard reply.kind == .acknowledgement, reply.ready == true else {
            throw CompanionRefreshFailure.message(reply.detail ?? "Companion did not accept the Sit(x) settings.")
        }
        if let status = reply.sitxStatus { sitxRelayStatus = status }
        return reply
    }

    func sendChat(_ xml: String, serverID: UUID) async throws {
        guard isReady else { throw CompanionRefreshFailure.message("Companion is not connected to TAK.") }
        let reply = try await request(BridgeWire.Message(kind: .cot, xml: xml, serverID: serverID))
        guard reply.kind == .acknowledgement, reply.ready == true else {
            throw CompanionRefreshFailure.message(reply.detail ?? "The contact's TAK server did not accept the chat.")
        }
    }

    func refreshChannels(serverID: UUID? = nil) async {
        await channelRequest(BridgeWire.Message(kind: .channels, serverID: serverID))
    }

    func setChannel(serverID: UUID, bitPosition: Int, active: Bool) async {
        #if DEBUG
        if isChannelPreview {
            channelServers = channelServers.map { server in
                guard server.id == serverID else { return server }
                var updated = server
                updated.channels = server.channels.map { channel in
                    channel.bitPosition == bitPosition
                        ? TAKChannel(bitPosition: channel.bitPosition, name: channel.name, direction: channel.direction, active: active)
                        : channel
                }
                return updated
            }
            return
        }
        #endif
        await channelRequest(BridgeWire.Message(kind: .channelUpdate, serverID: serverID,
            channelBitPosition: bitPosition, channelActive: active, clientUID: SitxClient.deviceID()))
    }

    #if DEBUG
    func beginChannelPreview() {
        let id = UUID(uuidString: "E0B22F5E-4AC1-4BC4-A1CA-A47B6759C367")!
        isChannelPreview = true
        configured = true
        serverReady = true
        status = "Connected (Preview)"
        channelError = nil
        channelServers = [TAKChannelServer(id: id, name: "192.0.2.18:8089", channels: [
            TAKChannel(bitPosition: 0, name: "Operations", direction: "IN/OUT", active: true),
            TAKChannel(bitPosition: 1, name: "Command", direction: "IN/OUT", active: true),
            TAKChannel(bitPosition: 2, name: "Logistics", direction: "IN/OUT", active: false),
            TAKChannel(bitPosition: 3, name: "Medical", direction: "IN/OUT", active: false)
        ], state: "Ready")]
    }
    #endif

    private func channelRequest(_ message: BridgeWire.Message) async {
        guard !channelsLoading else { return }
        #if DEBUG
        if isChannelPreview { return }
        #endif
        guard isReady else {
            channelError = "Connect WearTAK Companion to a TAK server to configure channels."
            return
        }
        channelsLoading = true
        channelError = nil
        defer { channelsLoading = false }
        do {
            let reply = try await request(message, timeoutSeconds: 65)
            guard reply.kind == .channels, let servers = reply.channelServers else { throw TAKTransportError.notConfigured }
            applySession(reply)
            let previous = Dictionary(uniqueKeysWithValues: channelServers.map { ($0.id, $0) })
            channelServers = servers.map { server in
                if server.id != message.serverID, server.state == "Select server to load channels", let cached = previous[server.id] {
                    return cached
                }
                return server
            }
            if let id = reply.sourceServerID, let generation = reply.sourceGeneration {
                onSourceRefresh?(id, generation)
            }
            if let id = message.serverID { channelError = channelServers.first { $0.id == id }?.error }
        } catch {
            channelError = "Channel request failed: \(error.localizedDescription)"
        }
    }

    private func request(_ message: BridgeWire.Message, timeoutSeconds: Double = 12) async throws -> BridgeWire.Message {
        guard WCSession.default.isReachable else {
            throw CompanionRefreshFailure.message("The paired phone is unavailable for live messaging.")
        }
        guard pending.count < 16 else {
            throw CompanionRefreshFailure.message("Too many Companion requests are in progress.")
        }
        let data = try message.encoded()
        return try await withCheckedThrowingContinuation { continuation in
            pending[message.id] = continuation
            timeouts[message.id] = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(timeoutSeconds)) } catch { return }
                self?.finish(message.id, result: .failure(CompanionRefreshFailure.message(
                    "The phone did not reply within \(Int(timeoutSeconds)) seconds.")))
            }
            WCSession.default.sendMessageData(data, replyHandler: { [weak self] data in
                Task { @MainActor in
                    do {
                        let reply = try BridgeWire.Message.decode(data)
                        guard reply.id == message.id else { throw TAKTransportError.notConfigured }
                        self?.finish(message.id, result: .success(reply))
                    } catch { self?.finish(message.id, result: .failure(error)) }
                }
            }, errorHandler: { [weak self] error in
                Task { @MainActor in self?.finish(message.id, result: .failure(error)) }
            })
        }
    }

    private func finish(_ id: UUID, result: Result<BridgeWire.Message, Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let configured = session.receivedApplicationContext["WearTAKCompanion.serverConfigured"] as? Bool ?? false
        let sitxSetUp = session.receivedApplicationContext["WearTAKCompanion.sitxSetUp"] as? Bool ?? false
        Task { @MainActor [weak self] in
            self?.configured = configured
            self?.phoneSitxSetUp = sitxSetUp
            self?.publishIdentity(force: true)
            self?.refresh()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.refresh() }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        let configured = context["WearTAKCompanion.serverConfigured"] as? Bool
        let unavailable = context["WearTAKCompanion.serverReady"] as? Bool == false
        let sitxSetUp = context["WearTAKCompanion.sitxSetUp"] as? Bool ?? false
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let configured { self.configured = configured }
            self.phoneSitxSetUp = sitxSetUp
            if unavailable && !self.handshakeInFlight && !self.mapRefreshing { self.invalidate() }
            else { self.refresh() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData data: Data) {
        Task { @MainActor [weak self] in
            guard let self, self.active, let message = try? BridgeWire.Message.decode(data), message.kind == .status else { return }
            self.apply(message)
        }

    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData data: Data, replyHandler: @escaping (Data) -> Void) {
        Task { @MainActor [weak self] in
            guard let self, let message = try? BridgeWire.Message.decode(data) else { replyHandler(Data()); return }
            if message.kind == .cot, message.xml != nil, self.active, self.usesCompanion {
                self.applySession(message)
                self.onCoT?(message)
            }
            replyHandler((try? BridgeWire.Message(kind: .acknowledgement, id: message.id).encoded()) ?? Data())
        }
    }

    private enum CompanionRefreshFailure: LocalizedError {
        case message(String)
        var errorDescription: String? { switch self { case .message(let text): return text } }
    }
}