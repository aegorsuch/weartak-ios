import Combine
import Foundation
import OSLog
import WatchConnectivity
import UIKit

@MainActor
final class PhoneBridgeModel: NSObject, ObservableObject, WCSessionDelegate {
    private let chatLogger = Logger(subsystem: "com.aegorsuch.weartak", category: "GeoChat")
    private let reportingLogger = Logger(subsystem: "com.aegorsuch.weartak", category: "PhoneReporting")
    private let missionLogger = Logger(subsystem: "com.aegorsuch.weartak", category: "DataSync")
    private var lastReportingDiagnostic: String?
    @Published private(set) var servers: [CompanionServer] = []
    @Published private(set) var serverStates: [UUID: ServerState] = [:]
    @Published private(set) var status = "No servers configured"
    @Published private(set) var isWatchPaired = false
    @Published private(set) var watchSetupError: String?
    @Published private(set) var configured = false
    @Published private(set) var connected = false
    @Published private(set) var mapCacheError: String?
    @Published private(set) var phoneReporting = PhoneReportingStatus()

    struct ServerState {
        var configured = false
        var connected = false
        var detail = "Disabled"
    }

    struct PhoneReportingStatus {
        var running = false
        var state = "Not started"
        var detail: String?
        var identity: String?
        var permission = "Not requested"
        var interval: TimeInterval?
        var lastReportAt: Date?
        var suppressedWatchPLIs = 0
    }

    private var sessions: [UUID: CompanionServerSession] = [:]
    let sitx: CompanionSitxSession
    private var active = true
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundGeneration: UUID?
    private var backgroundDeadline: Task<Void, Never>?
    private var refreshInFlight = false
    private var mapCache = CompanionMapCache()
    private var chatBuffer = CompanionChatBuffer()
    private var lastMapEventReceivedAt: Date?
    private static let mapStorageKey = "WearTAK.companion.mapCache"
    // An active phone location session keeps Companion running, so server sessions stay up while it reports.
    private var canRelay: Bool { active || backgroundTask != .invalid || reporter.isRunning }
    private let reporter: PhoneLocationReporter
    private var watchIdentity: Result<WatchReportingIdentity, WatchReportingIdentity.Failure> = .failure(.missing)
    private var lastPhoneReportAt: Date?
    private var phoneReportsByServer: [UUID: Date] = [:]
    private var latestPhoneFix: PhoneLocationFix?
    private var phoneInterval = PhoneReportingPolicy.minimumInterval
    private var phoneSendInFlight = false
    private var evaluatingReporting = false
    private var requestedWhenInUse = false
    private var completedMessages: [UUID: Set<UUID>] = [:]
    private var completedOrder: [UUID] = []
    private var incomingInFlight = 0
    private var watchWritesInFlight = 0
    private var sourceGenerations: [UUID: Int] = [:]
    private let bridgeSessionID = UUID()
    private static let storageKey = "WearTAK.companion.servers"
    private let defaults: UserDefaults

