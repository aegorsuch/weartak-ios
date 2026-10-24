import Combine
import Foundation
import CryptoKit
import HealthKit
import OSLog
import WatchConnectivity
import UIKit

@MainActor
final class PhoneBridgeModel: NSObject, ObservableObject, WCSessionDelegate, WearTAKGarminDelegate {
    enum WatchRoute: String, CaseIterable, Identifiable {
        case apple, garmin
        var id: String { rawValue }
        var title: String { self == .apple ? "Apple Watch" : "Garmin Connect IQ" }
    }
    private let chatLogger = Logger(subsystem: "com.aegorsuch.weartak", category: "GeoChat")
    private let reportingLogger = Logger(subsystem: "com.aegorsuch.weartak", category: "PhoneReporting")
    private let missionLogger = Logger(subsystem: "com.aegorsuch.weartak", category: "DataSync")
    private var lastReportingDiagnostic: String?
    @Published private(set) var servers: [CompanionServer] = []
    @Published private(set) var serverStates: [UUID: ServerState] = [:]
    @Published private(set) var status = String(localized: "No servers configured", table: "PhoneBridgeStatus")
    @Published private(set) var isWatchPaired = false
    @Published private(set) var watchSetupError: String?
    @Published private(set) var watchRoute: WatchRoute
    @Published private(set) var configured = false
    @Published private(set) var connected = false
    @Published private(set) var dittoStatus = DittoBridgeStatus(enabled: false, source: .community,
        state: .off, detail: "Ditto sync is off.")
    @Published private(set) var mapCacheError: String?
    @Published private(set) var tlsDiscoveryError: String?
    @Published private(set) var garminStatus = "Choose a Garmin watch in Garmin Connect."
    @Published private(set) var garminDevices: [[String: String]] = []
    @Published private(set) var garminDeviceID: String?
    @Published private(set) var garminReady = false
    @Published private(set) var userMetrics = UserMetrics(source: "Manual entry", measuredAt: nil)
    @Published private(set) var importedMetricsSource: String?
    private var tlsWaiters: [String: [CheckedContinuation<Void, Error>]] = [:]
    private var tlsDiscoveryTasks: [String: Task<Void, Never>] = [:]
    private var failedTLSDiscoveries = Set<String>()
    @Published private(set) var phoneReporting = PhoneReportingStatus()
    /// Non-nil when location settings will let the watch's TAK link drop while the phone is locked.
    @Published private(set) var backgroundAdvice: String?
    @Published var developerMode: Bool {
        didSet {
            developerModeTaps = 0
            defaults.set(developerMode, forKey: Self.developerModeKey)
        }
    }
    @Published var adminLockEnabled: Bool {
        didSet { defaults.set(adminLockEnabled, forKey: Self.adminLockKey) }
    }
    private var developerModeTaps = 0

    struct ServerState {
        var configured = false
        var connected = false
        var detail = String(localized: "Disabled", table: "PhoneBridgeStatus")
        var connectedSince: Date?
        var certificateExpires: Date?
        var lastError: String?
        var lastErrorAt: Date?
    }

    struct PhoneReportingStatus {
        var running = false
        var state = String(localized: "Not started", table: "PhoneBridgeStatus")
        var detail: String?
        var identity: String?
        var permission = String(localized: "Not requested", table: "PhoneBridgeStatus")
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
    private lazy var mapCacheWrites = MapCacheWriteBatcher { [weak self] in self?.saveMapCache() }
    /// Last loaded items per subscribed mission (key: server ID + name), paged to the watch after a mission reply.
    fileprivate var missionItemPages: [String: [TAKMissionItem]] = [:]
    private var chatBuffer = CompanionChatBuffer()
    private var lastMapEventReceivedAt: Date?
    private static let mapStorageKey = "WearTAK.companion.mapCache"
    private static let developerModeKey = "WearTAK.companion.developerMode"
    private static let adminLockKey = "WearTAK.companion.adminLock"
    // An active phone location session keeps Companion running, so server sessions stay up while it reports.
    private var canRelay: Bool { active || backgroundTask != .invalid || reporter.isRunning }
    private let reporter: PhoneLocationReporter
    private let dittoRuntime: DittoPeerRuntime
    private var watchIdentity: Result<WatchReportingIdentity, WatchReportingIdentity.Failure> = .failure(.missing)
    private var lastPhoneReportAt: Date?
    private var phoneReportsByServer: [UUID: Date] = [:]
    private var latestPhoneFix: PhoneLocationFix?
    private var alertLocations = AlertLocationHistory()
    private struct ActivePhoneEmergency {
        let xml: String
        let ownUID: String
        var lastFixAt: Date?
    }
    private var activePhoneEmergencies: [String: ActivePhoneEmergency] = [:]
    private var refreshingPhoneEmergencies = false
    private var pendingGarminEmergencies: [String: GarminEnvelope] = [:]
    private var garminEmergencyRetries = Set<String>()
    private var garminEventTasks: [UUID: Task<BridgeWire.Message, Error>] = [:]
    private var selfPositionRequestedAt: Date?
    private var pendingGarminMarkers: [String: (envelope: GarminEnvelope, requestedAt: Date)] = [:]
    private var garminMarkerUpdates = Set<String>()
    private var phoneInterval = PhoneReportingPolicy.minimumInterval
    private var phoneSendInFlight = false
    private var phoneDittoTrackInFlight = false
    private var lastPhoneDittoTrackAt: Date?
    private var evaluatingReporting = false
    private var requestedWhenInUse = false
    private var relayReceipts = CoTRelayReceiptLedger()
    private var relayWritesInFlight = Set<UUID>()
    private static let relayReceiptsKey = "WearTAK.companion.relayReceipts"
    private var incomingInFlight = 0
    private var watchWritesInFlight = 0
    private var sourceGenerations: [UUID: Int] = [:]
    private let bridgeSessionID = UUID()
    private static let storageKey = "WearTAK.companion.servers"
    private static let watchRouteKey = "WearTAK.companion.watchRoute"
    private static let userMetricsKey = "WearTAK.companion.userMetrics"
    private let defaults: UserDefaults
    private let healthStore = HKHealthStore()
    private var garmin: WearTAKGarmin?
    private var garminGeneration = UUID()
    private var garminConnectionToken: String?
    private var garminIdentity: WatchReportingIdentity?
    private var garminBiometrics = WatchBiometrics(batdokCotEnabled: false)
    private var garminChannelServers: [UUID] = []
    private var garminQueue: [GarminEnvelope] = []
    private var garminSending = false
    private var garminMetricsRequestID: String?
    private var garminMetricsPreview: UserMetrics?
    private var garminMetricsError: String?
    private var garminLedger = GarminDeliveryLedger()
    private var garminLedgerError: String?
    private var garminWrites = Set<UUID>()
    private var garminReceivesInFlight = 0
    private var garminRoutes = GarminRouteStore()
    @Published private(set) var navigationRoutes: [GarminRoute] = []
    @Published private(set) var routeNavigationState: RouteNavigationState?
    @Published private(set) var routeNavigationError: String?
    @Published private(set) var navigationLocation: GarminRoute.Point?
    private var navigationFixDate: Date?
    private var navigationAccuracyMeters = 0.0
    private var routeNavigation = RouteNavigationReplica()
    private var routePackageInFlight = Set<UUID>()
    private var routePackageAttempts: [UUID: Date] = [:]
    private var routePackageError: String?
    private lazy var appleRouteWrites = MapCacheWriteBatcher { [weak self] in self?.sendAppleRoutes() }
    private var garminRouteVersion: Int?
    private var garminSitxRouteConfig: CompanionSitxSession.Config?
    private static let garminRoutesStorageKey = "WearTAK.companion.garminRoutes"

