import Combine
import Foundation
import WatchConnectivity
import UIKit

@MainActor
final class PhoneBridgeModel: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var servers: [CompanionServer] = []
    @Published private(set) var serverStates: [UUID: ServerState] = [:]
    @Published private(set) var status = "No servers configured"
    @Published private(set) var watchStatus = "Watch unavailable"
    @Published private(set) var configured = false
    @Published private(set) var connected = false
    @Published private(set) var mapCacheError: String?

    struct ServerState {
        var configured = false
        var connected = false
        var detail = "Disabled"
    }

    private var sessions: [UUID: CompanionServerSession] = [:]
    private var active = true
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundGeneration: UUID?
    private var backgroundDeadline: Task<Void, Never>?
    private var refreshInFlight = false
    private var mapCache = CompanionMapCache()
    private var lastMapEventReceivedAt: Date?
    private static let mapStorageKey = "WearTAK.companion.mapCache"
    private var canRelay: Bool { active || backgroundTask != .invalid }
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
        super.init()
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
                checked = try CompanionServer.saving(CompanionServer(id: record.id, endpoint: endpoint, enabled: record.enabled), into: checked)
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
        if active { endBackgroundRefresh() }
        synchronize()
    }

    private func beginBackgroundRefresh() throws {
        guard !active, backgroundTask == .invalid else { return }
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
        mapCache.prune(enabledServerIDs: Set(servers.filter(\.enabled).map(\.id)))
        saveMapCache()
        for id in Array(sessions.keys) where !validIDs.contains(id) { sessions.removeValue(forKey: id)?.stop() }
        for server in servers {
            let session: CompanionServerSession
            if let existing = sessions[server.id] { session = existing }
            else {
                session = CompanionServerSession()
                session.onState = { [weak self] state in
                    self?.serverStates[server.id] = state
                    self?.publishState()
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
        publishState()
    }

    private func snapshot(id: UUID = UUID()) -> BridgeWire.Message {
        BridgeWire.Message(kind: .status, id: id, ready: canRelay && connected, configured: configured, detail: status,
                   sessionID: bridgeSessionID)
    }

    private func publishState() {
        configured = serverStates.values.contains { $0.configured }
        connected = canRelay && serverStates.values.contains { $0.connected }
        status = !canRelay ? "Waiting for watch refresh" : connected ? "Connected" : configured ? "No connected servers" : "Configure on phone"
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let context: [String: Any] = [
            "WearTAKCompanion.serverConfigured": configured,
            "WearTAKCompanion.serverReady": canRelay && connected
        ]
        do { try session.updateApplicationContext(context) }
        catch { watchStatus = "Unable to update watch setup state" }
        watchStatus = session.isReachable ? "Available for live messages" : "Waiting for watch app"
        if session.isReachable, let data = try? snapshot().encoded() {
            session.sendMessageData(data, replyHandler: nil, errorHandler: { _ in })
        }
    }

    private func forward(_ xml: String, sourceID: UUID) {
        let event = CompanionMapEvent(xml: xml, sourceServerID: sourceID,
                                      sourceGeneration: sourceGenerations[sourceID, default: 0], receivedAt: Date())
        if event.isValid { lastMapEventReceivedAt = event.receivedAt }
        mapCache.receive(event)
        saveMapCache()
        guard canRelay, connected, WCSession.default.isReachable, incomingInFlight < 16,
              let data = try? BridgeWire.Message(kind: .cot, xml: xml, sourceServerID: sourceID,
                  sourceGeneration: sourceGenerations[sourceID, default: 0], sessionID: bridgeSessionID).encoded() else { return }
        incomingInFlight += 1
        WCSession.default.sendMessageData(data, replyHandler: { [weak self] _ in
            Task { @MainActor in self?.incomingInFlight = max(0, (self?.incomingInFlight ?? 1) - 1) }
        }, errorHandler: { [weak self] _ in
            Task { @MainActor in self?.incomingInFlight = max(0, (self?.incomingInFlight ?? 1) - 1) }
        })
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor [weak self] in self?.publishState() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.publishState() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.watchStatus = "Watch session inactive" }
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
                    replyHandler(try self.snapshot(id: message.id).encoded())
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
                    guard message.kind == .cot, let xml = message.xml, self.canRelay, self.connected,
                        self.watchWritesInFlight < 16 else {
                    replyHandler(try self.snapshot(id: message.id).encoded())
                    return
                }
                self.watchWritesInFlight += 1
                defer { self.watchWritesInFlight -= 1 }
                var successful = self.completedMessages[message.id] ?? []
                let ready = self.sessions.filter { $0.value.state.connected }
                for (id, server) in ready where !successful.contains(id) {
                    do { try await server.send(xml); successful.insert(id) }
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
        if enabled.isEmpty { failures.append("Enable a TAK server in Companion on the phone.") }
        for server in enabled where serverStates[server.id]?.connected != true {
            failures.append("\(server.host): \(serverStates[server.id]?.detail ?? "Disconnected")")
        }
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
        mapCache.prune(enabledServerIDs: Set(enabled.map(\.id)))
        saveMapCache()
        let reply = BridgeWire.Message(kind: .mapSnapshot, id: message.id, ready: connected,
            configured: configured, detail: status, sessionID: bridgeSessionID,
            enabledServerIDs: enabled.map(\.id), refreshError: failures.isEmpty ? nil : failures.joined(separator: "\n"))
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
            try connection.connect(endpoint: record.endpoint, identity: CertificateStore.resolve(stored), trustedCA: ca)
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

    func updateChannel(bit: Int, active: Bool, clientUID: String) async throws -> TAKChannelGroups {
        let client = try makeChannelClient()
        defer { client.cancel(); channelClient = nil }
        _ = try await client.update(bitPosition: bit, active: active, clientUID: clientUID)
        onChannelsChanged?()
        return try await client.load(checkSupport: false, sendLatestSA: true)
    }
}