    override convenience init() { self.init(defaults: .standard) }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        reporter = PhoneLocationReporter(defaults: defaults)
        sitx = CompanionSitxSession(defaults: defaults)
        super.init()
        if sitx.isConfigured { serverStates[SitxRelayConfig.serverID] = sitx.state }
        sitx.onState = { [weak self] state in
            guard let self else { return }
            let id = SitxRelayConfig.serverID
            let wasConnected = self.serverStates[id]?.connected == true
            if self.sitx.isConfigured { self.serverStates[id] = state } else { self.serverStates.removeValue(forKey: id) }
            if !self.sitx.isConfigured {
                self.mapCache.remove(sourceID: id)
                self.saveMapCache()
            }
            self.publishState()
            if state.connected, !wasConnected, let fix = self.latestPhoneFix { self.reportPhoneFix(fix) }
        }
        sitx.onCoT = { [weak self] xml in self?.forward(xml, sourceID: SitxRelayConfig.serverID) }
        reporter.onFix = { [weak self] fix in self?.reportPhoneFix(fix) }
        reporter.onAuthorizationChange = { [weak self] in self?.publishState() }
        reporter.onError = { [weak self] message in
            self?.phoneReporting.detail = message
            self?.reportingLogger.error("Phone GPS: \(message, privacy: .public)")
        }
        active = UIApplication.shared.applicationState == .active
        if let data = defaults.data(forKey: Self.mapStorageKey) {
            do {
                mapCache = try JSONDecoder().decode(CompanionMapCache.self, from: data)
                mapCache.resetGenerations()
                mapCache.prune()
            } catch { mapCacheError = "Unable to load cached map: \(error.localizedDescription)" }
        }
        do {
            if let data = defaults.data(forKey: Self.storageKey) {
                servers = try JSONDecoder().decode([CompanionServer].self, from: data)
            } else if let host = defaults.string(forKey: "WearTAK.bridge.host"), !host.isEmpty {
                let endpoint = try CompanionEndpoint.parse(address: host,
                    streamPort: defaults.string(forKey: "WearTAK.bridge.port") ?? "8089",
                    enrollmentPort: defaults.string(forKey: "WearTAK.bridge.enrollmentPort") ?? "8446")
                servers = [CompanionServer(endpoint: endpoint)]
                try persist(servers)
            }
            var checked: [CompanionServer] = []
            for record in servers {
                let endpoint = try CompanionEndpoint.parse(address: record.host, streamPort: "\(record.port)", enrollmentPort: "\(record.enrollmentPort)")
                checked = try CompanionServer.saving(CompanionServer(id: record.id, endpoint: endpoint,
                    enabled: record.enabled, streamTLSName: record.streamTLSName), into: checked)
            }
            servers = checked
            synchronize()
        } catch {
            servers = []
            status = "Unable to load server settings"
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func save(_ server: CompanionServer) throws {
        let updated = try CompanionServer.saving(server, into: servers)
        try persist(updated)
        let previous = servers.first { $0.id == server.id }
        servers = updated
        if let previous, previous.endpoint.key != server.endpoint.key {
            sessions.removeValue(forKey: server.id)?.stop()
            mapCache.remove(sourceID: server.id)
            sourceGenerations[server.id, default: 0] += 1
            try? CertificateStore.remove(endpoint: previous.endpoint.key)
        }
        synchronize()
    }

    func setEnabled(_ enabled: Bool, id: UUID) throws {
        guard var server = servers.first(where: { $0.id == id }) else { return }
        server.enabled = enabled
        try save(server)
    }

    func remove(id: UUID) throws {
        guard let server = servers.first(where: { $0.id == id }) else { return }
        sessions[server.id]?.stop()
        try CertificateStore.remove(endpoint: server.endpoint.key)
        let updated = servers.filter { $0.id != id }
        try persist(updated)
        sessions.removeValue(forKey: id)?.stop()
        servers = updated
        serverStates.removeValue(forKey: id)
        synchronize()
    }

    func setActive(_ active: Bool) {
        self.active = active
        if active {
            endBackgroundRefresh()
            reporter.refreshServicesEnabled()
        }
        synchronize()
    }

    /// Short, bounded time for one watch request. Not used while phone location reporting keeps Companion running.
    private func beginBackgroundRefresh() throws {
        guard !active, backgroundTask == .invalid, !reporter.isRunning else { return }
        let generation = UUID()
        backgroundGeneration = generation
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Watch TAK refresh") { [weak self] in
            Task { @MainActor in self?.endBackgroundRefresh(generation: generation) }
        }
        guard backgroundTask != .invalid else {
            backgroundGeneration = nil
            throw CompanionFailure.message("iOS could not grant time for a watch refresh. Open Companion on the phone.")
        }
        backgroundDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            self?.endBackgroundRefresh(generation: generation)
        }
        synchronize()
    }

    private func endBackgroundRefresh(generation: UUID? = nil) {
        if let generation, generation != backgroundGeneration { return }
        backgroundDeadline?.cancel()
        backgroundDeadline = nil
        let task = backgroundTask
        backgroundTask = .invalid
        backgroundGeneration = nil
        if !active { synchronize() }
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
    }

    private func saveMapCache() {
        do {
            defaults.set(try JSONEncoder().encode(mapCache), forKey: Self.mapStorageKey)
        } catch { mapCacheError = "Unable to cache map: \(error.localizedDescription)" }
    }

    private func persist(_ servers: [CompanionServer]) throws {
        defaults.set(try JSONEncoder().encode(servers), forKey: Self.storageKey)
    }

    private func synchronize() {
        let validIDs = Set(servers.map(\.id))
        mapCache.prune(enabledServerIDs: enabledSourceIDs)
        chatBuffer.prune(enabledServerIDs: enabledSourceIDs)
        saveMapCache()
        for id in Array(sessions.keys) where !validIDs.contains(id) { sessions.removeValue(forKey: id)?.stop() }
        for server in servers {
            let session: CompanionServerSession
            if let existing = sessions[server.id] { session = existing }
            else {
                session = CompanionServerSession()
                session.onState = { [weak self] state in
                    guard let self else { return }
                    let wasConnected = self.serverStates[server.id]?.connected == true
                    self.serverStates[server.id] = state
                    self.publishState()
                    // A stationary phone may not produce another fix, so report the cached one on (re)connect.
                    if state.connected, !wasConnected, let fix = self.latestPhoneFix {
                        self.reportPhoneFix(fix)
                    }
                }
                session.onCoT = { [weak self] xml in self?.forward(xml, sourceID: server.id) }
                session.onChannelsChanged = { [weak self] in
                    self?.sourceGenerations[server.id, default: 0] += 1
                    self?.mapCache.remove(sourceID: server.id)
                    self?.saveMapCache()
                }
                sessions[server.id] = session
            }
            session.configure(server, active: canRelay)
        }
        sitx.setActive(canRelay)
        publishState()
    }

    /// TAK server IDs plus the watch-provided Sit(x) relay, used to scope cached map and chat events.
    private var enabledSourceIDs: Set<UUID> {
        var ids = Set(servers.filter(\.enabled).map(\.id))
        if sitx.isConfigured { ids.insert(SitxRelayConfig.serverID) }
        return ids
    }

    /// Connected outputs (TAK servers and Sit(x)) keyed by source ID.
    private func readyOutputs() -> [UUID: (String) async throws -> Void] {
        let enabled = Set(servers.filter(\.enabled).map(\.id))
        var outputs: [UUID: (String) async throws -> Void] = [:]
        for (id, session) in sessions where enabled.contains(id) && session.state.connected {
            outputs[id] = { xml in try await session.send(xml) }
        }
        if sitx.isConfigured, sitx.state.connected {
            let sitx = self.sitx
            outputs[SitxRelayConfig.serverID] = { xml in try await sitx.send(xml) }
        }
        return outputs
    }

    private func applySitx(_ config: SitxRelayConfig) throws {
        try sitx.apply(config)
        serverStates[SitxRelayConfig.serverID] = sitx.isConfigured ? sitx.state : nil
        if !sitx.isConfigured { mapCache.remove(sourceID: SitxRelayConfig.serverID); saveMapCache() }
        publishState()
    }

    private var sitxStatusSummary: String? {
        sitx.isSetUp ? sitx.state.detail : nil
    }

    private func sourceName(_ id: UUID) -> String {
        if id == SitxRelayConfig.serverID { return "Sit(x)" }
        return servers.first { $0.id == id }?.host ?? "Server"
    }

    private func snapshot(id: UUID = UUID()) -> BridgeWire.Message {
        BridgeWire.Message(kind: .status, id: id, ready: canRelay && connected, configured: configured, detail: status,
                   sessionID: bridgeSessionID, phoneReporting: phoneReportingSummary,
                   phoneLocationEnabled: reporter.isRunning, sitxStatus: sitxStatusSummary ?? "")
    }

    private var phoneReportingSummary: String {
        guard phoneReporting.running else { return "Off - " + (phoneReporting.detail ?? phoneReporting.state) }
        return phoneReporting.state
    }

    /// Starts or stops phone GPS reporting from current servers, watch identity and location authorization.
    private func evaluateReporting() {
        guard !evaluatingReporting else { return }
        evaluatingReporting = true
        defer { evaluatingReporting = false }
        let wasRunning = reporter.isRunning
        if case .success(let identity) = watchIdentity {
            do { _ = try identity.validated() }
            catch let failure as WatchReportingIdentity.Failure { watchIdentity = .failure(failure) }
            catch { watchIdentity = .failure(.invalidField("identity payload")) }
        }
        let enabledConfigured = servers.filter { $0.enabled && serverStates[$0.id]?.configured == true }.count
            + (sitx.isConfigured ? 1 : 0)
        let decision = PhoneReportingGate.decide(enabledConfiguredServers: enabledConfigured, identity: watchIdentity,
            authorization: reporter.authorization, preciseLocation: reporter.preciseLocation,
            servicesEnabled: reporter.servicesEnabled, appActive: active, alreadyRunning: reporter.isRunning)
        switch decision {
        case .run:
            if !reporter.isRunning {
                lastPhoneReportAt = nil
                phoneReportsByServer = [:]
                latestPhoneFix = nil
                phoneReporting.lastReportAt = nil
                phoneReporting.detail = nil
                phoneReporting.state = "Waiting for phone GPS fix"
                reporter.start(appActive: active)
            }
        case .requestWhenInUse:
            reporter.stop()
            phoneReporting.state = "Requesting location permission"
            phoneReporting.detail = nil
            if !requestedWhenInUse {
                requestedWhenInUse = true
                reporter.requestWhenInUse()
            }
        case .blocked(let reason):
            reporter.stop()
            lastPhoneReportAt = nil
            phoneReportsByServer = [:]
            latestPhoneFix = nil
            phoneReporting.state = "Stopped"
            phoneReporting.detail = reason
            phoneReporting.interval = nil
        }
        phoneReporting.running = reporter.isRunning
        phoneReporting.permission = reporter.permissionSummary
        if case .success(let identity) = watchIdentity {
            phoneReporting.identity = "\(identity.resolvedCallSign) - \(identity.team) - \(identity.resolvedRole) (UID \(identity.uid.prefix(8)))"
        } else { phoneReporting.identity = nil }
        let diagnostic = "\(phoneReporting.state); \(phoneReporting.permission); \(phoneReporting.detail ?? "")"
        if diagnostic != lastReportingDiagnostic {
            lastReportingDiagnostic = diagnostic
            reportingLogger.notice("Phone reporting state: \(diagnostic, privacy: .public)")
        }
        if reporter.isRunning != wasRunning { synchronize() }
    }

    private func reportPhoneFix(_ fix: PhoneLocationFix) {
        guard reporter.isRunning, case .success(let identity) = watchIdentity else { return }
        latestPhoneFix = fix
        do { try PhoneReportingPolicy.validate(fix) }
        catch {
            phoneReporting.detail = error.localizedDescription
            reportingLogger.error("Phone GPS fix rejected: \(error.localizedDescription, privacy: .public)")
            return
        }
        let interval = PhoneReportingPolicy.interval(for: identity, speed: fix.speed)
        phoneInterval = interval
        phoneReporting.interval = interval
        guard !phoneSendInFlight, PhoneReportingPolicy.isDue(lastSentAt: lastPhoneReportAt, interval: interval) else { return }
        let ready = readyOutputs()
        guard !ready.isEmpty else {
            updatePhoneReportingState("Waiting for TAK server connection",
                detail: "No enabled TAK server is connected; Companion retries automatically.")
            return
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let biometrics = WatchBiometrics.decode(contextValue: WCSession.default.receivedApplicationContext[WatchBiometrics.contextKey])
        let xml = PhonePLI.event(identity: identity, fix: fix, interval: interval, appVersion: version,
                                 osVersion: "iOS \(UIDevice.current.systemVersion)",
                                 biometrics: biometrics ?? WatchBiometrics())
        phoneSendInFlight = true
        Task {
            defer {
                self.phoneSendInFlight = false
                if case .success(let current) = self.watchIdentity,
                   !current.hasSameSettings(as: identity),
                   let fix = self.latestPhoneFix {
                    self.reportPhoneFix(fix)
                }
            }
            var failures: [String] = []
            var delivered: [UUID: Date] = [:]
            for (id, send) in ready {
                do { try await send(xml); delivered[id] = Date() }
                catch { failures.append("\(self.sourceName(id)): \(error.localizedDescription)") }
            }
            guard self.reporter.isRunning, case .success(let current) = self.watchIdentity,
                  current.hasSameSettings(as: identity) else { return }
            self.phoneReportsByServer.merge(delivered) { _, latest in latest }
            if !delivered.isEmpty {
                self.reportingLogger.notice("Watch-identity PLI accepted by \(delivered.count) TAK server(s); vitals \((biometrics ?? WatchBiometrics()).fresh().remarks, privacy: .public)")
                self.lastPhoneReportAt = Date()
                self.phoneReporting.lastReportAt = self.lastPhoneReportAt
            }
            self.updatePhoneReportingState(!delivered.isEmpty ? "Reporting phone GPS" : "Report failed; reconnecting",
                detail: failures.isEmpty ? nil : failures.joined(separator: "\n"))
        }
    }

    private func updatePhoneReportingState(_ state: String, detail: String?) {
        phoneReporting.detail = detail
        guard phoneReporting.state != state else { return }
        phoneReporting.state = state
        publishState()
    }

    /// Accepts identity only from the activated session of a paired watch with WearTAK installed. WatchConnectivity
    /// persists that context per paired watch, so Companion keeps no separate copy that could outlive a watch switch.
    private func refreshWatchIdentity(contextValue: Data? = nil) {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isPaired,
              session.isWatchAppInstalled else {
            setWatchIdentity(.failure(.watchUnavailable))
            return
        }
        let value: Any? = contextValue ?? session.receivedApplicationContext[WatchReportingIdentity.contextKey]
        do {
            guard let identity = try WatchReportingIdentity.decode(contextValue: value) else {
                setWatchIdentity(.failure(.missing))
                return
            }
            setWatchIdentity(.success(try identity.validated()))
        } catch let failure as WatchReportingIdentity.Failure {
            setWatchIdentity(.failure(failure))
        } catch { setWatchIdentity(.failure(.invalidField("identity payload"))) }
    }

    private func setWatchIdentity(_ identity: Result<WatchReportingIdentity, WatchReportingIdentity.Failure>) {
        var settingsChanged = false
        if case .success(let new) = identity, case .success(let old) = watchIdentity, new.hasSameSettings(as: old) {
            watchIdentity = identity
        } else {
            watchIdentity = identity
            settingsChanged = true
            lastPhoneReportAt = nil
            phoneReportsByServer = [:]
        }
        publishState()
        if settingsChanged, let fix = latestPhoneFix {
            reportPhoneFix(fix)
        }
    }

    /// Drops the watch's own PLI only while the phone recently reported that same user. Alerts and points pass through.
    private func shouldSuppressWatchPLI(_ xml: String, serverID: UUID) -> Bool {
        guard let header = PhonePLI.header(xml), header.type == PhonePLI.type,
              case .success(let identity) = watchIdentity else { return false }
        guard header.uid == identity.uid else {
            setWatchIdentity(.failure(.mismatchedUID))
            return false
        }
        guard reporter.isRunning,
              PhoneReportingPolicy.canUsePhonePLI(lastPhoneReportAt: phoneReportsByServer[serverID],
                  latestFix: latestPhoneFix, interval: phoneInterval) else { return false }
        phoneReporting.suppressedWatchPLIs += 1
        return true
    }

    private func publishState() {
        evaluateReporting()
        configured = serverStates.values.contains { $0.configured }
        connected = canRelay && serverStates.values.contains { $0.connected }
        status = !canRelay ? "Waiting for watch refresh" : connected ? "Connected" : configured ? "No connected servers" : "Configure on phone"
        let session = WCSession.default
        isWatchPaired = WCSession.isSupported() && session.isPaired
        guard session.activationState == .activated else { return }
        let context: [String: Any] = [
            "WearTAKCompanion.serverConfigured": configured,
            "WearTAKCompanion.serverReady": canRelay && connected,
            "WearTAKCompanion.sitxSetUp": sitx.isSetUp
        ]
        do {
            try session.updateApplicationContext(context)
            watchSetupError = nil
        } catch {
            watchSetupError = "Unable to update watch setup state: \(error.localizedDescription)"
        }
        if session.isReachable, let data = try? snapshot().encoded() {
            session.sendMessageData(data, replyHandler: nil, errorHandler: { _ in })
        }
    }

    private func forward(_ xml: String, sourceID: UUID) {
        let event = CompanionMapEvent(xml: xml, sourceServerID: sourceID,
                                      sourceGeneration: sourceGenerations[sourceID, default: 0], receivedAt: Date())
        let isChat = event.header?.type == "b-t-f"
        if isChat { chatLogger.notice("Server GeoChat received") }
        if isChat, chatBuffer.receive(event) {
            chatLogger.warning("GeoChat buffer limit reached; oldest messages evicted")
        }
        if event.isValid { lastMapEventReceivedAt = event.receivedAt }
        mapCache.receive(event)
        saveMapCache()
        guard canRelay, connected, WCSession.default.isReachable, incomingInFlight < 16,
              let data = try? BridgeWire.Message(kind: .cot, xml: xml, sourceServerID: sourceID,
                  sourceGeneration: sourceGenerations[sourceID, default: 0], sessionID: bridgeSessionID).encoded() else {
            chatLogger.notice("CoT \(event.header?.type ?? "?", privacy: .public) not forwarded: relay=\(self.canRelay), connected=\(self.connected), reachable=\(WCSession.default.isReachable), inFlight=\(self.incomingInFlight)")
            return
        }
        incomingInFlight += 1
        WCSession.default.sendMessageData(data, replyHandler: { [weak self] _ in
            Task { @MainActor in
                self?.incomingInFlight = max(0, (self?.incomingInFlight ?? 1) - 1)
                if isChat { self?.chatLogger.notice("GeoChat acknowledged by watch bridge") }
            }
        }, errorHandler: { [weak self] error in
            Task { @MainActor in
                self?.incomingInFlight = max(0, (self?.incomingInFlight ?? 1) - 1)
                if isChat { self?.chatLogger.error("GeoChat bridge send failed: \(error.localizedDescription, privacy: .public)") }
            }
        })
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor [weak self] in self?.refreshWatchIdentity() }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.refreshWatchIdentity() }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let value = applicationContext[WatchReportingIdentity.contextKey] else { return }
        let data = value as? Data ?? Data()
        Task { @MainActor [weak self] in self?.refreshWatchIdentity(contextValue: data) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.publishState() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.setWatchIdentity(.failure(.watchUnavailable))
        }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data,
                            replyHandler: @escaping (Data) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var replyID = UUID()
            do {
                let message = try BridgeWire.Message.decode(messageData)
                replyID = message.id
                try self.beginBackgroundRefresh()
                if message.kind == .hello {
                    self.chatBuffer.prune(enabledServerIDs: self.enabledSourceIDs)
                    replyHandler(try self.chatBuffer.filling(self.snapshot(id: message.id)).encoded())
                    return
                }
                if message.kind == .sitxConfig, let config = message.sitxConfig {
                    var released: SitxRelayConfig?
                    if config.enabled {
                        try self.applySitx(config)
                    } else {
                        let token = await self.sitx.release()
                        released = SitxRelayConfig(enabled: false, host: config.host, flowTag: config.flowTag,
                                                   refreshToken: token)
                    }
                    replyHandler(try BridgeWire.Message(kind: .acknowledgement, id: message.id, ready: true,
                        sitxConfig: released, sitxStatus: self.sitxStatusSummary ?? "").encoded())
                    return
                }
                if message.kind == .mapSnapshot {
                    replyHandler(try await self.mapReply(to: message).encoded())
                    return
                }
                if message.kind == .channels || message.kind == .channelUpdate {
                    let reply = await self.channelReply(to: message)
                    replyHandler((try? reply.encoded()) ?? Data())
                    return
                }
                if message.kind == .missions || message.kind == .missionUpdate {
                    replyHandler(try await self.missionReply(to: message).encoded())
                    return
                }
                    guard message.kind == .cot, let xml = message.xml, self.canRelay, self.connected,
                        self.watchWritesInFlight < 16 else {
                    replyHandler(try self.snapshot(id: message.id).encoded())
                    return
                }
                self.watchWritesInFlight += 1
                defer { self.watchWritesInFlight -= 1 }
                var successful = self.completedMessages[message.id] ?? []
                var ready = self.readyOutputs()
                if let target = message.serverID {
                    // Directed CoT (for example GeoChat) goes only to its source server and is never broadcast.
                    guard self.enabledSourceIDs.contains(target), let send = ready[target] else {
                        throw CompanionFailure.message("The contact's TAK server is not connected. Message not sent.")
                    }
                    ready = [target: send]
                }
                for (id, send) in ready where !successful.contains(id) {
                    if self.shouldSuppressWatchPLI(xml, serverID: id) {
                        successful.insert(id)
                        continue
                    }
                    do { try await send(xml); successful.insert(id) }
                    catch { continue }
                }
                guard !successful.isEmpty else { throw CompanionFailure.message("No server accepted the relay write.") }
                if self.completedMessages[message.id] == nil { self.completedOrder.append(message.id) }
                self.completedMessages[message.id] = successful
                if self.completedOrder.count > 128 { self.completedMessages.removeValue(forKey: self.completedOrder.removeFirst()) }
                replyHandler(try BridgeWire.Message(kind: .acknowledgement, id: message.id, ready: true).encoded())
            } catch {
                replyHandler((try? BridgeWire.Message(kind: .status, id: replyID, ready: false,
                    detail: error.localizedDescription).encoded()) ?? Data())
            }
        }
    }

    private func mapReply(to message: BridgeWire.Message) async throws -> BridgeWire.Message {
        guard !refreshInFlight else {
            throw CompanionFailure.message("A map refresh is already in progress.")
        }
        refreshInFlight = true
        defer { refreshInFlight = false }
        let deadline = Date().addingTimeInterval(8)
        while canRelay, !connected, Date() < deadline,
              serverStates.values.contains(where: { $0.detail == "Connecting" }) {
            try await Task.sleep(for: .milliseconds(200))
        }
        var failures: [String] = []
        if let mapCacheError { failures.append(mapCacheError) }
        let enabled = servers.filter(\.enabled)
        if enabled.isEmpty, !sitx.isConfigured { failures.append("Enable a TAK server in Companion on the phone.") }
        for server in enabled where serverStates[server.id]?.connected != true {
            failures.append("\(server.host): \(serverStates[server.id]?.detail ?? "Disconnected")")
        }
        if sitx.isConfigured, !sitx.state.connected { failures.append("Sit(x): \(sitx.state.detail)") }
        let ready = enabled.compactMap { server -> (String, CompanionServerSession)? in
            guard let session = sessions[server.id], session.state.connected else { return nil }
            return (server.host, session)
        }
        await withTaskGroup(of: String?.self) { group in
            for (host, session) in ready {
                group.addTask { @MainActor in
                    do { try await session.refreshLatestSA(); return nil }
                    catch { return "\(host): \(error.localizedDescription)" }
                }
            }
            for await error in group { if let error { failures.append(error) } }
        }
        if !ready.isEmpty {
            let collectionStarted = Date()
            while canRelay, Date().timeIntervalSince(collectionStarted) < 4 {
                try await Task.sleep(for: .milliseconds(200))
                let quietSince = max(collectionStarted, lastMapEventReceivedAt ?? collectionStarted)
                if Date().timeIntervalSince(collectionStarted) >= 2,
                   Date().timeIntervalSince(quietSince) >= 1 { break }
            }
        }
        if !canRelay { failures.append("The phone's background refresh time expired.") }
        mapCache.prune(enabledServerIDs: enabledSourceIDs)
        saveMapCache()
        let reply = BridgeWire.Message(kind: .mapSnapshot, id: message.id, ready: connected,
            configured: configured, detail: status, sessionID: bridgeSessionID,
            enabledServerIDs: Array(enabledSourceIDs), refreshError: failures.isEmpty ? nil : failures.joined(separator: "\n"),
            phoneReporting: phoneReportingSummary, phoneLocationEnabled: reporter.isRunning, sitxStatus: sitxStatusSummary ?? "")
        return try mapCache.filling(reply)
    }

    private func channelReply(to message: BridgeWire.Message) async -> BridgeWire.Message {
        var snapshots = servers.filter(\.enabled).map { record in
            TAKChannelServer(id: record.id, name: "\(record.host):\(record.port)",
                             state: serverStates[record.id]?.connected == true ? "Select server to load channels" : "Server not connected")
        }
        guard let id = message.serverID else {
            return BridgeWire.Message(kind: .channels, id: message.id, channelServers: snapshots, sessionID: bridgeSessionID)
        }
        do {
            guard canRelay, let session = sessions[id], let index = snapshots.firstIndex(where: { $0.id == id }) else {
                throw CompanionFailure.message("This server is no longer enabled.")
            }
            let groups: TAKChannelGroups
            if message.kind == .channelUpdate {
                guard let bit = message.channelBitPosition, let enabled = message.channelActive,
                      let uid = message.clientUID, !uid.isEmpty else { throw CompanionFailure.message("Invalid channel selection.") }
                groups = try await session.updateChannel(bit: bit, active: enabled, clientUID: uid)
            } else { groups = try await session.loadChannels() }
            snapshots[index].channels = groups.channels
            snapshots[index].state = groups.channels.isEmpty ? "No channels assigned" : "Ready"
        } catch {
            if let index = snapshots.firstIndex(where: { $0.id == id }) {
                snapshots[index].state = "Channel request failed"
                snapshots[index].error = error.localizedDescription
            }
        }
        return BridgeWire.Message(kind: .channels, id: message.id, channelServers: snapshots,
                                  sourceServerID: id, sourceGeneration: sourceGenerations[id, default: 0], sessionID: bridgeSessionID)
    }
}