    override convenience init() { self.init(defaults: .standard) }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        watchRoute = WatchRoute(rawValue: defaults.string(forKey: Self.watchRouteKey) ?? "") ?? .apple
        developerMode = defaults.bool(forKey: Self.developerModeKey)
        adminLockEnabled = defaults.bool(forKey: Self.adminLockKey)
        reporter = PhoneLocationReporter(defaults: defaults)
        dittoRuntime = DittoPeerRuntime(defaults: defaults,
            communityPDL: Bundle.main.object(forInfoDictionaryKey: "DITTO_COMMUNITY_PDL") as? String,
            pdlStore: SecurePDLStore(service: "com.aegorsuch.weartak.ditto"))
        sitx = CompanionSitxSession(defaults: defaults)
        super.init()
        if let data = defaults.data(forKey: AlertLocationHistory.storageKey) {
            do { alertLocations.receive(try JSONDecoder().decode(PhoneLocationFix.self, from: data)) }
            catch { reportingLogger.error("Last-known GPS could not be restored: \(error.localizedDescription, privacy: .public)") }
        }
        if let data = defaults.data(forKey: Self.relayReceiptsKey) {
            do {
                relayReceipts = try JSONDecoder().decode(CoTRelayReceiptLedger.self, from: data)
            } catch {
                reportingLogger.error("Relay receipts could not be restored: \(error.localizedDescription, privacy: .public)")
            }
        }
        garminSitxRouteConfig = sitx.config
        if let data = defaults.data(forKey: Self.garminRoutesStorageKey) {
            do {
                guard data.count <= 100_000 else { throw GarminRoute.Failure.capacity }
                let saved = try JSONDecoder().decode(GarminRouteStore.self, from: data)
                garminRoutes = try saved.validated()
            } catch {
                routePackageError = "Saved routes could not be loaded: \(error.localizedDescription)"
                chatLogger.error("Saved routes could not be loaded: \(error.localizedDescription, privacy: .public)")
            }
            navigationRoutes = garminRoutes.routes
            if let data = defaults.data(forKey: RouteNavigationState.storageKey) { receiveRouteNavigation(data) }
        }
        dittoRuntime.onStatusChange = { [weak self] status in
            guard let self else { return }
            self.dittoStatus = status
            self.publishState()
        }
        dittoRuntime.ownUID = {
            try? WatchReportingIdentity.decode(
                contextValue: WCSession.default.receivedApplicationContext[WatchReportingIdentity.contextKey])?.uid
        }
        dittoRuntime.onEvent = { [weak self] xml in self?.receiveDitto(xml) }
        do {
            let url = try GarminDeliveryLedger.storageURL()
            if FileManager.default.fileExists(atPath: url.path) {
                garminLedger = try JSONDecoder().decode(GarminDeliveryLedger.self, from: Data(contentsOf: url))
            }
        } catch {
            garminLedgerError = "Unable to load Garmin delivery records: \(error.localizedDescription)"
            garminStatus = garminLedgerError ?? error.localizedDescription
        }
        if let data = defaults.data(forKey: Self.userMetricsKey),
           let stored = try? JSONDecoder().decode(UserMetrics.self, from: data) {
            userMetrics = stored
            importedMetricsSource = stored.source
        }
        if sitx.isConfigured { serverStates[SitxRelayConfig.serverID] = sitx.state }
        sitx.onState = { [weak self] state in
            guard let self else { return }
            let id = SitxRelayConfig.serverID
            let wasConnected = self.serverStates[id]?.connected == true
            if self.garminSitxRouteConfig != self.sitx.config {
                self.garminSitxRouteConfig = self.sitx.config
                self.sourceGenerations[id, default: 0] += 1
                try? self.updateGarminRoutes { $0.removeServer(id.uuidString) }
            }
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
            if self?.routeNavigationState?.phase == .active { self?.routeNavigationError = message }
            self?.reportingLogger.error("Phone GPS: \(message, privacy: .public)")
        }
        active = UIApplication.shared.applicationState == .active
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.dittoRuntime.restore(isForeground: self.active)
        }
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
                    enabled: record.enabled, streamTLSName: record.streamTLSName,
                    apiTLSName: record.apiTLSName, name: record.name), into: checked)
            }
            servers = checked
            synchronize()
        } catch {
            servers = []
            try? updateGarminRoutes { $0.retainServers(Set(enabledSourceIDs.map(\.uuidString))) }
            status = String(localized: "Unable to load server settings", table: "PhoneBridgeStatus")
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        if watchRoute == .garmin { startGarmin() }
    }

    func selectWatchRoute(_ route: WatchRoute) {
        guard route != watchRoute else { return }
        stopRouteNavigation()
        watchRoute = route
        defaults.set(route.rawValue, forKey: Self.watchRouteKey)
        garmin?.stop()
        garmin = nil
        garminGeneration = UUID()
        garminIdentity = nil
        garminBiometrics = WatchBiometrics(batdokCotEnabled: false)
        garminChannelServers = []
        garminQueue = []
        garminSending = false
        garminRouteVersion = nil
        garminReady = false
        garminMetricsRequestID = nil
        garminMetricsPreview = nil
        garminMetricsError = nil
        if route == .garmin {
            setWatchIdentity(.failure(.missing))
            startGarmin()
        } else {
            refreshWatchIdentity()
        }
        publishState()
    }

    var routeLocation: GarminRoute.Point? {
        guard let date = navigationFixDate, abs(date.timeIntervalSinceNow) < 120 else { return nil }
        return navigationLocation
    }

    func requestRouteLocation() {
        if reporter.authorization == .notDetermined { reporter.requestWhenInUse() }
        else if !reporter.requestFreshLocation() && routeLocation == nil {
            routeNavigationError = "Waiting for a current location. Allow Location access in iPhone Settings."
        }
    }

    func startRouteNavigation(_ route: GarminRoute, start: RouteFollower.Start) {
        guard watchRoute == .apple else {
            routeNavigationError = "Select Apple Watch to share route navigation."
            return
        }
        do {
            guard let current = navigationRoutes.first(where: { $0.id == route.id }) else {
                throw RouteNavigationState.Failure.invalid
            }
            var candidate = routeNavigation
            try candidate.start(route: current, start: start, location: routeLocation,
                                accuracyMeters: navigationAccuracyMeters, origin: "phone")
            try commitRouteNavigation(candidate)
            requestRouteLocation()
        } catch { routeNavigationError = "Route start failed: \(error.localizedDescription)" }
    }

    func stopRouteNavigation() {
        var candidate = routeNavigation
        guard candidate.stop(origin: "phone") else { return }
        do { try commitRouteNavigation(candidate) }
        catch { routeNavigationError = "Route stop failed: \(error.localizedDescription)" }
    }

    private func receiveRouteNavigation(_ data: Data) {
        guard watchRoute == .apple else { return }
        do {
            let state = try RouteNavigationState.decode(data)
            var candidate = routeNavigation
            if try candidate.receive(state) { try commitRouteNavigation(candidate) }
            else if let current = routeNavigation.state, current != state { publishRouteNavigation() }
        } catch { routeNavigationError = "Route sync failed: \(error.localizedDescription)" }
    }

    private func commitRouteNavigation(_ candidate: RouteNavigationReplica) throws {
        guard let state = candidate.state else { return }
        let data = try state.encoded()
        defaults.set(data, forKey: RouteNavigationState.storageKey)
        routeNavigation = candidate
        routeNavigationState = state
        routeNavigationError = nil
        reporter.setNavigationActive(state.phase == .active, appActive: active)
        publishRouteNavigation()
    }

    private func publishRouteNavigation() {
        guard watchRoute == .apple, let state = routeNavigationState,
              WCSession.default.activationState == .activated else { return }
        do {
            let data = try state.encoded()
            var context = WCSession.default.applicationContext
            context[RouteNavigationState.contextKey] = data
            try WCSession.default.updateApplicationContext(context)
            if WCSession.default.isReachable {
                WCSession.default.sendMessage([RouteNavigationState.contextKey: data], replyHandler: nil,
                    errorHandler: { [weak self] error in
                        Task { @MainActor in
                            self?.routeNavigationError = "Route sync queued for reconnection: \(error.localizedDescription)"
                        }
                    })
            }
        } catch { routeNavigationError = "Route sync failed: \(error.localizedDescription)" }
    }

    private func startGarmin() {
        let client = WearTAKGarmin(defaults: defaults)
        client.delegate = self
        garmin = client
        garminDevices = client.devices
        garminDeviceID = client.selectedDeviceID
        if let selected = client.selectedDeviceID { client.selectDevice(selected) }
    }

    func chooseGarminDevices() { garmin?.chooseDevices() }

    func selectGarminDevice(_ id: String) {
        garminGeneration = UUID()
        garminIdentity = nil
        garminBiometrics = WatchBiometrics(batdokCotEnabled: false)
        garminChannelServers = []
        garminQueue = []
        garminSending = false
        garminRouteVersion = nil
        garminMetricsRequestID = nil
        garminMetricsPreview = nil
        garminMetricsError = nil
        garminDeviceID = id
        setWatchIdentity(.failure(.missing))
        garmin?.selectDevice(id)
    }

    func handleGarminURL(_ url: URL) {
        guard watchRoute == .garmin, let garmin, garmin.handle(url) else { return }
        garminDevices = garmin.devices
        garminDeviceID = garmin.selectedDeviceID
    }

    nonisolated func garmin(_ client: WearTAKGarmin, received data: Data, token: String) {
        Task { @MainActor [weak self] in
            guard let self, self.garmin === client, client.connectionToken == token else { return }
            await self.receiveGarmin(data)
        }
    }

    nonisolated func garmin(_ client: WearTAKGarmin, status: String, ready: Bool, token: String) {
        Task { @MainActor [weak self] in
            guard let self, self.watchRoute == .garmin, self.garmin === client,
                  client.connectionToken == token else { return }
            let connectionChanged = self.garminConnectionToken != token
            let becameReady = ready && !self.garminReady
            if connectionChanged {
                self.garminConnectionToken = token
                self.garminGeneration = UUID()
                self.garminQueue = []
                self.garminSending = false
                self.garminRouteVersion = nil
            }
            self.garminStatus = status
            self.garminReady = ready
            self.garminDevices = self.garmin?.devices ?? []
            self.garminDeviceID = self.garmin?.selectedDeviceID
            if ready && (connectionChanged || becameReady) {
                self.enqueueGarmin(GarminEnvelope("request_settings"))
            } else if !ready {
                self.garminGeneration = UUID()
                self.garminQueue = []
                self.garminSending = false
                self.garminRouteVersion = nil
                self.garminIdentity = nil
                self.setWatchIdentity(.failure(.watchUnavailable))
            }
            self.publishState()
        }
    }

    @discardableResult
    func registerDeveloperModeTap() -> Bool {
        guard !developerMode else { return false }
        developerModeTaps += 1
        guard developerModeTaps == 7 else { return false }
        developerMode = true
        return true
    }

    func resetDeveloperModeTaps() {
        developerModeTaps = 0
    }

    func save(_ server: CompanionServer) throws {
        let updated = try CompanionServer.saving(server, into: servers)
        try persist(updated)
        let previous = servers.first { $0.id == server.id }
        servers = updated
        if let previous, previous.endpoint.key != server.endpoint.key {
            sessions.removeValue(forKey: server.id)?.stop()
            mapCache.remove(sourceID: server.id)
            try updateGarminRoutes { $0.removeServer(server.id.uuidString) }
            sourceGenerations[server.id, default: 0] += 1
            try? CertificateStore.remove(endpoint: previous.endpoint.key)
        }
        synchronize()
    }

    func setEnabled(_ enabled: Bool, id: UUID) throws {
        guard var server = servers.first(where: { $0.id == id }) else { return }
        server.enabled = enabled
        if !enabled { cancelTLSApprovals(serverID: id) }
        if enabled { failedTLSDiscoveries = failedTLSDiscoveries.filter { !$0.hasPrefix(id.uuidString + ":") } }
        try save(server)
    }

    func remove(id: UUID) throws {
        guard let server = servers.first(where: { $0.id == id }) else { return }
        cancelTLSApprovals(serverID: id)
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
        let foregroundChanged = self.active != active
        self.active = active
        if foregroundChanged {
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await self.dittoRuntime.setForeground(active)
            }
        }
        if !active { mapCacheWrites.flush() }
        if active {
            endBackgroundRefresh()
            reporter.refreshServicesEnabled()
        }
        synchronize()
    }

    private func cancelTLSApprovals(serverID: UUID) {
        for key in Array(tlsWaiters.keys) where key.hasPrefix(serverID.uuidString + ":") {
            finishTLSApproval(key, result: .failure(CompanionFailure.message("Certificate approval cancelled because the server was disabled or removed.")))
        }
    }

    private func requestTLSApproval(serverID: UUID, isAPI: Bool) async throws {
        guard let server = servers.first(where: { $0.id == serverID && $0.enabled }) else {
            throw CompanionFailure.message("Server unavailable for certificate discovery.")
        }
        let key = "\(serverID.uuidString):\(isAPI ? "api" : "stream")"
        guard (isAPI ? server.apiTLSName : server.streamTLSName) == nil else {
            throw CompanionFailure.message("The configured TLS name failed validation. Automatic discovery does not replace a manual or previously saved identity.")
        }
        guard !failedTLSDiscoveries.contains(key) else {
            throw CompanionFailure.message("Automatic certificate discovery failed. Disable and re-enable the server to try again, or ask the administrator to check its certificate.")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            tlsWaiters[key, default: []].append(continuation)
            guard tlsDiscoveryTasks[key] == nil else { return }
            tlsDiscoveryTasks[key] = Task {
                do {
                    guard let stored = try CertificateStore.read(endpoint: server.endpoint.key) else {
                        throw CompanionFailure.message("Enroll or import a client certificate first.")
                    }
                    let identity = try CertificateStore.resolve(stored)
                    let ca = defaults.data(forKey: "WearTAK.bridge.serverCA.\(server.endpoint.key)")
                    let names = try await ServerCertificateInspection().inspect(host: server.host,
                        port: isAPI ? 8443 : server.port, certificates: identity.certificates, trustedCA: ca,
                        automatic: true)
                    let name = try CertificateStore.automaticTLSName(names)
                    try Task.checkCancellation()
                    guard servers.first(where: { $0.id == serverID }) == server else {
                        throw CompanionFailure.message("Server settings changed during certificate discovery.")
                    }
                    tlsDiscoveryError = nil
                    var updated = server
                    if isAPI { updated.apiTLSName = name } else { updated.streamTLSName = name }
                    try save(updated)
                    Logger(subsystem: "com.aegorsuch.weartak", category: "TLSDiscovery")
                        .notice("Saved automatic \(isAPI ? "API" : "stream", privacy: .public) certificate identity \(name, privacy: .public) for \(server.host, privacy: .public)")
                    finishTLSApproval(key, result: .success(()))
                } catch {
                    tlsDiscoveryError = "Certificate discovery for \(server.host) failed: \(error.localizedDescription)"
                    failedTLSDiscoveries.insert(key)
                    finishTLSApproval(key, result: .failure(error))
                }
            }
        }
    }

    private func finishTLSApproval(_ key: String, result: Result<Void, Error>) {
        tlsDiscoveryTasks.removeValue(forKey: key)?.cancel()
        for waiter in tlsWaiters.removeValue(forKey: key) ?? [] { waiter.resume(with: result) }
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
            mapCacheWrites.flush()
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
        mapCacheWrites.cancel()
        do {
            defaults.set(try JSONEncoder().encode(mapCache), forKey: Self.mapStorageKey)
            mapCacheError = nil
        } catch { mapCacheError = "Unable to cache map: \(error.localizedDescription)" }
    }

    func reconnect(id: UUID) {
        sessions[id]?.reconnect()
    }

    private func persist(_ servers: [CompanionServer]) throws {
        defaults.set(try JSONEncoder().encode(servers), forKey: Self.storageKey)
    }

    private func persistUserMetrics() {
        do {
            defaults.set(try JSONEncoder().encode(userMetrics), forKey: Self.userMetricsKey)
            importedMetricsSource = userMetrics.source
        } catch {
            watchSetupError = "Unable to save imported user metrics: \(error.localizedDescription)"
        }
    }

    func applyImportedMetrics(_ preview: UserMetrics, fields: Set<UserMetrics.Field>) throws {
        var updated = userMetrics
        updated.importFields(fields, from: try preview.validated())
        userMetrics = try updated.validated()
        persistUserMetrics()
    }

    func importAppleHealthMetrics() async throws -> UserMetrics {
        guard HKHealthStore.isHealthDataAvailable() else { throw UserMetrics.Failure.unavailable }
        let heightType = HKQuantityType.quantityType(forIdentifier: .height)!
        let weightType = HKQuantityType.quantityType(forIdentifier: .bodyMass)!
        let bloodType = HKObjectType.characteristicType(forIdentifier: .bloodType)!
        let sexType = HKObjectType.characteristicType(forIdentifier: .biologicalSex)!
        try await healthStore.requestAuthorization(toShare: [], read: [heightType, weightType, bloodType, sexType])
        var result = UserMetrics(source: "Apple Health", measuredAt: Date())
        if let birth = try? healthStore.dateOfBirthComponents().year { result.birthYear = birth }
        if let sex = try? healthStore.biologicalSex().biologicalSex {
            switch sex {
            case .female: result.sex = "Female"
            case .male: result.sex = "Male"
            default: break
            }
        }
        if let blood = try? healthStore.bloodType().bloodType {
            switch blood {
            case .aPositive: result.bloodType = "A+"
            case .aNegative: result.bloodType = "A-"
            case .bPositive: result.bloodType = "B+"
            case .bNegative: result.bloodType = "B-"
            case .abPositive: result.bloodType = "AB+"
            case .abNegative: result.bloodType = "AB-"
            case .oPositive: result.bloodType = "O+"
            case .oNegative: result.bloodType = "O-"
            default: break
            }
        }
        result.heightCM = try await latestQuantity(heightType, unit: .meterUnit(with: .centi))
        result.weightKG = try await latestQuantity(weightType, unit: .gramUnit(with: .kilo))
        if result.birthYear == nil, result.heightCM == nil, result.weightKG == nil, result.sex == nil, result.bloodType == nil {
            throw UserMetrics.Failure.unavailable
        }
        return try result.validated()
    }

    private func latestQuantity(_ type: HKQuantityType, unit: HKUnit) async throws -> Double? {
        try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                let sample = samples?.first as? HKQuantitySample
                continuation.resume(returning: sample?.quantity.doubleValue(for: unit))
            }
            healthStore.execute(query)
        }
    }

    func importGarminMetrics() async throws -> UserMetrics {
        guard watchRoute == .garmin, garminReady else {
            throw CompanionFailure.message("Select and connect a Garmin watch first.")
        }
        let requestID = UUID().uuidString
        garminMetricsRequestID = requestID
        garminMetricsPreview = nil
        garminMetricsError = nil
        enqueueGarmin(GarminEnvelope("request_user_profile", ["requestId": requestID]))
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let garminMetricsPreview {
                garminMetricsRequestID = nil
                return garminMetricsPreview
            }
            if let garminMetricsError {
                garminMetricsRequestID = nil
                throw CompanionFailure.message(garminMetricsError)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        garminMetricsRequestID = nil
        throw CompanionFailure.message("Timed out waiting for Garmin user metrics.")
    }

    private func enqueueGarmin(_ message: GarminEnvelope) {
        guard watchRoute == .garmin, garminReady else {
            garminStatus = "Garmin reply deferred: watch is unavailable. Queued events will retry."
            return
        }
        guard garminQueue.count < 64 else {
            garminStatus = "Garmin reply queue is full. Queued events will retry."
            return
        }
        garminQueue.append(message)
        flushGarmin()
    }

    private func replayGarminRoutes() {
        guard garminRouteVersion == GarminRoute.version, watchRoute == .garmin, garminReady else { return }
        let messages = [GarminEnvelope("routes_reset", ["routeVersion": GarminRoute.version])] +
            garminRoutes.routes.map { GarminEnvelope("route", $0.payload) }
        // Admit the entire reset/replay or none; a partial reset must not erase good watch routes.
        guard garminQueue.count + messages.count <= 64 else {
            reportGarminRouteError("Garmin route snapshot deferred: reply queue is full. Refresh the watch map to retry.")
            return
        }
        garminQueue.append(contentsOf: messages)
        flushGarmin()
    }

    private func reportGarminRouteError(_ detail: String) {
        garminStatus = detail
        guard garminRouteVersion == GarminRoute.version else { return }
        var error = detail
        while error.utf8.count > 256 { error.removeLast() }
        // Error text is generated locally; never echo raw server route XML or metadata.
        enqueueGarmin(GarminEnvelope("routes_error", ["routeVersion": GarminRoute.version,
                                                      "error": error]))
    }

    private func updateGarminRoutes(_ update: (inout GarminRouteStore) throws -> Void) throws {
        let previous = garminRoutes.routes
        var candidate = garminRoutes
        try update(&candidate)
        _ = try candidate.validated()
        let data = try JSONEncoder().encode(candidate)
        defaults.set(data, forKey: Self.garminRoutesStorageKey)
        garminRoutes = candidate
        navigationRoutes = candidate.routes
        guard previous != garminRoutes.routes else { return }
        if let state = routeNavigationState, state.phase == .active,
           previous.contains(where: { $0.id == state.route.id }),
           !candidate.routes.contains(where: { $0.id == state.route.id && $0.points == state.route.points && $0.method == state.route.method }) {
            stopRouteNavigation()
        }
        if watchRoute == .apple { publishAppleRoutes() }
        guard garminRouteVersion == GarminRoute.version, watchRoute == .garmin, garminReady else { return }
        var messages: [GarminEnvelope] = []
        for route in previous where !garminRoutes.routes.contains(where: {
            $0.serverId == route.serverId && $0.uid == route.uid
        }) {
            messages.append(GarminEnvelope("route_remove", route.removalPayload))
        }
        for route in garminRoutes.routes where !previous.contains(route) {
            messages.append(GarminEnvelope("route", route.payload))
        }
        guard garminQueue.count + messages.count <= 64 else {
            reportGarminRouteError("Garmin route update deferred: reply queue is full. Refresh the watch map to retry.")
            return
        }
        garminQueue.append(contentsOf: messages)
        flushGarmin()
    }

    private func receiveGarminRoutes(_ xml: String, sourceID: UUID) -> Bool {
        guard enabledSourceIDs.contains(sourceID) else { return false }
        do {
            let events = try GarminRouteCoT.parse(Data(xml.utf8), serverId: sourceID.uuidString)
            guard !events.isEmpty else { return false }
            routePackageError = nil
            try updateGarminRoutes { store in
                for event in events {
                    switch event {
                    case .route(let route): try store.upsert(route)
                    case .remove(let uid): store.remove(serverId: sourceID.uuidString, uid: uid)
                    }
                }
            }
            if watchRoute == .apple { publishAppleRoutes() }
            return events.contains { if case .route = $0 { return true }; return false }
        } catch {
            // Invalid route geometry must not degrade to a misleading single map point.
            let isRoute = xml.contains("b-m-r")
            if isRoute {
                routePackageError = error.localizedDescription
                if watchRoute == .apple { publishAppleRoutes() }
                else { reportGarminRouteError(error.localizedDescription) }
            }
            return isRoute
        }
    }

    private func flushGarmin() {
        guard watchRoute == .garmin, garminReady, !garminSending, let garmin, !garminQueue.isEmpty else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: garminQueue[0].object)
            guard data.count <= GarminEnvelope.maximumBytes else {
                throw GarminRelayProtocol.Failure.invalid("outgoing message size")
            }
            let generation = garminGeneration
            let connectionToken = garmin.connectionToken
            garminSending = true
            garmin.send(data) { [weak self] error in
                Task { @MainActor in
                    guard let self, self.garminGeneration == generation, self.watchRoute == .garmin,
                          self.garmin?.connectionToken == connectionToken else { return }
                    self.garminSending = false
                    if !self.garminQueue.isEmpty { self.garminQueue.removeFirst() }
                    if let error {
                        self.garminStatus = "Garmin send failed: \(error.localizedDescription)"
                    }
                    self.flushGarmin()
                }
            }
        } catch {
            garminQueue.removeFirst()
            garminStatus = "Garmin send failed: \(error.localizedDescription)"
            flushGarmin()
        }
    }

    private func synchronize() {
        let validIDs = Set(servers.map(\.id))
        mapCache.prune(enabledServerIDs: enabledSourceIDs)
        try? updateGarminRoutes { $0.retainServers(Set(enabledSourceIDs.map(\.uuidString))) }
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
                session.onTLSMismatch = { [weak self] isAPI in
                    guard let self else { throw CompanionFailure.message("Companion unavailable.") }
                    try await self.requestTLSApproval(serverID: server.id, isAPI: isAPI)
                }
                session.onChannelsChanged = { [weak self] in
                    guard let self else { return }
                    self.sourceGenerations[server.id, default: 0] += 1
                    self.mapCache.remove(sourceID: server.id)
                    self.saveMapCache()
                    try? self.updateGarminRoutes { $0.removeServer(server.id.uuidString) }
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
        if dittoStatus.enabled { ids.insert(DittoCoTDocument.sourceID) }
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
        try updateGarminRoutes { $0.retainServers(Set(enabledSourceIDs.map(\.uuidString))) }
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
                   phoneLocationEnabled: reporter.isRunning, sitxStatus: sitxStatusSummary ?? "",
                   sitxSettings: sitx.settingsSnapshot, relayPaused: relayPauseReason,
                   remoteAlertSourceIDs: Array(connectedAlertSourceIDs), dittoStatus: dittoStatus)
    }

    /// Non-nil while Companion is backgrounded without phone location reporting: iOS then only grants short
    /// windows per watch request, so the watch shows why its TAK link keeps dropping.
    private var relayPauseReason: String? {
        guard !active, !reporter.isRunning, configured else { return nil }
        if let fix = PhoneBackgroundAdvice.watchReason(authorization: reporter.authorization,
            preciseLocation: reporter.preciseLocation, servicesEnabled: reporter.servicesEnabled) {
            let localizedFix: String
            switch fix {
            case "turn on Location Services":
                localizedFix = String(localized: "turn on Location Services", table: "PhoneBridgeStatus")
            case "turn on Precise Location":
                localizedFix = String(localized: "turn on Precise Location", table: "PhoneBridgeStatus")
            case "location restricted":
                localizedFix = String(localized: "location restricted", table: "PhoneBridgeStatus")
            case "set Location to Always":
                localizedFix = String(localized: "set Location to Always", table: "PhoneBridgeStatus")
            default:
                localizedFix = fix
            }
            return String(localized: "On iPhone, \(localizedFix)", table: "PhoneBridgeStatus")
        }
        return String((phoneReporting.detail ?? String(localized: "Phone location reporting is off", table: "PhoneBridgeStatus")).prefix(200))
    }

    private var phoneReportingSummary: String {
        guard phoneReporting.running else {
            return String(localized: "Off - \(phoneReporting.detail ?? phoneReporting.state)", table: "PhoneBridgeStatus")
        }
        return phoneReporting.state
    }

    /// Starts or stops phone GPS reporting from current servers, watch identity and location authorization.
    private func evaluateReporting() {
        guard !evaluatingReporting else { return }
        evaluatingReporting = true
        defer { evaluatingReporting = false }
        reporter.setNavigationActive(routeNavigationState?.phase == .active, appActive: active)
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
                phoneReporting.state = String(localized: "Waiting for phone GPS fix", table: "PhoneBridgeStatus")
                reporter.start(appActive: active)
            }
        case .requestWhenInUse:
            reporter.stop()
            phoneReporting.state = String(localized: "Requesting location permission", table: "PhoneBridgeStatus")
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
            phoneReporting.state = String(localized: "Stopped", table: "PhoneBridgeStatus")
            phoneReporting.detail = localizedReportingBlockReason(reason)
            phoneReporting.interval = nil
        }
        phoneReporting.running = reporter.isRunning
        phoneReporting.permission = reporter.permissionSummary
        let advice = PhoneBackgroundAdvice.message(hasServers: enabledConfigured > 0,
            authorization: reporter.authorization, preciseLocation: reporter.preciseLocation,
            servicesEnabled: reporter.servicesEnabled)
        let localizedAdvice: String?
        switch advice {
        case "Turn on Location Services so the watch stays connected to TAK while this phone is locked.":
            localizedAdvice = String(localized: "Turn on Location Services so the watch stays connected to TAK while this phone is locked.", table: "PhoneBridgeStatus")
        case "Turn on Precise Location so the watch stays connected to TAK while this phone is locked.":
            localizedAdvice = String(localized: "Turn on Precise Location so the watch stays connected to TAK while this phone is locked.", table: "PhoneBridgeStatus")
        case "Location access is restricted, so the watch will lose TAK when this phone is locked.":
            localizedAdvice = String(localized: "Location access is restricted, so the watch will lose TAK when this phone is locked.", table: "PhoneBridgeStatus")
        case "Set Location to Always (with Precise Location on) so the watch stays connected to TAK while this phone is locked or in your pocket.":
            localizedAdvice = String(localized: "Set Location to Always (with Precise Location on) so the watch stays connected to TAK while this phone is locked or in your pocket.", table: "PhoneBridgeStatus")
        default:
            localizedAdvice = advice
        }
        if backgroundAdvice != localizedAdvice { backgroundAdvice = localizedAdvice }
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

    /// Phone GPS reporting is the watch identity's position source, so it also feeds Ditto `track`.
    private func publishPhoneDittoTrack(_ xml: String, interval: TimeInterval) {
        guard watchRoute == .apple, dittoRuntime.status.state == .syncing, !phoneDittoTrackInFlight,
              lastPhoneDittoTrackAt.map({ Date().timeIntervalSince($0) >= interval }) ?? true else { return }
        phoneDittoTrackInFlight = true
        Task {
            defer { self.phoneDittoTrackInFlight = false }
            if await self.dittoRuntime.publishTrack(pliXML: xml) { self.lastPhoneDittoTrackAt = Date() }
        }
    }

    private func requestSelfPosition() {
        if reporter.requestFreshLocation() { selfPositionRequestedAt = Date() }
        lastPhoneReportAt = nil
        if let fix = alertLocations.lastKnown() { reportPhoneFix(fix, allowLastKnown: true) }
    }

    private func reportPhoneFix(_ fix: PhoneLocationFix, allowLastKnown: Bool = false) {
        if !allowLastKnown, fix.horizontalAccuracy >= 0, fix.horizontalAccuracy.isFinite,
           fix.latitude.isFinite, fix.longitude.isFinite, (-90...90).contains(fix.latitude),
           (-180...180).contains(fix.longitude), abs(fix.timestamp.timeIntervalSinceNow) < 120 {
            navigationLocation = GarminRoute.Point(lat: fix.latitude, lon: fix.longitude)
            navigationFixDate = fix.timestamp
            navigationAccuracyMeters = fix.horizontalAccuracy
            var candidate = routeNavigation
            if let location = navigationLocation, watchRoute == .apple,
               candidate.advance(at: location, accuracyMeters: fix.horizontalAccuracy, origin: "phone") {
                do { try commitRouteNavigation(candidate) }
                catch { routeNavigationError = "Route progress failed: \(error.localizedDescription)" }
            }
        }
        let previous = alertLocations.lastKnown()
        alertLocations.receive(fix)
        if let valid = alertLocations.lastKnown(), valid != previous {
            do { defaults.set(try JSONEncoder().encode(valid), forKey: AlertLocationHistory.storageKey) }
            catch { reportingLogger.error("Last-known GPS could not be saved: \(error.localizedDescription, privacy: .public)") }
        }
        refreshPhoneEmergencies(using: fix)
        retryPendingGarminEmergencies()
        refreshGarminMarkers(using: fix)
        guard reporter.isRunning, case .success(let identity) = watchIdentity else { return }
        latestPhoneFix = fix
        do {
            if allowLastKnown {
                guard AlertLocationHistory.isUsable(fix, now: fix.timestamp) else {
                    throw PhoneReportingPolicy.FixFailure.invalidCoordinate
                }
            } else { try PhoneReportingPolicy.validate(fix) }
        }
        catch {
            phoneReporting.detail = error.localizedDescription
            reportingLogger.error("Phone GPS fix rejected: \(error.localizedDescription, privacy: .public)")
            return
        }
        if let requested = selfPositionRequestedAt, fix.timestamp >= requested, !phoneSendInFlight {
            lastPhoneReportAt = nil
            selfPositionRequestedAt = nil
        }
        let interval = PhoneReportingPolicy.interval(for: identity, speed: fix.speed)
        phoneInterval = interval
        phoneReporting.interval = interval
        guard !phoneSendInFlight, PhoneReportingPolicy.isDue(lastSentAt: lastPhoneReportAt, interval: interval) else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let biometrics = watchRoute == .garmin ? garminBiometrics :
            WatchBiometrics.decode(contextValue: WCSession.default.receivedApplicationContext[WatchBiometrics.contextKey])
        let xml = PhonePLI.event(identity: identity, fix: fix, interval: interval, appVersion: version,
                                 osVersion: "iOS \(UIDevice.current.systemVersion)",
                                 biometrics: biometrics ?? WatchBiometrics())
        publishPhoneDittoTrack(xml, interval: interval)
        let ready = readyOutputs()
        guard !ready.isEmpty else {
            updatePhoneReportingState(String(localized: "Waiting for TAK server connection", table: "PhoneBridgeStatus"),
                detail: String(localized: "No enabled TAK server is connected; Companion retries automatically.", table: "PhoneBridgeStatus"))
            return
        }
        phoneSendInFlight = true
        Task {
            defer {
                self.phoneSendInFlight = false
                if case .success(let current) = self.watchIdentity,
                   !current.hasSameSettings(as: identity),
                   let fix = self.latestPhoneFix {
                    self.reportPhoneFix(fix)
                } else if let requested = self.selfPositionRequestedAt, let fix = self.latestPhoneFix,
                          fix.timestamp >= requested {
                    self.lastPhoneReportAt = nil
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
                self.reportingLogger.notice("Watch-identity PLI accepted by \(delivered.count) TAK server(s); vitals \((biometrics ?? WatchBiometrics()).fresh(reportingInterval: interval).remarks, privacy: .public)")
                self.lastPhoneReportAt = Date()
                self.phoneReporting.lastReportAt = self.lastPhoneReportAt
            }
            self.updatePhoneReportingState(!delivered.isEmpty
                ? String(localized: "Reporting phone GPS", table: "PhoneBridgeStatus")
                : String(localized: "Report failed; reconnecting", table: "PhoneBridgeStatus"),
                detail: failures.isEmpty ? nil : failures.joined(separator: "\n"))
        }
    }

    private func receiveGarmin(_ data: Data) async {
        guard watchRoute == .garmin, garminReady else { return }
        let generation = garminGeneration
        let connectionToken = garmin?.connectionToken
        var received: GarminEnvelope?
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            let envelope = try GarminEnvelope(object: object)
            received = envelope
            guard garminReceivesInFlight < 16 else {
                throw CompanionFailure.message("Garmin relay is busy. Retry later.")
            }
            garminReceivesInFlight += 1
            defer { garminReceivesInFlight -= 1 }
            try beginBackgroundRefresh()
            if envelope.type == "watch_settings" {
                guard let id = garminDeviceID.flatMap(UUID.init(uuidString:)) else {
                    throw GarminRelayProtocol.Failure.noIdentity
                }
                let identity = try GarminRelayProtocol.identity(envelope, uid: id)
                garminIdentity = identity
                setWatchIdentity(.success(identity))
                return
            }
            if envelope.type == "user_profile" {
                guard try envelope.string("requestId", maximum: 128) == garminMetricsRequestID else { return }
                if let error = envelope.payload["error"] as? String {
                    garminMetricsError = error
                } else {
                    garminMetricsPreview = try GarminRelayProtocol.metrics(envelope)
                }
                return
            }
            if envelope.type == "pli" {
                guard var identity = garminIdentity else { throw GarminRelayProtocol.Failure.noIdentity }
                if let callsign = envelope.payload["callsign"] as? String { identity.callSign = callsign }
                if let team = envelope.payload["team"] as? String { identity.team = team }
                if let role = envelope.payload["role"] as? String { identity.role = role }
                identity.issuedAt = Date()
                identity = try identity.validated()
                garminIdentity = identity
                let heartRate = envelope.payload["hr"] == nil ? nil : try envelope.integer("hr", range: 1...300)
                garminBiometrics = WatchBiometrics(
                    heartRate: heartRate, measuredAt: Date(),
                    batdokCotEnabled: envelope.payload["includeBatdok"] as? Bool ?? false)
                setWatchIdentity(.success(identity))
                requestSelfPosition()
                return
            }
            let isEvent = ["marker", "marker_delete", "emergency", "chat"].contains(envelope.type)
            if isEvent {
                if envelope.type == "emergency", let uid = envelope.payload["uid"] as? String {
                    reporter.requestFreshLocation()
                    if envelope.payload["state"] as? String == "CANCEL" {
                        pendingGarminEmergencies.removeValue(forKey: uid)
                    }
                }
                if envelope.type == "marker", envelope.payload["locationSource"] as? String == "phone" {
                    requestSelfPosition()
                    let uid = try envelope.string("uid", maximum: 128)
                    if pendingGarminMarkers[uid] == nil, pendingGarminMarkers.count < 64 {
                        pendingGarminMarkers[uid] = (envelope, Date())
                    }
                }
                if envelope.type == "marker_delete", let uid = envelope.payload["uid"] as? String {
                    pendingGarminMarkers.removeValue(forKey: uid)
                }
                let reply: BridgeWire.Message
                do { reply = try await relayGarminEvent(envelope) }
                catch GarminRelayProtocol.Failure.noLocation {
                    if envelope.type == "emergency", envelope.payload["state"] as? String == "ALERT",
                       let uid = envelope.payload["uid"] as? String {
                        guard pendingGarminEmergencies.count < 32 || pendingGarminEmergencies[uid] != nil else {
                            throw CompanionFailure.message("Too many pending emergency locations. Retry later.")
                        }
                        pendingGarminEmergencies[uid] = envelope
                        reporter.setEmergencyActive(true)
                        try await sendGarminLocationUnavailable(envelope)
                    }
                    throw GarminRelayProtocol.Failure.noLocation
                }
                guard generation == garminGeneration, watchRoute == .garmin,
                      garmin?.connectionToken == connectionToken else { return }
                if envelope.type == "marker", envelope.payload["locationSource"] as? String == "phone",
                   let fix = alertLocations.lastKnown() { try sendGarminMarkerLocation(envelope, fix: fix) }
                try sendGarminReply(reply, request: envelope)
                return
            }
            if envelope.type == "location_request" || envelope.type == "pli" { requestSelfPosition() }
            let request = try GarminRelayProtocol.request(
                envelope, identity: garminIdentity, fix: alertLocations.lastKnown(), channelServers: garminChannelServers)
            let reply = try await processWatchMessage(request)
            guard generation == garminGeneration, watchRoute == .garmin,
                garmin?.connectionToken == connectionToken
            else { return }
            try sendGarminReply(reply, request: envelope)
        } catch {
            guard generation == garminGeneration, watchRoute == .garmin,
                garmin?.connectionToken == connectionToken
            else { return }
            garminStatus = error.localizedDescription
            if let received, ["marker", "marker_delete", "emergency", "chat"].contains(received.type),
                let messageID = received.payload["messageId"] as? String, messageID.count <= 128
            {
                var payload: [String: Any] = [
                    "ok": false, "messageId": messageID,
                    "error": String(error.localizedDescription.prefix(256)),
                ]
                if let session = received.payload["relaySession"] as? String { payload["relaySession"] = session }
                enqueueGarmin(GarminEnvelope("relay_result", payload))
            }
        }
    }

    private func relayGarminEvent(_ envelope: GarminEnvelope, fallbackXML: String? = nil) async throws -> BridgeWire.Message {
        if let garminLedgerError { throw CompanionFailure.message(garminLedgerError) }
        guard let deviceID = garminDeviceID.flatMap(UUID.init(uuidString:)),
              let identity = garminIdentity else { throw GarminRelayProtocol.Failure.noIdentity }
        var payload = envelope.payload
        payload.removeValue(forKey: "relaySession")
        let fingerprint = try JSONSerialization.data(
            withJSONObject: GarminEnvelope(envelope.type, payload).object, options: [.sortedKeys])
        var updated = garminLedger
        let record = try updated.reserve(deviceID: deviceID,
            messageID: envelope.string("messageId", maximum: 128), fingerprint: fingerprint) {
            if let fallbackXML { return fallbackXML }
            return try GarminRelayProtocol.outgoingCoT(envelope, identity: identity,
                                                       fix: alertLocations.lastKnown(), now: Date())
        }
        try updated.save(to: GarminDeliveryLedger.storageURL())
        garminLedger = updated
        if record.accepted {
            return BridgeWire.Message(kind: .acknowledgement, id: record.requestID, ready: true)
        }
        if let task = garminEventTasks[record.requestID] { return try await task.value }
        guard garminWrites.count < 16 else {
            throw CompanionFailure.message("Garmin relay is busy. Retry later.")
        }
        garminWrites.insert(record.requestID)
        let task = Task {
            defer {
                self.garminWrites.remove(record.requestID)
                self.garminEventTasks.removeValue(forKey: record.requestID)
            }
            let reply = try await self.processWatchMessage(
                BridgeWire.Message(kind: .cot, id: record.requestID, xml: record.xml))
            guard reply.kind == .acknowledgement, reply.ready == true else {
                throw CompanionFailure.message("No connected server accepted this Garmin event. Retry later.")
            }
            var accepted = self.garminLedger
            try accepted.accept(record.requestID)
            try accepted.save(to: GarminDeliveryLedger.storageURL())
            self.garminLedger = accepted
            return reply
        }
        garminEventTasks[record.requestID] = task
        return try await task.value
    }

    private func sendGarminLocationUnavailable(_ envelope: GarminEnvelope) async throws {
        guard let identity = garminIdentity else { throw GarminRelayProtocol.Failure.noIdentity }
        let messageID = try envelope.string("messageId", maximum: 128)
        let fallbackID = "no-gps:" + SHA256.hash(data: Data(messageID.utf8)).map { String(format: "%02x", $0) }.joined()
        let xml = try TAKChatMessage.outgoing(senderUID: identity.uid, senderCallSign: identity.resolvedCallSign,
            recipientUID: TAKChatMessage.allChatRoomsUID, recipientCallSign: TAKChatMessage.allChatRoomsUID,
            text: "EMERGENCY from \(identity.resolvedCallSign): location unavailable, acquiring GPS",
            messageID: fallbackID, isGroup: true)
        _ = try await relayGarminEvent(GarminEnvelope("chat", ["messageId": fallbackID]), fallbackXML: xml)
    }

    private func retryPendingGarminEmergencies() {
        guard watchRoute == .garmin, garminReady, alertLocations.usable() != nil else { return }
        for (uid, envelope) in pendingGarminEmergencies where !garminEmergencyRetries.contains(uid) {
            garminEmergencyRetries.insert(uid)
            Task {
                defer { garminEmergencyRetries.remove(uid) }
                guard pendingGarminEmergencies[uid] != nil else { return }
                do {
                    let reply = try await relayGarminEvent(envelope)
                    guard pendingGarminEmergencies[uid] != nil else { return }
                    pendingGarminEmergencies.removeValue(forKey: uid)
                    try sendGarminReply(reply, request: envelope)
                } catch {
                    garminStatus = "Unable to relay emergency location: \(error.localizedDescription)"
                }
            }
        }
    }

    private func sendGarminMarkerLocation(_ envelope: GarminEnvelope, fix: PhoneLocationFix) throws {
        guard watchRoute == .garmin, garminReady, garminQueue.count < 64 else {
            throw CompanionFailure.message("Garmin marker position reply deferred; retry when the watch is ready.")
        }
        enqueueGarmin(GarminEnvelope("entity", [
            "uid": try envelope.string("uid", maximum: 128),
            "type": try envelope.string("type", maximum: 128),
            "lat": fix.latitude, "lon": fix.longitude,
            "ce": AlertLocationHistory.circularError(fix),
            "callSign": (envelope.payload["title"] as? String) ?? "",
            "isPoint": true, "isUser": false,
            "time": ISO8601DateFormatter().string(from: fix.timestamp),
            "stale": ISO8601DateFormatter().string(from: Date().addingTimeInterval(86_400))
        ]))
    }

    private func refreshGarminMarkers(using fix: PhoneLocationFix) {
        guard watchRoute == .garmin, garminReady, AlertLocationHistory.isUsable(fix, now: Date()) else { return }
        for (uid, pending) in pendingGarminMarkers {
            if fix.timestamp >= pending.requestedAt, !garminMarkerUpdates.contains(uid) {
                var payload = pending.envelope.payload
                payload["messageId"] = UUID().uuidString
                let envelope = GarminEnvelope("marker", payload)
                garminMarkerUpdates.insert(uid)
                Task {
                    defer { garminMarkerUpdates.remove(uid) }
                    do {
                        _ = try await relayGarminEvent(pending.envelope)
                        guard pendingGarminMarkers[uid]?.envelope.payload["messageId"] as? String ==
                                pending.envelope.payload["messageId"] as? String else { return }
                        _ = try await relayGarminEvent(envelope)
                        try sendGarminMarkerLocation(envelope, fix: fix)
                        pendingGarminMarkers.removeValue(forKey: uid)
                    } catch {
                        garminStatus = "Marker GPS update failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func refreshPhoneEmergencies(using fix: PhoneLocationFix) {
        guard !refreshingPhoneEmergencies, AlertLocationHistory.isUsable(fix, now: Date()),
              !activePhoneEmergencies.isEmpty else { return }
        refreshingPhoneEmergencies = true
        Task {
            defer { refreshingPhoneEmergencies = false }
            for (uid, alert) in activePhoneEmergencies {
                guard alert.lastFixAt.map({ fix.timestamp.timeIntervalSince($0) >= 5 }) ?? true,
                      let xml = AlertLocationHistory.refreshingAlert(alert.xml, ownUID: alert.ownUID, fix: fix) else { continue }
                let outputs = readyOutputs()
                var accepted = false
                for (_, send) in outputs {
                    guard activePhoneEmergencies[uid]?.xml == alert.xml else { break }
                    do { try await send(xml); accepted = true }
                    catch { reportingLogger.error("Emergency GPS update failed: \(error.localizedDescription, privacy: .public)") }
                }
                if accepted, activePhoneEmergencies[uid]?.xml == alert.xml {
                    activePhoneEmergencies[uid]?.lastFixAt = fix.timestamp
                }
            }
        }
    }

    private func sendGarminReply(_ reply: BridgeWire.Message, request: GarminEnvelope) throws {
        if request.type == "relay_hello" {
            var payload: [String: Any] = [
                "ready": reply.ready == true, "detail": reply.detail ?? "",
                "reliableDelivery": true,
                "phoneLocation": true,
                "chatGroups": false,
                "routeVersion": GarminRoute.version,
            ]
            if let session = request.payload["relaySession"] as? String { payload["relaySession"] = session }
            enqueueGarmin(GarminEnvelope("relay_status", payload))
            garminRouteVersion = (try? request.integer("routeVersion", range: 1...1))
            replayGarminRoutes()
            return
        }
        switch reply.kind {
        case .hello:
            break
        case .acknowledgement:
            if let messageID = request.payload["messageId"] {
                var payload: [String: Any] = ["ok": true, "messageId": messageID]
                if let session = request.payload["relaySession"] as? String { payload["relaySession"] = session }
                enqueueGarmin(GarminEnvelope("relay_result", payload))
            }
        case .mapSnapshot:
            garminRouteVersion = (try? request.integer("routeVersion", range: 1...1))
            replayGarminRoutes()
            for event in (reply.mapEvents ?? []).prefix(GarminRelayProtocol.maximumEntities) {
                if event.header?.type?.hasPrefix("b-m-r") == true { continue }
                if let envelope = try GarminRelayProtocol.incoming(event.xml, ownUID: garminIdentity?.uid ?? "") {
                    enqueueGarmin(envelope)
                }
            }
        case .channels:
            let servers = reply.channelServers ?? []
            if request.type == "channels_servers_request" {
                garminChannelServers = Array(servers.prefix(4).map(\.id))
                let payload = [
                    "servers": servers.prefix(4).enumerated().map {
                        ["serverIndex": $0.offset, "name": $0.element.name]
                    }
                ]
                enqueueGarmin(GarminEnvelope("channels_servers_response", payload))
            } else if let index = request.payload["serverIndex"] as? Int,
                garminChannelServers.indices.contains(index),
                let server = servers.first(where: { $0.id == garminChannelServers[index] })
            {
                enqueueGarmin(
                    GarminEnvelope(
                        "channels_response",
                        [
                            "serverName": server.name,
                            "channels": server.channels.map {
                                [
                                    "bitpos": $0.bitPosition, "name": $0.name, "direction": $0.direction,
                                    "active": $0.active,
                                ]
                            },
                        ]))
            }
        case .missions:
            let requestID = try request.string("requestId", maximum: 128)
            let payloadServers = (reply.missionServers ?? []).map { server -> [String: Any] in
                [
                    "id": server.id.uuidString, "name": server.name, "state": server.state,
                    "missions": server.missions.map { mission -> [String: Any] in
                        var row: [String: Any] = [
                            "name": mission.name, "subscribed": mission.subscribed,
                            "passwordProtected": mission.passwordProtected,
                        ]
                        if let count = mission.itemCount { row["itemCount"] = count }
                        if let error = mission.error { row["error"] = error }
                        return row
                    },
                ]
            }
            if request.type == "missions_servers_request" {
                enqueueGarmin(
                    GarminEnvelope(
                        "missions_servers_response",
                        ["requestId": requestID, "dataSyncVersion": 1, "servers": payloadServers]))
            } else {
                let serverID = try request.string("serverID", maximum: 128)
                let missions =
                    payloadServers.first(where: { ($0["id"] as? String) == serverID })?["missions"] as? [[String: Any]]
                    ?? []
                enqueueGarmin(
                    GarminEnvelope(
                        "missions_response",
                        ["requestId": requestID, "dataSyncVersion": 1, "serverID": serverID, "missions": missions]))
            }
        default:
            break
        }
    }

    /// Publishes the watch's own PLI to Ditto `track`. Phone GPS reporting publishes its own PLI instead, so a
    /// watch fix is acknowledged without overwriting it.
    private func dittoTrackReply(to message: BridgeWire.Message, xml: String) async -> BridgeWire.Message {
        let publishedIdentity = try? WatchReportingIdentity.decode(
            contextValue: WCSession.default.receivedApplicationContext[WatchReportingIdentity.contextKey])
        // Ditto runs on every watch TAK route, so this checks the published UID, not Companion relay selection.
        guard let uid = publishedIdentity?.uid, PhonePLI.isSelfPLI(xml, uid: uid) else {
            return BridgeWire.Message(kind: .acknowledgement, id: message.id, ready: false,
                detail: "Ditto accepts only this watch's own position.", dittoStatus: dittoRuntime.status)
        }
        let published = reporter.isRunning ? true : await dittoRuntime.publishTrack(pliXML: xml)
        return BridgeWire.Message(kind: .acknowledgement, id: message.id, ready: published,
            dittoStatus: dittoRuntime.status)
    }

    private func processWatchMessage(_ message: BridgeWire.Message) async throws -> BridgeWire.Message {
        if message.locationRefresh == true || message.kind == .mapSnapshot {
            requestSelfPosition()
        }
        if message.kind == .hello {
            if let config = message.dittoConfig { _ = await dittoRuntime.apply(config) }
            chatBuffer.prune(enabledServerIDs: enabledSourceIDs)
            return try chatBuffer.filling(snapshot(id: message.id))
        }
        if message.kind == .dittoConfig, let config = message.dittoConfig {
            let current = await dittoRuntime.apply(config)
            return BridgeWire.Message(kind: .acknowledgement, id: message.id,
                ready: current.state != .failed, detail: current.detail, dittoStatus: current)
        }
        if message.kind == .dittoTrack, let xml = message.xml {
            return await dittoTrackReply(to: message, xml: xml)
        }
        if message.kind == .dittoEvent, let xml = message.xml {
            guard let identity = try WatchReportingIdentity.decode(
                contextValue: WCSession.default.receivedApplicationContext[WatchReportingIdentity.contextKey]) else {
                throw CompanionFailure.message("Ditto is waiting for this watch's reporting identity.")
            }
            let published = await dittoRuntime.publishEvent(xml, uid: identity.uid, callsign: identity.callSign)
            return BridgeWire.Message(kind: .acknowledgement, id: message.id, ready: published,
                                      dittoStatus: dittoRuntime.status)
        }
        if message.kind == .sitxConfig, let config = message.sitxConfig {
            var released: SitxRelayConfig?
            if config.removeConnection == true {
                await sitx.removeConnection()
                released = SitxRelayConfig(enabled: false, host: "", flowTag: "", removeConnection: true)
            } else if config.enabled {
                try applySitx(config)
            } else {
                let token = await sitx.release()
                released = SitxRelayConfig(enabled: false, host: config.host, flowTag: config.flowTag, refreshToken: token)
            }
            return BridgeWire.Message(kind: .acknowledgement, id: message.id, ready: true,
                sitxConfig: released, sitxStatus: sitxStatusSummary ?? "", sitxSettings: sitx.settingsSnapshot)
        }
        if message.kind == .routes { return appleRouteSnapshot(id: message.id) }
        if message.kind == .mapSnapshot { return try await mapReply(to: message) }
        if message.kind == .channels || message.kind == .channelUpdate { return await channelReply(to: message) }
        if message.kind == .missions, message.missionItemOffset != nil { return missionItemPageReply(to: message) }
        if message.kind == .missions || message.kind == .missionUpdate { return await missionReply(to: message) }
        guard message.kind == .cot, let xml = message.xml, canRelay, connected, watchWritesInFlight < 16 else {
            return snapshot(id: message.id)
        }
        watchWritesInFlight += 1
        defer { watchWritesInFlight -= 1 }
        guard relayWritesInFlight.insert(message.id).inserted else {
            throw CompanionFailure.message("This relay write is already in progress; retry with the same ID.")
        }
        defer { relayWritesInFlight.remove(message.id) }
        let isGarmin = garminWrites.contains(message.id)
        let generation = garminGeneration
        let connectionToken = garmin?.connectionToken
        var successful = relayReceipts.outputs(for: message.id)
        let relayXML: String
        if !isGarmin, case .success(let identity) = watchIdentity {
            relayXML = AlertLocationHistory.fillingMissingAlertLocation(xml, ownUID: identity.uid,
                                                                       fix: alertLocations.lastKnown())
        } else { relayXML = xml }
        if let header = PhonePLI.header(relayXML),
           header.type == "b-a-o" || header.type.hasPrefix("b-a-o-") || header.type == "b-a-g",
           case .success(let identity) = watchIdentity {
            if header.type == "b-a-o-can" || header.type.hasPrefix("b-a-o-can-") {
                activePhoneEmergencies.removeValue(forKey: header.uid)
            } else if header.uid.hasPrefix(identity.uid + "-alert-") || header.uid.hasPrefix(identity.uid + ".garmin-") {
                activePhoneEmergencies[header.uid] = ActivePhoneEmergency(xml: relayXML, ownUID: identity.uid,
                                                                         lastFixAt: alertLocations.lastKnown()?.timestamp)
                reporter.requestFreshLocation()
            }
            reporter.setEmergencyActive(!activePhoneEmergencies.isEmpty || !pendingGarminEmergencies.isEmpty)
        }
        var ready = readyOutputs()
        if let target = message.serverID {
            guard enabledSourceIDs.contains(target), let send = ready[target] else {
                throw CompanionFailure.message("The contact's TAK server is not connected. Message not sent.")
            }
            ready = [target: send]
        }
        for (id, send) in ready where !successful.contains(id) {
            if isGarmin && (watchRoute != .garmin || generation != garminGeneration ||
                            garmin?.connectionToken != connectionToken) { break }
            if shouldSuppressWatchPLI(xml, serverID: id) {
                successful.insert(id)
                continue
            }
            do {
                try await send(relayXML)
                successful.insert(id)
                relayReceipts.accept(message.id, output: id)
                do { defaults.set(try JSONEncoder().encode(relayReceipts), forKey: Self.relayReceiptsKey) }
                catch {
                    reportingLogger.error("Relay receipts could not be saved: \(error.localizedDescription, privacy: .public)")
                }
            } catch {
                reportingLogger.error("Watch relay write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard !successful.isEmpty else { throw CompanionFailure.message("No server accepted the relay write.") }
        return BridgeWire.Message(kind: .acknowledgement, id: message.id, ready: true)
    }

    private func updatePhoneReportingState(_ state: String, detail: String?) {
        phoneReporting.detail = detail
        guard phoneReporting.state != state else { return }
        phoneReporting.state = state
        publishState()
    }

    private func localizedReportingBlockReason(_ reason: String) -> String {
        switch reason {
        case "Enable a TAK server with a certificate.":
            return String(localized: "Enable a TAK server with a certificate.", table: "PhoneBridgeStatus")
        case "Location Services are off on this phone.":
            return String(localized: "Location Services are off on this phone.", table: "PhoneBridgeStatus")
        case "Location access denied. Allow it in Settings > WearTAK Companion > Location.":
            return String(localized: "Location access denied. Allow it in Settings > WearTAK Companion > Location.", table: "PhoneBridgeStatus")
        case "Location access is restricted on this phone.":
            return String(localized: "Location access is restricted on this phone.", table: "PhoneBridgeStatus")
        case "Open Companion to allow location access.":
            return String(localized: "Open Companion to allow location access.", table: "PhoneBridgeStatus")
        case "Turn on Precise Location for WearTAK Companion in Settings.":
            return String(localized: "Turn on Precise Location for WearTAK Companion in Settings.", table: "PhoneBridgeStatus")
        default:
            return reason
        }
    }

    /// Accepts identity only from the activated session of a paired watch with WearTAK installed. WatchConnectivity
    /// persists that context per paired watch, so Companion keeps no separate copy that could outlive a watch switch.
    private func refreshWatchIdentity(contextValue: Data? = nil) {
        guard watchRoute == .apple else { return }
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
        if settingsChanged, case .success = identity { requestSelfPosition() }
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
        if mapCache.retainEmergencySources(connectedAlertSourceIDs) { saveMapCache() }
        status = !canRelay ? String(localized: "Waiting for watch refresh", table: "PhoneBridgeStatus")
            : connected ? String(localized: "Connected", table: "PhoneBridgeStatus")
            : configured ? String(localized: "No connected servers", table: "PhoneBridgeStatus")
            : String(localized: "Configure on phone", table: "PhoneBridgeStatus")
        if watchRoute == .garmin {
            isWatchPaired = garminDeviceID != nil
            return
        }
        let session = WCSession.default
        isWatchPaired = WCSession.isSupported() && session.isPaired
        guard session.activationState == .activated else { return }
        var context: [String: Any] = [
            "WearTAKCompanion.serverConfigured": configured,
            "WearTAKCompanion.serverReady": canRelay && connected,
            "WearTAKCompanion.sitxSetUp": sitx.isSetUp
        ]
        if let reason = relayPauseReason { context["WearTAKCompanion.relayPaused"] = reason }
        do {
            context[SitxSettingsSnapshot.contextKey] = try JSONEncoder().encode(sitx.settingsSnapshot)
            context[DittoBridgeStatus.contextKey] = try JSONEncoder().encode(dittoStatus)
            if let state = routeNavigationState { context[RouteNavigationState.contextKey] = try state.encoded() }
            try session.updateApplicationContext(context)
            watchSetupError = nil
        } catch {
            watchSetupError = "Unable to update watch setup state: \(error.localizedDescription)"
        }
        if session.isReachable, let data = try? snapshot().encoded() {
            session.sendMessageData(data, replyHandler: nil, errorHandler: { _ in })
        }
    }

    private var connectedAlertSourceIDs: Set<UUID> {
        var ids = Set(enabledSourceIDs.filter { serverStates[$0]?.connected == true })
        if dittoStatus.state == .syncing { ids.insert(DittoCoTDocument.sourceID) }
        return ids
    }

    /// Ditto is a data-only source independent of TAK connectivity. Never dispatch packages or commands here.
    private func receiveDitto(_ xml: String) {
        guard watchRoute == .apple, dittoStatus.enabled else { return }
        let source = DittoCoTDocument.sourceID
        let event = CompanionMapEvent(xml: xml, sourceServerID: source, sourceGeneration: 0, receivedAt: Date())
        if event.header?.type == "b-t-f" {
            if chatBuffer.receive(event) { chatLogger.warning("Ditto chat buffer evicted oldest messages") }
        } else {
            mapCache.receive(event)
            mapCacheWrites.schedule()
        }
        guard WCSession.default.isReachable, incomingInFlight < 16 else { return }
        do {
            let data = try BridgeWire.Message(kind: .cot, xml: xml, sourceServerID: source,
                sourceGeneration: 0, sessionID: bridgeSessionID).encoded()
            incomingInFlight += 1
            WCSession.default.sendMessageData(data, replyHandler: { [weak self] _ in
                Task { @MainActor in self?.incomingInFlight = max(0, (self?.incomingInFlight ?? 1) - 1) }
            }, errorHandler: { [weak self] error in
                Task { @MainActor in
                    self?.incomingInFlight = max(0, (self?.incomingInFlight ?? 1) - 1)
                    self?.chatLogger.error("Ditto watch delivery pending: \(error.localizedDescription, privacy: .public)")
                }
            })
        } catch { chatLogger.error("Ditto event exceeds bridge limits: \(error.localizedDescription, privacy: .public)") }
    }

    private func appleRouteSnapshot(id: UUID = UUID()) -> BridgeWire.Message {
        BridgeWire.Message(kind: .routes, id: id,
            routes: garminRoutes.routes.filter { route in
                enabledSourceIDs.contains { $0.uuidString == route.serverId }
            }, routeError: routePackageError)
    }

    private func publishAppleRoutes() {
        guard watchRoute == .apple, WCSession.default.isReachable else { return }
        appleRouteWrites.schedule()
    }

    private func sendAppleRoutes() {
        guard watchRoute == .apple, WCSession.default.isReachable else { return }
        do {
            let data = try appleRouteSnapshot().encoded()
            WCSession.default.sendMessageData(data, replyHandler: nil, errorHandler: { [weak self] error in
                Task { @MainActor in
                    self?.chatLogger.error("Route snapshot delivery failed: \(error.localizedDescription, privacy: .public)")
                }
            })
        } catch {
            chatLogger.error("Route snapshot encoding failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func receiveRoutePackage(_ xml: String, sourceID: UUID) -> Bool {
        guard xml.contains("b-f-t-r") else { return false }
        do {
            guard let advertisement = try TAKRoutePackage.Advertisement.parse(xml) else { return false }
            guard servers.contains(where: { $0.id == sourceID && $0.enabled }),
                  let session = sessions[sourceID] else {
                throw CompanionFailure.message("Route Data Packages require a configured TAK server. Sit(x) and multicast package downloads are not supported.")
            }
            guard !routePackageInFlight.contains(sourceID), routePackageInFlight.count < 2,
                  routePackageAttempts[sourceID].map({ Date().timeIntervalSince($0) >= 10 }) ?? true else {
                throw CompanionFailure.message("Route package import is busy. Resend the package after 10 seconds.")
            }
            routePackageAttempts[sourceID] = Date()
            routePackageInFlight.insert(sourceID)
            let generation = sourceGenerations[sourceID, default: 0]
            Task {
                defer { routePackageInFlight.remove(sourceID) }
                do {
                    let data = try await session.routePackage(advertisement)
                    let routes = try RoutePackageZIP.routes(data, advertisement: advertisement,
                                                            serverID: sourceID.uuidString)
                    guard enabledSourceIDs.contains(sourceID),
                          sourceGenerations[sourceID, default: 0] == generation else { return }
                    routePackageError = nil
                    try updateGarminRoutes { store in
                        for route in routes { try store.upsert(route) }
                    }
                    publishAppleRoutes()
                } catch {
                    guard enabledSourceIDs.contains(sourceID),
                          sourceGenerations[sourceID, default: 0] == generation else { return }
                    routePackageError = "Route package import failed: \(error.localizedDescription)"
                    chatLogger.error("Route package import failed: \(error.localizedDescription, privacy: .public)")
                    publishAppleRoutes()
                    if watchRoute == .garmin {
                        reportGarminRouteError("Route package import failed: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            routePackageError = error.localizedDescription
            chatLogger.error("Route package rejected: \(error.localizedDescription, privacy: .public)")
            publishAppleRoutes()
            if watchRoute == .garmin { reportGarminRouteError(error.localizedDescription) }
        }
        return true
    }

    private func forward(_ xml: String, sourceID: UUID) {
        if receiveRoutePackage(xml, sourceID: sourceID) { return }
        let event = CompanionMapEvent(xml: xml, sourceServerID: sourceID,
                                      sourceGeneration: sourceGenerations[sourceID, default: 0], receivedAt: Date())
        let isChat = event.header?.type == "b-t-f"
        if isChat { chatLogger.notice("Server GeoChat received") }
        if isChat, chatBuffer.receive(event) {
            chatLogger.warning("GeoChat buffer limit reached; oldest messages evicted")
        }
        if event.isValid { lastMapEventReceivedAt = event.receivedAt }
        mapCache.receive(event)
        mapCacheWrites.schedule()
        // Delete events and routes need not contain a valid anchor point, unlike entity-cache headers.
        let isRoute = receiveGarminRoutes(xml, sourceID: sourceID)
        if isRoute { return }
        if watchRoute == .garmin {
            guard canRelay, connected, garminReady, let envelope = try? GarminRelayProtocol.incoming(xml,
                ownUID: garminIdentity?.uid ?? "", receivedAt: event.receivedAt) else {
                return
            }
            enqueueGarmin(envelope)
            return
        }
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
        Task { @MainActor [weak self] in
            guard self?.watchRoute == .apple else { return }
            self?.refreshWatchIdentity()
            if let data = session.receivedApplicationContext[RouteNavigationState.contextKey] as? Data {
                self?.receiveRouteNavigation(data)
            }
            self?.publishRouteNavigation()
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            guard self?.watchRoute == .apple else { return }
            self?.refreshWatchIdentity()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let data = applicationContext[WatchReportingIdentity.contextKey] as? Data
        let navigation = applicationContext[RouteNavigationState.contextKey] as? Data
        Task { @MainActor [weak self] in
            guard self?.watchRoute == .apple else { return }
            if let data { self?.refreshWatchIdentity(contextValue: data) }
            if let navigation { self?.receiveRouteNavigation(navigation) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = message[RouteNavigationState.contextKey] as? Data else { return }
        Task { @MainActor [weak self] in self?.receiveRouteNavigation(data) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.publishState()
            self?.publishRouteNavigation()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor [weak self] in
            guard self?.watchRoute == .apple else { return }
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
                replyHandler(try await self.processWatchMessage(message).encoded())
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
        if enabled.isEmpty, !sitx.isConfigured, dittoStatus.state != .syncing {
            failures.append("Enable a TAK server or Ditto in Companion on the phone.")
        }
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
            phoneReporting: phoneReportingSummary, phoneLocationEnabled: reporter.isRunning, sitxStatus: sitxStatusSummary ?? "",
            sitxSettings: sitx.settingsSnapshot, relayPaused: relayPauseReason,
            remoteAlertSourceIDs: Array(connectedAlertSourceIDs))
        return try mapCache.filling(reply)
    }

    private func channelReply(to message: BridgeWire.Message) async -> BridgeWire.Message {
        var snapshots = servers.filter(\.enabled).map { record in
            TAKChannelServer(id: record.id, name: record.displayLabel,
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
            TAKMissionServer(id: record.id, name: record.displayLabel,
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
                    try updateGarminRoutes { $0.retainMissions(serverId: id.uuidString, names: names) }
                    missionLogger.notice("Data Sync \(subscribe ? "subscribed to" : "unsubscribed from", privacy: .public) mission on \(snapshots[index].name, privacy: .public)")
                }
                if message.kind == .missionUpdate, id == message.serverID,
                   let name = message.missionName, let removeUID = message.missionRemoveUID {
                    guard let uid = message.clientUID, !uid.isEmpty,
                          let path = TAKMissionAPI.path(name, "/contents") else { throw TAKMissionAPI.Failure.invalidName }
                    do {
                        _ = try await request(path, "DELETE", [URLQueryItem(name: "uid", value: removeUID),
                                                                URLQueryItem(name: "creatorUid", value: uid)])
                        try updateGarminRoutes { $0.removeMissionItem(serverId: id.uuidString, name: name, uid: removeUID) }
                        missionLogger.notice("Data Sync removed an item from a mission on \(snapshots[index].name, privacy: .public)")
                    } catch {
                        missionLogger.error("Data Sync item removal failed: \(error.localizedDescription, privacy: .public)")
                        removalError = TAKMissionAPI.removalMessage(error.localizedDescription)
                    }
                }
                var missions = try TAKMissionAPI.parseList(await request("/missions", "GET", []))
                let listed = Set(missions.map(\.name))
                // A joined mission missing from one listing is kept (its watch items stay) unless the server
                // confirms it no longer exists, so a partial or transient listing cannot drop subscriptions.
                for name in names.subtracting(listed).sorted() {
                    guard let path = TAKMissionAPI.path(name) else { names.remove(name); continue }
                    do {
                        _ = try await request(path, "GET", [])
                    } catch where TAKMissionAPI.isNotFound(error) {
                        names.remove(name)
                        missionLogger.notice("Data Sync dropped a deleted mission on \(snapshots[index].name, privacy: .public)")
                        continue
                    } catch {}
                    missions.append(TAKMission(name: name, error: "Mission not listed by the server; keeping saved items."))
                }
                setSubscribedMissions(names, for: id)
                try updateGarminRoutes { $0.retainMissions(serverId: id.uuidString, names: names) }
                for i in missions.indices where names.contains(missions[i].name) {
                    missions[i].subscribed = true
                    guard missions[i].error == nil else { continue }
                    if let uid = message.clientUID, !uid.isEmpty, let path = TAKMissionAPI.path(missions[i].name, "/subscription") {
                        let query = [URLQueryItem(name: "uid", value: uid)]
                        var role = try? await request(path, "GET", query)
                        if role == nil, (try? await request(path, "PUT", query)) != nil {
                            // The server lost this UID's subscription (for example after a reconnect); restore it.
                            missionLogger.notice("Data Sync restored a mission subscription on \(snapshots[index].name, privacy: .public)")
                            role = try? await request(path, "GET", query)
                        }
                        missions[i].canEdit = role.flatMap(TAKMissionAPI.parseCanEdit)
                    }
                    guard let path = TAKMissionAPI.path(missions[i].name, "/cot") else {
                        missions[i].error = "Watch item limit reached."
                        continue
                    }
                    do {
                        let limit = min(budget, TAKMissionAPI.maximumItemsPerMission)
                        let routeGeneration = sourceGenerations[id, default: 0]
                        let data = try await request(path, "GET", [])
                        if enabledSourceIDs.contains(id),
                           sourceGenerations[id, default: 0] == routeGeneration,
                           subscribedMissions(id).contains(missions[i].name) {
                            do {
                                let events = try GarminRouteCoT.parse(data, serverId: id.uuidString,
                                                                     missionName: missions[i].name)
                                let routes = events.compactMap { event -> GarminRoute? in
                                    if case .route(let route) = event { return route }
                                    return nil
                                }
                                routePackageError = nil
                                try updateGarminRoutes {
                                    try $0.replaceMission(serverId: id.uuidString, name: missions[i].name, routes: routes)
                                }
                            } catch {
                                routePackageError = error.localizedDescription
                                if watchRoute == .apple { publishAppleRoutes() }
                                else { reportGarminRouteError(error.localizedDescription) }
                                missions[i].error = error.localizedDescription
                            }
                        }
                        var items = TAKMissionAPI.parseItems(data,
                                                             limit: TAKMissionAPI.maximumParsedItems)
                        items.removeAll { $0.type == "b-m-r" || $0.type.hasPrefix("b-m-r-") }
                        let available = items.count
                        items = TAKMissionAPI.nearest(items, limit: limit, latitude: message.latitude, longitude: message.longitude)
                        missions[i].items = items
                        missions[i].itemTotal = items.count
                        missionItemPages[Self.missionPageKey(id, missions[i].name)] = items
                        if available > items.count, missions[i].error == nil {
                            let scope = message.latitude == nil ? "first" : "nearest"
                            missions[i].error = "Showing \(scope) \(items.count) of \(available) items (watch limit)."
                        }
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
        // Items that do not fit stay counted in `itemTotal`; the watch pages them in with `missionItemOffset`.
        while (try? reply.encoded()) == nil {
            guard var servers = reply.missionServers,
                  let s = servers.indices.last(where: { servers[$0].missions.contains { !($0.items ?? []).isEmpty } }),
                  let m = servers[s].missions.indices.last(where: { !(servers[s].missions[$0].items ?? []).isEmpty }),
                  let count = servers[s].missions[m].items?.count else { break }
            servers[s].missions[m].items?.removeLast(max(1, (count + 1) / 2))
            reply.missionServers = servers
        }
        return reply
    }

    private static func missionPageKey(_ serverID: UUID, _ name: String) -> String { serverID.uuidString + "\n" + name }

    /// One page of a mission's last loaded items, as large as fits in a watch message.
    fileprivate func missionItemPageReply(to message: BridgeWire.Message) -> BridgeWire.Message {
        var reply = BridgeWire.Message(kind: .missions, id: message.id, sessionID: bridgeSessionID)
        guard let serverID = message.serverID, let name = message.missionName, let offset = message.missionItemOffset,
              let items = missionItemPages[Self.missionPageKey(serverID, name)], offset < items.count else {
            reply.detail = "Mission items changed. Reload Data Sync."
            return reply
        }
        reply.serverID = serverID
        reply.missionName = name
        reply.missionItemOffset = offset
        var page = Array(items[offset...].prefix(TAKMissionAPI.maximumItemsPerMission))
        reply.missionItems = page
        while (try? reply.encoded()) == nil, page.count > 1 {
            page.removeLast((page.count + 1) / 2)
            reply.missionItems = page
        }
        return reply
    }
}

@MainActor
private final class CompanionServerSession {
    var onState: ((PhoneBridgeModel.ServerState) -> Void)?
    var onCoT: ((String) -> Void)?
    var onChannelsChanged: (() -> Void)?
    var onTLSMismatch: ((Bool) async throws -> Void)?
    private var streamApprovalTask: Task<Void, Never>?
    private(set) var state = PhoneBridgeModel.ServerState()
    private let connection = TAKServerConnection()
    private var record: CompanionServer?
    private var active = true
    private var retryTask: Task<Void, Never>?
    private var channelClient: TAKChannelClient?

    init() {
        connection.onState = { [weak self] ready, detail in
            guard let self else { return }
            if ready, !self.state.connected { self.state.connectedSince = Date() }
            if !ready { self.state.connectedSince = nil }
            if !ready, detail != "Connecting" { self.state.lastError = detail; self.state.lastErrorAt = Date() }
            self.state.connected = ready
            self.state.detail = detail
            self.onState?(self.state)
            if ready { self.retryTask?.cancel(); self.retryTask = nil }
            else if detail != "Connecting" { self.retry() }
        }
        connection.onCoT = { [weak self] xml in self?.onCoT?(xml) }
        connection.onHostnameMismatch = { [weak self] in
            guard let self, self.streamApprovalTask == nil else { return }
            self.streamApprovalTask = Task {
                defer { self.streamApprovalTask = nil }
                do {
                    guard let approve = self.onTLSMismatch else { return }
                    try await approve(false)
                } catch {
                    self.state.lastError = error.localizedDescription
                    self.state.lastErrorAt = Date()
                    self.onState?(self.state)
                }
            }
        }
    }

    func configure(_ record: CompanionServer, active: Bool) {
        var previous = self.record
        // API identity and display-name changes do not interrupt the CoT stream.
        previous?.apiTLSName = record.apiTLSName
        previous?.name = record.name
        let changed = previous != record || self.active != active
        self.record = record
        self.active = active
        if changed { stop() }
        do {
            if let stored = try CertificateStore.read(endpoint: record.endpoint.key) {
                state.certificateExpires = try CertificateStore.resolve(stored).expires
                state.configured = true
            } else { state.configured = false; state.certificateExpires = nil }
            if !active { state.detail = String(localized: "Paused in background", table: "PhoneBridgeStatus") }
            else if !record.enabled { state.detail = String(localized: "Disabled", table: "PhoneBridgeStatus") }
            else if !state.configured { state.detail = String(localized: "Configure certificate", table: "PhoneBridgeStatus") }
            else if !connection.ready && state.detail != "Connecting" { connect() }
        } catch { state.configured = false; state.certificateExpires = nil; state.detail = error.localizedDescription }
        onState?(state)
    }

    /// Drops the current stream and reconnects immediately instead of waiting for the retry timer.
    func reconnect() {
        guard let record else { return }
        stop()
        configure(record, active: active)
    }

    private func connect() {
        guard let record, record.enabled, active, state.configured else { return }
        do {
            guard let stored = try CertificateStore.read(endpoint: record.endpoint.key) else { throw CompanionFailure.message("Certificate required.") }
            let ca = UserDefaults.standard.data(forKey: "WearTAK.bridge.serverCA.\(record.endpoint.key)")
            try connection.connect(endpoint: record.endpoint, identity: CertificateStore.resolve(stored),
                                   trustedCA: ca, streamTLSName: record.streamTLSName)
        } catch {
            state.detail = error.localizedDescription
            state.connected = false
            state.lastError = state.detail
            state.lastErrorAt = Date()
            onState?(state)
        }
    }

    func stop() {
        retryTask?.cancel()
        retryTask = nil
        connection.disconnect()
        channelClient?.cancel()
        channelClient = nil
        state.connected = false
        state.connectedSince = nil
        state.detail = String(localized: "Disabled", table: "PhoneBridgeStatus")
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
        let client = try TAKChannelClient(host: record.host, identity: CertificateStore.resolve(stored),
                                          trustedCA: ca, apiTLSName: record.apiTLSName)
        channelClient = client
        return client
    }

    func loadChannels() async throws -> TAKChannelGroups {
        try await retryAPIOnApproval { try await self.loadChannelsOnce() }
    }

    private func loadChannelsOnce() async throws -> TAKChannelGroups {
        let client = try makeChannelClient()
        defer { client.cancel(); channelClient = nil }
        return try await client.load(checkSupport: true, sendLatestSA: true)
    }

    func refreshLatestSA() async throws {
        try await retryAPIOnApproval { try await self.refreshLatestSAOnce() }
    }

    private func refreshLatestSAOnce() async throws {
        guard active, state.connected, let record,
              let stored = try CertificateStore.read(endpoint: record.endpoint.key) else {
            throw CompanionFailure.message("TAK server is not connected.")
        }
        let ca = UserDefaults.standard.data(forKey: "WearTAK.bridge.serverCA.\(record.endpoint.key)")
        let client = try TAKChannelClient(host: record.host, identity: CertificateStore.resolve(stored),
                                          trustedCA: ca, requestTimeout: 3, apiTLSName: record.apiTLSName)
        defer { client.cancel() }
        _ = try await client.load(checkSupport: false, sendLatestSA: true)
    }

    func missionRequest(path: String, method: String = "GET", query: [URLQueryItem] = []) async throws -> Data {
        try await retryAPIOnApproval { try await self.missionRequestOnce(path: path, method: method, query: query) }
    }

    func routePackage(_ advertisement: TAKRoutePackage.Advertisement) async throws -> Data {
        guard active, state.connected, let record, record.enabled,
              let stored = try CertificateStore.read(endpoint: record.endpoint.key) else {
            throw CompanionFailure.message("TAK server is not connected.")
        }
        let ca = UserDefaults.standard.data(forKey: "WearTAK.bridge.serverCA.\(record.endpoint.key)")
        let client = try TAKChannelClient(host: record.host, identity: CertificateStore.resolve(stored),
                                          trustedCA: ca, requestTimeout: 20, apiTLSName: record.apiTLSName)
        defer { client.cancel() }
        return try await client.routePackage(advertisement)
    }

    private func missionRequestOnce(path: String, method: String, query: [URLQueryItem]) async throws -> Data {
        guard active, state.connected, let record, record.enabled,
              let stored = try CertificateStore.read(endpoint: record.endpoint.key) else {
            throw CompanionFailure.message("TAK server is not connected.")
        }
        let ca = UserDefaults.standard.data(forKey: "WearTAK.bridge.serverCA.\(record.endpoint.key)")
        let client = try TAKChannelClient(host: record.host, identity: CertificateStore.resolve(stored),
                                          trustedCA: ca, requestTimeout: 20, apiTLSName: record.apiTLSName)
        defer { client.cancel() }
        return try await client.missionRequest(path: path, method: method, query: query)
    }

    func updateChannel(bit: Int, active: Bool, clientUID: String) async throws -> TAKChannelGroups {
        try await retryAPIOnApproval { try await self.updateChannelOnce(bit: bit, active: active, clientUID: clientUID) }
    }

    private func updateChannelOnce(bit: Int, active: Bool, clientUID: String) async throws -> TAKChannelGroups {
        let client = try makeChannelClient()
        defer { client.cancel(); channelClient = nil }
        _ = try await client.update(bitPosition: bit, active: active, clientUID: clientUID)
        onChannelsChanged?()
        return try await client.load(checkSupport: false, sendLatestSA: true)
    }

    private func retryAPIOnApproval<T>(_ operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch let mismatch as TLSHostnameMismatch {
            guard let approve = onTLSMismatch else { throw mismatch }
            try await approve(true)
            return try await operation()
        }
    }
}