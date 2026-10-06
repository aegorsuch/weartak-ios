import Combine
import CoreLocation
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
    @Published private(set) var missionServers: [TAKMissionServer] = []
    @Published private(set) var missionsLoading = false
    @Published private(set) var missionError: String?
    @Published private(set) var mapRefreshing = false
    @Published private(set) var mapRefreshError: String?
    @Published private(set) var mapLastChecked: Date?
    @Published private(set) var phoneReportingStatus: String?
    @Published private(set) var phoneLocationEnabled = false
    @Published private(set) var identitySyncError: String?
    /// Display state for the phone link; `isReady` stays strict for sending.
    @Published private(set) var linkState: CompanionLinkState = .disconnected
    private var lastHealthy: Date?
    private var checkingSince: Date?
    private var pauseReason: String?
    var onStateChange: (() -> Void)?
    var onCoT: ((BridgeWire.Message) -> Void)?
    var onSourceRefresh: ((UUID, Int) -> Void)?
    var onBridgeRestart: (() -> Void)?
    var onMapSnapshot: (([CompanionMapEvent], [UUID]) -> Void)?
    /// A server's mission list loaded; its subscribed missions carry their current map items.
    var onMissions: ((TAKMissionServer) -> Void)?
    /// The watch position sent with Data Sync requests so oversized missions keep their nearest items.
    var currentCoordinate: (() -> CLLocationCoordinate2D?)?
    private var missionRequestInFlight = false
    private var lastMissionRemovalError: String?
    private var lastMissionSync: Date?
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
    @Published private(set) var sitxSettings: SitxSettingsSnapshot?
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
        if resumed { mapLastChecked = nil; checkingSince = Date() }
        if !active { checkingSince = nil; invalidate() }
        else { publishIdentity(); refresh() }
    }

    private func updateLinkState() {
        guard active, usesCompanion else {
            lastHealthy = nil
            checkingSince = nil
            pauseReason = nil
            if linkState != .disconnected { linkState = .disconnected }
            return
        }
        let state = CompanionLinkState.resolve(ready: isReady, pauseReason: pauseReason,
            lastHealthy: lastHealthy, checkingSince: checkingSince)
        if linkState != state { linkState = state }
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
                // Brief reachability drops (phone locked or set down) keep state during the grace period.
                if let lastHealthy, Date().timeIntervalSince(lastHealthy) < CompanionLinkState.graceSeconds {
                    status = "Reconnecting to phone…"
                    onStateChange?()
                    updateLinkState()
                    return
                }
            }
            invalidate()
            return
        }
        if lastConfirmation.map({ Date().timeIntervalSince($0) >= 15 }) ?? true {
            serverReady = false
            phoneLocationEnabled = false
            onStateChange?()
        }
        updateLinkState()
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
                checkingSince = nil
                if let lastHealthy, Date().timeIntervalSince(lastHealthy) < CompanionLinkState.graceSeconds {
                    serverReady = false
                    status = "Reconnecting to phone…"
                    onStateChange?()
                    updateLinkState()
                } else {
                    invalidate()
                }
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
            Task { await self.syncMissions() }
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
        if let settings = message.sitxSettings { sitxSettings = settings }
        lastConfirmation = Date()
        pauseReason = serverReady ? nil : message.relayPaused
        checkingSince = nil
        if serverReady { lastHealthy = lastConfirmation }
        else if pauseReason == nil { lastHealthy = nil }
        status = message.detail ?? (serverReady ? "Connected" : "Not connected")
        onStateChange?()
        updateLinkState()
        for event in message.chatEvents ?? [] {
            onCoT?(BridgeWire.Message(kind: .cot, xml: event.xml, sourceServerID: event.sourceServerID,
                sourceGeneration: event.sourceGeneration, sessionID: message.sessionID))
        }
    }

    private func applySitxSettingsContext(_ context: [String: Any]) {
        guard let data = context[SitxSettingsSnapshot.contextKey] as? Data else { return }
        do {
            sitxSettings = try JSONDecoder().decode(SitxSettingsSnapshot.self, from: data)
        } catch {
            sitxRelayStatus = "Sit(x) settings sync failed: \(error.localizedDescription)"
        }
    }

    #if DEBUG && targetEnvironment(simulator)
    func receiveLoadTestMessage(_ data: Data) throws {
        let message = try BridgeWire.Message.decode(data)
        guard message.kind == .cot else { throw BridgeWire.Failure.invalidCoT }
        applySession(message)
        onCoT?(message)
    }
    #endif

    private func applySession(_ message: BridgeWire.Message) {
        guard let incoming = message.sessionID, incoming != sessionID else { return }
        sessionID = incoming
        channelServers = []
        missionServers = []
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
        updateLinkState()
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
        if let settings = reply.sitxSettings { sitxSettings = settings }
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

    func refreshMissions(serverID: UUID? = nil) async {
        await missionRequest(BridgeWire.Message(kind: .missions, serverID: serverID, clientUID: SitxClient.deviceID()))
    }

    func setMission(serverID: UUID, name: String, subscribed: Bool) async {
        await missionRequest(BridgeWire.Message(kind: .missionUpdate, serverID: serverID, clientUID: SitxClient.deviceID(),
                                                missionName: name, missionSubscribe: subscribed))
    }

    /// Removes an item from a mission on the server; returns an error to show, or nil on success.
    func removeMissionItem(serverID: UUID, mission: String, uid: String) async -> String? {
        var message = BridgeWire.Message(kind: .missionUpdate, serverID: serverID, clientUID: SitxClient.deviceID(),
                                         missionName: mission)
        message.missionRemoveUID = uid
        return await missionRequest(message, quiet: true) ?? lastMissionRemovalError
    }

    /// Sends CoT to one server only (for example a Data Sync item update to its mission's server).
    func send(_ xml: String, serverID: UUID) async throws {
        guard isReady else { throw CompanionRefreshFailure.message("Companion is not connected to TAK.") }
        let reply = try await request(BridgeWire.Message(kind: .cot, xml: xml, serverID: serverID))
        guard reply.kind == .acknowledgement, reply.ready == true else {
            throw CompanionRefreshFailure.message(reply.detail ?? "The mission's TAK server did not accept the update.")
        }
    }

    /// Quietly reloads subscribed missions (adds, moves and removals) at most once a minute.
    func syncMissions(hasSubscriptions: Bool = UserDefaults.standard.bool(forKey: WatchSessionModel.missionSubscriptionsFlagKey)) async {
        guard hasSubscriptions, lastMissionSync.map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return }
        await missionRequest(BridgeWire.Message(kind: .missions, clientUID: SitxClient.deviceID(), missionSync: true), quiet: true)
    }

    /// Returns an error description when the request could not run or failed; nil on success.
    @discardableResult
    private func missionRequest(_ message: BridgeWire.Message, quiet: Bool = false) async -> String? {
        var message = message
        if let coordinate = currentCoordinate?() {
            message.latitude = coordinate.latitude
            message.longitude = coordinate.longitude
        }
        lastMissionRemovalError = nil
        guard !missionRequestInFlight else { return "Data Sync is busy. Try again." }
        guard isReady else {
            let error = "Connect WearTAK Companion to a TAK server to use Data Sync."
            if !quiet { missionError = error }
            return error
        }
        missionRequestInFlight = true
        if !quiet {
            missionsLoading = true
            missionError = nil
        }
        defer {
            missionRequestInFlight = false
            missionsLoading = false
        }
        do {
            let reply = try await request(message, timeoutSeconds: 65)
            guard reply.kind == .missions, var servers = reply.missionServers else {
                throw CompanionRefreshFailure.message(reply.detail ?? "Update both WearTAK apps to use Data Sync.")
            }
            applySession(reply)
            await pageMissionItems(into: &servers)
            lastMissionSync = Date()
            let previous = Dictionary(uniqueKeysWithValues: missionServers.map { ($0.id, $0) })
            missionServers = servers.map { server in
                if server.state == TAKMissionServer.selectState, let cached = previous[server.id], cached.isLoaded { return cached }
                return server
            }
            for server in servers where server.isLoaded { onMissions?(server) }
            if !quiet, let id = message.serverID { missionError = servers.first { $0.id == id }?.error }
            if message.missionRemoveUID != nil {
                lastMissionRemovalError = reply.detail
                    ?? message.serverID.flatMap { id in servers.first { $0.id == id }?.error }
            }
            return nil
        } catch {
            let text = "Data Sync request failed: \(error.localizedDescription)"
            if !quiet { missionError = text }
            return text
        }
    }

    /// Fetches mission items that did not fit in the mission reply, one message-sized page at a time.
    private func pageMissionItems(into servers: inout [TAKMissionServer]) async {
        for s in servers.indices where servers[s].isLoaded {
            for m in servers[s].missions.indices {
                guard var items = servers[s].missions[m].items, let total = servers[s].missions[m].itemTotal,
                      items.count < total else { continue }
                var page = BridgeWire.Message(kind: .missions, serverID: servers[s].id)
                page.missionName = servers[s].missions[m].name
                while items.count < total {
                    page.id = UUID()
                    page.missionItemOffset = items.count
                    guard let reply = try? await request(page, timeoutSeconds: 20),
                          reply.missionItemOffset == items.count, let next = reply.missionItems, !next.isEmpty else { break }
                    items += next.prefix(total - items.count)
                }
                if items.count < total {
                    servers[s].missions[m].error = "Loaded \(items.count) of \(total) items; the rest load on the next sync."
                }
                servers[s].missions[m].items = items
            }
        }
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
            self?.applySitxSettingsContext(session.receivedApplicationContext)
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
        let paused = context["WearTAKCompanion.relayPaused"] as? String
        let sitxSetUp = context["WearTAKCompanion.sitxSetUp"] as? Bool ?? false
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let configured { self.configured = configured }
            self.applySitxSettingsContext(context)
            self.phoneSitxSetUp = sitxSetUp
            if unavailable && !self.handshakeInFlight && !self.mapRefreshing {
                self.pauseReason = paused.map { String($0.prefix(200)) }
                if paused == nil { self.lastHealthy = nil }
                self.invalidate()
                if self.pauseReason != nil { self.status = "Phone paused in background" }
            }
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