// MARK: - Data Sync

extension PhoneBridgeModel {
    private typealias MissionRequest = (_ path: String, _ method: String, _ query: [URLQueryItem]) async throws -> Data

    private static func missionSubscriptionsKey(_ id: UUID) -> String { "WearTAK.missions.subscribed.\(id.uuidString)" }

    private func subscribedMissions(_ id: UUID) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.missionSubscriptionsKey(id)) ?? [])
    }

    private func setSubscribedMissions(_ names: Set<String>, for id: UUID) {
        UserDefaults.standard.set(names.sorted(), forKey: Self.missionSubscriptionsKey(id))
    }

    private func missionRequester(for id: UUID) -> MissionRequest? {
        if id == SitxRelayConfig.serverID {
            guard sitx.isConfigured else { return nil }
            let sitx = self.sitx
            return { path, method, query in try await sitx.missionRequest(path: path, method: method, query: query) }
        }
        guard servers.contains(where: { $0.id == id && $0.enabled }), let session = sessions[id] else { return nil }
        return { path, method, query in try await session.missionRequest(path: path, method: method, query: query) }
    }

    /// Lists a server's Data Sync missions, applies a watch subscribe/unsubscribe, and loads the map items of
    /// subscribed missions. Subscriptions use the watch UID, the identity this phone streams to the server.
    fileprivate func missionReply(to message: BridgeWire.Message) async -> BridgeWire.Message {
        var snapshots = servers.filter(\.enabled).map { record in
            TAKMissionServer(id: record.id, name: "\(record.host):\(record.port)",
                             state: serverStates[record.id]?.connected == true ? TAKMissionServer.selectState : "Server not connected")
        }
        if sitx.isConfigured {
            snapshots.append(TAKMissionServer(id: SitxRelayConfig.serverID,
                name: "Sit(x) " + (sitx.selectedGroupName ?? sitx.host),
                state: sitx.state.connected ? TAKMissionServer.selectState : "Server not connected"))
        }
        var targets: [UUID] = []
        if let id = message.serverID { targets = [id] }
        else if message.missionSync == true { targets = snapshots.map(\.id).filter { !subscribedMissions($0).isEmpty } }
        var budget = TAKMissionAPI.maximumItemsTotal
        var removalError: String?
        for id in targets {
            guard let index = snapshots.firstIndex(where: { $0.id == id }) else { continue }
            do {
                guard canRelay, let request = missionRequester(for: id) else {
                    throw CompanionFailure.message("This server is no longer enabled.")
                }
                var names = subscribedMissions(id)
                if message.kind == .missionUpdate, id == message.serverID,
                   let name = message.missionName, let subscribe = message.missionSubscribe {
                    guard let uid = message.clientUID, !uid.isEmpty,
                          let path = TAKMissionAPI.path(name, "/subscription") else { throw TAKMissionAPI.Failure.invalidName }
                    _ = try await request(path, subscribe ? "PUT" : "DELETE", [URLQueryItem(name: "uid", value: uid)])
                    if subscribe { names.insert(name) } else { names.remove(name) }
                    setSubscribedMissions(names, for: id)
                    missionLogger.notice("Data Sync \(subscribe ? "subscribed to" : "unsubscribed from", privacy: .public) mission on \(snapshots[index].name, privacy: .public)")
                }
                if message.kind == .missionUpdate, id == message.serverID,
                   let name = message.missionName, let removeUID = message.missionRemoveUID {
                    guard let uid = message.clientUID, !uid.isEmpty,
                          let path = TAKMissionAPI.path(name, "/contents") else { throw TAKMissionAPI.Failure.invalidName }
                    do {
                        _ = try await request(path, "DELETE", [URLQueryItem(name: "uid", value: removeUID),
                                                                URLQueryItem(name: "creatorUid", value: uid)])
                        missionLogger.notice("Data Sync removed an item from a mission on \(snapshots[index].name, privacy: .public)")
                    } catch {
                        missionLogger.error("Data Sync item removal failed: \(error.localizedDescription, privacy: .public)")
                        removalError = TAKMissionAPI.removalMessage(error.localizedDescription)
                    }
                }
                var missions = try TAKMissionAPI.parseList(await request("/missions", "GET", []))
                let listed = Set(missions.map(\.name))
                if !names.isSubset(of: listed) {
                    names.formIntersection(listed)
                    setSubscribedMissions(names, for: id)
                }
                for i in missions.indices where names.contains(missions[i].name) {
                    missions[i].subscribed = true
                    if let uid = message.clientUID, !uid.isEmpty, let path = TAKMissionAPI.path(missions[i].name, "/subscription") {
                        missions[i].canEdit = (try? await request(path, "GET", [URLQueryItem(name: "uid", value: uid)]))
                            .flatMap(TAKMissionAPI.parseCanEdit)
                    }
                    guard budget > 0, let path = TAKMissionAPI.path(missions[i].name, "/cot") else {
                        missions[i].error = "Watch item limit reached."
                        continue
                    }
                    do {
                        let items = TAKMissionAPI.parseItems(try await request(path, "GET", []),
                                                             limit: min(budget, TAKMissionAPI.maximumItemsPerMission))
                        missions[i].items = items
                        budget -= items.count
                    } catch { missions[i].error = error.localizedDescription }
                }
                snapshots[index].missions = missions
                snapshots[index].state = missions.isEmpty ? TAKMissionServer.emptyState : TAKMissionServer.readyState
                let roles = missions.filter(\.subscribed).map { $0.canEdit.map { $0 ? "edit" : "read-only" } ?? "role unknown" }
                missionLogger.notice("Data Sync \(snapshots[index].name, privacy: .public): \(missions.count) mission(s), \(names.count) subscribed \(roles, privacy: .public)")
            } catch {
                snapshots[index].state = "Data Sync request failed"
                snapshots[index].error = error.localizedDescription
                missionLogger.error("Data Sync \(snapshots[index].name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        var reply = BridgeWire.Message(kind: .missions, id: message.id, sessionID: bridgeSessionID)
        reply.missionServers = snapshots
        reply.missionSync = message.missionSync
        reply.detail = removalError
        while (try? reply.encoded()) == nil {
            guard var servers = reply.missionServers,
                  let s = servers.indices.last(where: { servers[$0].missions.contains { !($0.items ?? []).isEmpty } }),
                  let m = servers[s].missions.indices.last(where: { !(servers[s].missions[$0].items ?? []).isEmpty }),
                  let count = servers[s].missions[m].items?.count else { break }
            servers[s].missions[m].items?.removeLast(max(1, count / 4))
            servers[s].missions[m].error = "Some items were omitted to fit the watch message size."
            reply.missionServers = servers
        }
        return reply
    }
}

@MainActor
private final class CompanionServerSession {
    var onState: ((PhoneBridgeModel.ServerState) -> Void)?
    var onCoT: ((String) -> Void)?
    var onChannelsChanged: (() -> Void)?
    private(set) var state = PhoneBridgeModel.ServerState()
    private let connection = TAKServerConnection()
    private var record: CompanionServer?
    private var active = true
    private var retryTask: Task<Void, Never>?
    private var channelClient: TAKChannelClient?

    init() {
        connection.onState = { [weak self] ready, detail in
            guard let self else { return }
            self.state.connected = ready
            self.state.detail = detail
            self.onState?(self.state)
            if ready { self.retryTask?.cancel(); self.retryTask = nil }
            else if detail != "Connecting" { self.retry() }
        }
        connection.onCoT = { [weak self] xml in self?.onCoT?(xml) }
    }

    func configure(_ record: CompanionServer, active: Bool) {
        let changed = self.record != record || self.active != active
        self.record = record
        self.active = active
        if changed { stop() }
        do {
            if let stored = try CertificateStore.read(endpoint: record.endpoint.key) {
                _ = try CertificateStore.resolve(stored)
                state.configured = true
            } else { state.configured = false }
            if !active { state.detail = "Paused in background" }
            else if !record.enabled { state.detail = "Disabled" }
            else if !state.configured { state.detail = "Configure certificate" }
            else if !connection.ready && state.detail != "Connecting" { connect() }
        } catch { state.configured = false; state.detail = error.localizedDescription }
        onState?(state)
    }

    private func connect() {
        guard let record, record.enabled, active, state.configured else { return }
        do {
            guard let stored = try CertificateStore.read(endpoint: record.endpoint.key) else { throw CompanionFailure.message("Certificate required.") }
            let ca = UserDefaults.standard.data(forKey: "WearTAK.bridge.serverCA.\(record.endpoint.key)")
            try connection.connect(endpoint: record.endpoint, identity: CertificateStore.resolve(stored),
                                   trustedCA: ca, streamTLSName: record.streamTLSName)
        } catch { state.detail = error.localizedDescription; state.connected = false; onState?(state) }
    }

    func stop() {
        retryTask?.cancel()
        retryTask = nil
        connection.disconnect()
        channelClient?.cancel()
        channelClient = nil
        state.connected = false
        state.detail = "Disabled"
        onState?(state)
    }

    private func retry() {
        guard record?.enabled == true, active, state.configured else { return }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.connect()
        }
    }

    func send(_ xml: String) async throws { try await connection.send(xml) }

    private func makeChannelClient() throws -> TAKChannelClient {
        guard active, state.connected, let record, record.enabled, channelClient == nil,
              let stored = try CertificateStore.read(endpoint: record.endpoint.key) else {
            throw CompanionFailure.message("Server disconnected or channel request already running.")
        }
        let ca = UserDefaults.standard.data(forKey: "WearTAK.bridge.serverCA.\(record.endpoint.key)")
        let client = TAKChannelClient(host: record.host, identity: try CertificateStore.resolve(stored), trustedCA: ca)
        channelClient = client
        return client
    }

    func loadChannels() async throws -> TAKChannelGroups {
        let client = try makeChannelClient()
        defer { client.cancel(); channelClient = nil }
        return try await client.load(checkSupport: true, sendLatestSA: true)
    }

    func refreshLatestSA() async throws {
        guard active, state.connected, let record,
              let stored = try CertificateStore.read(endpoint: record.endpoint.key) else {
            throw CompanionFailure.message("TAK server is not connected.")
        }
        let ca = UserDefaults.standard.data(forKey: "WearTAK.bridge.serverCA.\(record.endpoint.key)")
        let client = TAKChannelClient(host: record.host, identity: try CertificateStore.resolve(stored),
                                      trustedCA: ca, requestTimeout: 3)
        defer { client.cancel() }
        _ = try await client.load(checkSupport: false, sendLatestSA: true)
    }

    func missionRequest(path: String, method: String = "GET", query: [URLQueryItem] = []) async throws -> Data {
        guard active, state.connected, let record, record.enabled,
              let stored = try CertificateStore.read(endpoint: record.endpoint.key) else {
            throw CompanionFailure.message("TAK server is not connected.")
        }
        let ca = UserDefaults.standard.data(forKey: "WearTAK.bridge.serverCA.\(record.endpoint.key)")
        let client = TAKChannelClient(host: record.host, identity: try CertificateStore.resolve(stored),
                                      trustedCA: ca, requestTimeout: 20)
        defer { client.cancel() }
        return try await client.missionRequest(path: path, method: method, query: query)
    }

    func updateChannel(bit: Int, active: Bool, clientUID: String) async throws -> TAKChannelGroups {
        let client = try makeChannelClient()
        defer { client.cancel(); channelClient = nil }
        _ = try await client.update(bitPosition: bit, active: active, clientUID: clientUID)
        onChannelsChanged?()
        return try await client.load(checkSupport: false, sendLatestSA: true)
    }
}