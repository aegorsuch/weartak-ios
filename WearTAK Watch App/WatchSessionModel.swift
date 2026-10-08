import Combine
import CoreLocation
import Foundation
import Network
import OSLog
import WatchKit
import WatchConnectivity

enum ConnectionState: String {
    case disconnected = "Offline"
    case connecting = "Connecting"
    case connected = "Connected"
    case unconfigured = "Relay not configured"
    case failed = "Connection failed"
}

enum EmergencyState: String, Codable {
    case alert = "ALERT"
    case cancel = "CANCEL"
}

enum ManualAlertType: String, CaseIterable, Identifiable {
    case gateRunner = "Gate Runner"
    case gunshot = "Gunshot"
    case gunshotInjury = "Gunshot Injury"
    case injury = "Injury"
    case uas = "UAS"
    case vehicle = "Vehicle"

    var id: Self { self }
}

struct WatchMarker: Identifiable, Codable {
    let id: UUID
    var kind: MarkerKind
    var latitude: Double
    var longitude: Double
    let createdAt: Date
    var title: String?
    var remark: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var displayTitle: String {
        title.flatMap { $0.isEmpty ? nil : $0 } ?? defaultLabel
    }

    // Matches Garmin's "<Type> 2525D point" default label.
    private var defaultLabel: String {
        switch kind {
        case .friendly: return String(localized: "Friendly 2525D point", table: "WatchStatus")
        case .neutral: return String(localized: "Neutral 2525D point", table: "WatchStatus")
        case .unknown: return String(localized: "Unknown 2525D point", table: "WatchStatus")
        case .hostile: return String(localized: "Hostile 2525D point", table: "WatchStatus")
        }
    }
}

struct IncomingMapEntity: Identifiable {
    let id: String
    let latitude: Double
    let longitude: Double
    let type: String
    let lastSeen: Date
    let callSign: String?
    let team: String?
    let role: String?
    let senderUID: String?
    let sourceServerID: UUID?
    let sourceGeneration: Int
    let expiresAt: Date?
    let isUser: Bool
    var sourceTransport: ContactChatRoute? = nil
    /// Data Sync mission holding this item; mission items stay on the map while subscribed.
    var missionName: String? = nil
    var alertCategory: String? = nil
    var isAlert: Bool = false

    var chatRoute: ContactChatRoute? {
        if let sourceServerID { return .companion(sourceServerID) }
        return sourceTransport
    }

    var teamColor: TeamColor? { TeamColor(cotName: team) }
    var roleBadge: String? { SitxCoT.roleBadge(role) }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// 2525D affiliation from a CoT atom type (`a-<affiliation>-...`); nil for non-symbol types such as `b-m-p-*`.
    var symbolKind: MarkerKind? { MarkerKind(cotType: type) }
}

enum MarkerKind: String, CaseIterable, Identifiable, Codable {
    case friendly = "Friendly"
    case neutral = "Neutral"
    case unknown = "Unknown"
    case hostile = "Hostile"

    var id: String { rawValue }

    /// Maps CoT atom affiliations: assumed friend → friendly; suspect, joker, faker → hostile;
    /// pending and other → unknown.
    init?(cotType: String) {
        let parts = cotType.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "a" else { return nil }
        switch parts[1] {
        case "f", "a": self = .friendly
        case "h", "s", "j", "k": self = .hostile
        case "n": self = .neutral
        case "u", "p", "o": self = .unknown
        default: return nil
        }
    }
}

struct BloodhoundDestination {
    let latitude: Double
    let longitude: Double
    let displayTitle: String
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

struct ContactConversation: Hashable, Identifiable {
    let uid: String
    let route: ContactChatRoute
    var id: Self { self }
}

enum ContactChatRoute: Hashable, Codable {
    case companion(UUID), multicast, sitx
}

private enum ContactChatFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}

enum PLIReportingRoute {
    case phoneRelay
    case standaloneSitx
}

@MainActor
protocol TAKTransport {
    var pliReportingRoute: PLIReportingRoute { get }
    func connect() async throws
    func sendPLI(coordinate: CLLocationCoordinate2D, reportingInterval: TimeInterval) async throws
    func sendMarker(_ marker: WatchMarker) async throws
    func deleteMarker(uid: String) async throws
    func sendEmergencyAlert(state: EmergencyState, type: String) async throws
    func incomingEntities() -> AsyncStream<EntityRelayPayload>
}

extension TAKTransport {
    var pliReportingRoute: PLIReportingRoute { .phoneRelay }
}

enum TAKTransportError: Error {
    case notConfigured
}

struct UnconfiguredTAKTransport: TAKTransport {
    func connect() async throws { throw TAKTransportError.notConfigured }
    func sendPLI(coordinate: CLLocationCoordinate2D, reportingInterval: TimeInterval) async throws {
        throw TAKTransportError.notConfigured
    }
    func sendMarker(_ marker: WatchMarker) async throws { throw TAKTransportError.notConfigured }
    func deleteMarker(uid: String) async throws { throw TAKTransportError.notConfigured }
    func sendEmergencyAlert(state: EmergencyState, type: String) async throws { throw TAKTransportError.notConfigured }
    func incomingEntities() -> AsyncStream<EntityRelayPayload> {
        AsyncStream { continuation in continuation.finish() }
    }
}

@MainActor
final class WatchSessionModel: NSObject, ObservableObject {
    private let chatLogger = Logger(subsystem: "com.aegorsuch.weartak", category: "GeoChat")
    private var offlineOutbox: OfflineOutbox?
    private var forwardingOffline = false
    private var lastOfflineAttempt: Date?
    @Published var offlineNotice: String?
    @Published var offlineExpiryNotice: String?
    @Published private(set) var queuedEventCount = 0
    static var markerStoredMessage: String {
        String(localized: "Marker details stored and will be sent when connected and/or location is updated", table: "WatchStatus")
    }

    private struct OfflineOperation: Codable {
        enum Kind: String, Codable { case marker, delete, alert, chat }
        let kind: Kind
        let scope: String
        var marker: WatchMarker?
        var markerID: UUID?
        var markerKind: MarkerKind?
        var title: String?
        var remark: String?
        var alertState: EmergencyState?
        var alertType: String?
        var xml: String?
        var route: ContactChatRoute?
        var recipientUID: String?
    }
    private static let markerStorageKey = "WearTAK.droppedPoints"
    private static let companionCacheKey = "WearTAK.cachedCompanionMap"
    private static let missionItemsKey = "WearTAK.dataSyncMissionItems"
    static let missionSubscriptionsFlagKey = "WearTAK.dataSyncHasSubscriptions"
    private static let maximumLiveEntities = 50
    private var companionMapCache = CompanionMapCache()
    @Published private(set) var mapCacheError: String?

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var companionServerConfigured = false
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var markers: [WatchMarker] = []
    @Published private(set) var incomingEntities: [IncomingMapEntity] = []
    var incomingUserTeams: [MapUserGroup] {
        MapUserGroup.make(values: incomingEntities.filter(\.isUser).compactMap(\.team))
    }
    var incomingUserRoles: [MapUserGroup] {
        MapUserGroup.make(values: incomingEntities.filter(\.isUser).compactMap(\.role))
    }
    @Published private(set) var bloodhoundTargetID: UUID?
    @Published private(set) var bloodhoundContactID: String?
    @Published private(set) var bloodhoundMapItemID: String?
    @Published private(set) var unseenIncomingPointIDs: Set<String> = []
    private var dismissedPointIDs: [String: Date] = [:]
    private var liveLocationRequested = false
    private static let dismissedPointsKey = "WearTAK.dismissedIncomingPoints"
    /// Latest CoT `time` seen per point, so a sender's re-send notifies again but reconnect replays do not.
    private var pointSendTimes: [String: Date] = [:]
    private static let pointSendTimesKey = "WearTAK.incomingPointSendTimes"
    private var clearedAlertSendTimes: [String: Date] = [:]
    private static let clearedAlertSendTimesKey = "WearTAK.clearedAlertSendTimes"
    private static let mapItemReplyLifetime: TimeInterval = 24 * 60 * 60
    @Published private var chatInbox = TAKChatInbox<ContactConversation>()

    var contactMessages: [ContactConversation: [TAKChatMessage]] { chatInbox.messages }
    var unreadChatCounts: [ContactConversation: Int] { chatInbox.unreadCounts }
    var unreadChatCount: Int { chatInbox.unreadCount }

    var chatConversations: [ContactConversation] { chatInbox.conversations }
    var incomingMapPoints: [IncomingMapEntity] { incomingEntities.filter { !$0.isUser } }
    /// Points offered in the Bloodhound order list; Data Sync items stay on the map only.
    var bloodhoundOrderPoints: [IncomingMapEntity] {
        let points = incomingEntities.filter { !$0.isUser && $0.missionName == nil }
        return points.filter(\.isAlert).sorted { $0.lastSeen > $1.lastSeen } + points.filter { !$0.isAlert }
    }

    func chatTitle(for conversation: ContactConversation) -> String {
        if let sender = contactMessages[conversation]?.last(where: { $0.senderUID == conversation.uid }) {
            return sender.senderCallSign
        }
        return incomingEntities.first { $0.id == conversation.uid && $0.chatRoute == conversation.route }?.callSign ??
            conversation.uid
    }

    func setConversationVisible(_ conversation: ContactConversation, visible: Bool) {
        chatInbox.setVisible(conversation, visible: visible)
    }
    @Published private(set) var headingDegrees: Double?
    @Published private(set) var activeAlertType: ManualAlertType?
    @Published private(set) var activeAutomaticAlert: AutomaticAlertCategory?
    @Published private(set) var activeEnvironmentalAlerts: Set<EnvironmentalAlertCategory> = []
    @Published private(set) var automaticAlertDeliveryFailed = false
    @Published var selectedMarkerKind: MarkerKind = .unknown {
        didSet { UserDefaults.standard.set(selectedMarkerKind.rawValue, forKey: "WearTAK.lastMarkerKind") }
    }

    private let locationManager = CLLocationManager()
    private let transport: TAKTransport
    let sitxClient: SitxClient
    let multicastClient: MulticastTAKTransport
    let companionClient: WatchCompanionOutput
    private let settings: AppSettings
    private var connectionTask: Task<Void, Never>?
    private var reportingTimer: Timer?
    private var identitySubscription: AnyCancellable?
    private var sitxRelaySubscriptions: Set<AnyCancellable> = []
    private var isSendingPLI = false
    #if DEBUG && targetEnvironment(simulator)
    private var simulatedBiometricsTimer: Timer?
    #endif
    private var isAppActive = true
    private var lastFixRequestAt: Date?
    private var incomingEntityTask: Task<Void, Never>?
    private var incomingPruneTimer: Timer?
    private var bloodhoundProximityNotified = false
    private var isUpdatingHeading = false
    private var lastPLISentAt: Date?
    private var sourceGenerations: [UUID: Int] = [:]
    private let networkPathMonitor = NWPathMonitor()
    @Published private(set) var networkConnectivity: DashboardNetworkConnectivity = .offline
    @Published private(set) var watchLocationEnabled = false
    var isOnWiFi: Bool { networkConnectivity == .wifi }
    var isPhoneRelayConnected: Bool {
        companionClient.isReady
    }

    init(transport: TAKTransport? = nil, settings: AppSettings) {
        let client = SitxClient(settings: settings)
        sitxClient = (transport as? SitxClient) ?? client
        multicastClient = MulticastTAKTransport(settings: settings)
        companionClient = WatchCompanionOutput(settings: settings)
        sitxClient.additionalOutput = multicastClient
        sitxClient.companionOutput = companionClient
        self.transport = transport ?? client
        self.settings = settings
        super.init()
        do {
            offlineOutbox = try OfflineOutbox()
            expireOfflineEvents()
        } catch { reportOfflineError(error) }
        identitySubscription = settings.$callSign
            .combineLatest(settings.$teamColor, settings.$role)
            .dropFirst()
            .sink { [weak self] _, _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.lastPLISentAt = nil
                    guard self.isAppActive, self.connectionState == .connected else { return }
                    self.requestLocation()
                }
            }
        selectedMarkerKind = MarkerKind(rawValue: UserDefaults.standard.string(forKey: "WearTAK.lastMarkerKind") ?? "") ?? .unknown
        if let savedAlert = UserDefaults.standard.string(forKey: "WearTAK.manualAlertType") {
            activeAlertType = ManualAlertType(rawValue: savedAlert)
        }
        sitxClient.onReady = { [weak self] in self?.connect() }
        sitxClient.onDisconnected = { [weak self] in
            guard let self, !self.sitxClient.hasReadyOutput else { return }
            self.connectionTask?.cancel()
            self.connectionState = .disconnected
            self.stopLocationUpdatesIfIdle()
            self.incomingEntityTask?.cancel()
        }
        multicastClient.onStateChange = { [weak self] in
            guard let self else { return }
            if self.multicastClient.isReady {
                self.connect()
            } else if !self.sitxClient.hasReadyOutput {
                self.connectionState = .disconnected
                self.stopLocationUpdatesIfIdle()
            }
        }
        multicastClient.onEntity = { [weak self] entity in
            self?.receiveEntity(entity, sourceTransport: .multicast, notifyNewPoint: true)
        }
        multicastClient.onChat = { [weak self] chat in self?.recordChat(chat, route: .multicast) }
        sitxClient.onChat = { [weak self] chat in self?.recordChat(chat, route: .sitx) }
        let companion = companionClient
        sitxClient.relayHandler = { config in try await companion.sendSitxConfig(config) }
        sitxClient.onRelayChange = { [weak self] in
            guard let self else { return }
            self.companionClient.sitxRelayRequested = self.sitxClient.isRelayedViaPhone
        }
        companionClient.sitxRelayRequested = sitxClient.isRelayedViaPhone
        companionClient.$sitxRelayStatus.removeDuplicates().sink { [weak self] status in
            Task { @MainActor [weak self] in self?.sitxClient.phoneRelayStatus = status }
        }.store(in: &sitxRelaySubscriptions)
        companionClient.$sitxSettings.removeDuplicates().sink { [weak self] settings in
            Task { @MainActor [weak self] in self?.sitxClient.applyPhoneSettings(settings) }
        }.store(in: &sitxRelaySubscriptions)
        companionClient.$isPhoneReachable.removeDuplicates().sink { [weak self] reachable in
            Task { @MainActor [weak self] in self?.sitxClient.canReachPhone = reachable }
        }.store(in: &sitxRelaySubscriptions)
        companionClient.onStateChange = { [weak self] in
            guard let self else { return }
            self.companionServerConfigured = self.companionClient.configured
            self.sitxClient.isPhoneReachable = self.companionClient.isReady
            if self.sitxClient.hasReadyOutput { self.connect() }
            else {
                self.connectionState = .disconnected
                self.stopLocationUpdatesIfIdle()
            }
        }
        companionClient.onCoT = { [weak self] message in
            guard let self, let xml = message.xml else { return }
            if let source = message.sourceServerID,
               let chat = TAKChatMessage.parse(xml, ownUID: SitxClient.deviceID()) {
                self.chatLogger.notice("Companion GeoChat parsed for this watch")
                self.recordChat(chat, route: .companion(source))
                return
            }
            let now = Date()
            let header = CoTMapHeader.parse(xml)
            if header?.type == "b-t-f" {
                self.chatLogger.notice("Companion GeoChat ignored: missing source, unrelated recipient or invalid message")
            }
            let seen = min(header?.time ?? now, now)
            if let id = message.sourceServerID {
                self.companionMapCache.receive(CompanionMapEvent(xml: xml, sourceServerID: id,
                    sourceGeneration: message.sourceGeneration ?? 0, receivedAt: now))
                self.companionMapCacheWrites.schedule()
            }
            for entity in SitxCoT.parse(Data(xml.utf8), excluding: SitxClient.deviceID()) {
                self.receiveEntity(entity, at: seen, sourceServerID: message.sourceServerID,
                                   sourceGeneration: message.sourceGeneration ?? 0, expiresAt: header?.stale,
                                   notifyNewPoint: true)
            }
            self.pruneIncomingEntities(now: now)
        }
        companionClient.onMapSnapshot = { [weak self] events, enabled in
            guard let self else { return }
            let ids = Set(enabled)
            self.incomingEntities.removeAll { $0.sourceServerID.map { !ids.contains($0) } ?? false }
            self.companionMapCache.prune(enabledServerIDs: ids)
            for event in events where ids.contains(event.sourceServerID) && event.isCurrent(at: Date()) {
                self.companionMapCache.receive(event)
                for entity in SitxCoT.parse(Data(event.xml.utf8), excluding: SitxClient.deviceID()) {
                    self.receiveEntity(entity, at: event.lastSeen, sourceServerID: event.sourceServerID,
                                       sourceGeneration: event.sourceGeneration, expiresAt: event.header?.stale)
                }
            }
            self.pruneIncomingEntities()
            self.saveCompanionMapCache()
        }
        companionClient.onSourceRefresh = { [weak self] id, generation in
            self?.refreshSource(id, generation: generation)
        }
        companionClient.onBridgeRestart = { [weak self] in
            guard let self else { return }
            self.sourceGenerations = [:]
            self.companionMapCache.resetGenerations()
            self.incomingEntities = self.incomingEntities.map { entity in
                guard entity.sourceServerID != nil else { return entity }
                return IncomingMapEntity(id: entity.id, latitude: entity.latitude, longitude: entity.longitude,
                    type: entity.type, lastSeen: entity.lastSeen, callSign: entity.callSign,
                    team: entity.team, role: entity.role, senderUID: entity.senderUID,
                    sourceServerID: entity.sourceServerID,
                    sourceGeneration: 0, expiresAt: entity.expiresAt, isUser: entity.isUser,
                    missionName: entity.missionName, alertCategory: entity.alertCategory, isAlert: entity.isAlert)
            }
            self.saveCompanionMapCache()
        }
        if let data = UserDefaults.standard.data(forKey: Self.markerStorageKey) {
            markers = (try? JSONDecoder().decode([WatchMarker].self, from: data)) ?? []
        }
        if let stored = UserDefaults.standard.dictionary(forKey: Self.dismissedPointsKey) as? [String: Double] {
            let now = Date()
            dismissedPointIDs = stored.mapValues { Date(timeIntervalSince1970: $0) }
                .filter { now.timeIntervalSince($0.value) < Self.mapItemReplyLifetime }
        }
        if let stored = UserDefaults.standard.dictionary(forKey: Self.pointSendTimesKey) as? [String: Double] {
            let now = Date()
            pointSendTimes = stored.mapValues { Date(timeIntervalSince1970: $0) }
                .filter { now.timeIntervalSince($0.value) < Self.mapItemReplyLifetime }
        }
        if let stored = UserDefaults.standard.dictionary(forKey: Self.clearedAlertSendTimesKey) as? [String: Double] {
            let now = Date()
            clearedAlertSendTimes = stored.mapValues { Date(timeIntervalSince1970: $0) }
                .filter { now.timeIntervalSince($0.value) < Self.mapItemReplyLifetime }
        }
        if let stored = Self.loadStoredMissions() {
            storedMissions = stored
            for serverID in Set(stored.map(\.serverID)) { installMissionItems(serverID: serverID) }
        }
        companionClient.onMissions = { [weak self] server in self?.applyMissions(server) }
        companionClient.currentCoordinate = { [weak self] in self?.lastLocation?.coordinate }
        if let data = UserDefaults.standard.data(forKey: Self.companionCacheKey) {
            do {
                companionMapCache = try JSONDecoder().decode(CompanionMapCache.self, from: data)
                companionMapCache.prune()
                for event in companionMapCache.events {
                    for entity in SitxCoT.parse(Data(event.xml.utf8), excluding: SitxClient.deviceID()) {
                        receiveEntity(entity, at: event.lastSeen, sourceServerID: event.sourceServerID,
                                      sourceGeneration: event.sourceGeneration, expiresAt: event.header?.stale)
                    }
                }
            } catch { mapCacheError = "Unable to load cached map: \(error.localizedDescription)" }
        }
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        networkPathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi)
            let cellular = path.usesInterfaceType(.cellular)
            Task { @MainActor [weak self] in
                self?.networkConnectivity = DashboardNetworkConnectivity.resolve(
                    satisfied: satisfied, wifi: wifi, cellular: cellular
                )
            }
        }
        networkPathMonitor.start(queue: DispatchQueue(label: "WearTAK.networkPath"))
        incomingPruneTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pruneIncomingEntities() }
        }
        reportingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.forwardOfflineEvents()
                guard let self, self.isAppActive, self.connectionState == .connected,
                      self.transport.pliReportingRoute == .standaloneSitx else { return }
                if let location = self.lastLocation, abs(location.timestamp.timeIntervalSinceNow) < 120 {
                    self.sendPLIIfDue(for: location)
                } else if self.lastFixRequestAt.map({ Date().timeIntervalSince($0) >= 15 }) ?? true {
                    self.lastFixRequestAt = Date()
                    self.requestLocation()
                }
            }
        }
    }

    func setAppActive(_ active: Bool) {
        isAppActive = active
        if !active { companionMapCacheWrites.flush() }
        if active {
            forwardOfflineEvents()
            pruneIncomingEntities()
            startHeadingUpdates()
        } else {
            stopHeadingUpdates()
        }
        companionClient.setActive(active)
        multicastClient.setAppActive(active)
        sitxClient.setAppActive(active)
        if active {
            sitxClient.resumeAuthorization()
            if liveLocationRequested { startLiveLocation() }
        } else { locationManager.stopUpdatingLocation() }
    }

    /// The dashboard coordinate readout needs continuous fixes even when the phone handles PLI.
    func setLiveLocationRequested(_ requested: Bool) {
        guard liveLocationRequested != requested else { return }
        liveLocationRequested = requested
        if requested { startLiveLocation() } else { stopLocationUpdatesIfIdle() }
    }

    private func startLiveLocation() {
        updateLocationAvailability()
        guard isAppActive, watchLocationEnabled else { return }
        locationManager.startUpdatingLocation()
    }

    private func stopLocationUpdatesIfIdle() {
        if liveLocationRequested, isAppActive { return }
        if connectionState == .connected, transport.pliReportingRoute == .standaloneSitx { return }
        locationManager.stopUpdatingLocation()
    }

    func requestLocation() {
        updateLocationAvailability()
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.requestLocation()
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            lastLocation = nil
        @unknown default:
            break
        }
    }

    private func updateLocationAvailability() {
        watchLocationEnabled = CLLocationManager.locationServicesEnabled() &&
            (locationManager.authorizationStatus == .authorizedAlways ||
             locationManager.authorizationStatus == .authorizedWhenInUse)
    }

    private func startHeadingUpdates() {
        guard isAppActive, CLLocationManager.headingAvailable(), !isUpdatingHeading,
              locationManager.authorizationStatus == .authorizedAlways ||
                locationManager.authorizationStatus == .authorizedWhenInUse else { return }
        isUpdatingHeading = true
        locationManager.startUpdatingHeading()
    }

    private func stopHeadingUpdates() {
        guard isUpdatingHeading else { return }
        isUpdatingHeading = false
        locationManager.stopUpdatingHeading()
        headingDegrees = nil
    }

    func connect() {
        guard isAppActive, connectionState != .connecting else { return }
        connectionTask?.cancel()
        connectionState = .connecting
        connectionTask = Task {
            do {
                let incoming = transport.incomingEntities()
                try await transport.connect()
                try Task.checkCancellation()
                connectionState = .connected
                lastPLISentAt = nil
                if transport.pliReportingRoute == .standaloneSitx,
                   locationManager.authorizationStatus == .authorizedAlways ||
                    locationManager.authorizationStatus == .authorizedWhenInUse {
                    locationManager.startUpdatingLocation()
                }
                incomingEntityTask?.cancel()
                incomingEntityTask = Task {
                    for await payload in incoming {
                        guard !Task.isCancelled else { break }
                        receiveEntity(payload, sourceTransport: .sitx, notifyNewPoint: true)
                    }
                }
                requestLocation()
                if let location = lastLocation { sendPLIIfDue(for: location) }
            } catch is CancellationError {
                return
            } catch {
                connectionState = error is TAKTransportError ? .unconfigured : .failed
            }
        }
    }

    func dropMarker() -> Bool {
        return storeMarker(at: usableMarkerCoordinate, kind: selectedMarkerKind, title: defaultPointTitle(), remark: "")
    }

    func defaultPointTitle(at date: Date = Date()) -> String {
        let callsign = settings.callSign.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "HHmmss'Z'"
        let timestamp = formatter.string(from: date)
        return callsign.isEmpty ? timestamp : "\(callsign)_\(timestamp)"
    }

    @discardableResult
    func addMarker(at coordinate: CLLocationCoordinate2D, kind: MarkerKind, title: String, remark: String) -> Bool {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return false }
        return storeMarker(at: coordinate, kind: kind, title: title, remark: remark)
    }

    var usableMarkerCoordinate: CLLocationCoordinate2D? {
        guard let location = lastLocation, location.horizontalAccuracy >= 0,
              abs(location.timestamp.timeIntervalSinceNow) < 120 else { return nil }
        return location.coordinate
    }

    @discardableResult
    func storeMarker(at coordinate: CLLocationCoordinate2D?, kind: MarkerKind, title: String, remark: String) -> Bool {
        if let coordinate, !CLLocationCoordinate2DIsValid(coordinate) {
            offlineNotice = String(localized: "Invalid marker coordinates.", table: "WatchStatus")
            return false
        }
        selectedMarkerKind = kind
        let id = UUID()
        guard let coordinate else {
            let operation = OfflineOperation(kind: .marker, scope: offlineScope, markerID: id,
                                             markerKind: kind, title: title, remark: remark)
            guard storeOffline(operation, key: "marker-\(id)", notice: Self.markerStoredMessage) else { return false }
            requestLocation()
            return true
        }
        let marker = WatchMarker(
            id: id,
            kind: kind,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            createdAt: Date(),
            title: title,
            remark: remark
        )
        guard storeOffline(OfflineOperation(kind: .marker, scope: offlineScope, marker: marker,
                                            xml: sitxClient.markerXML(marker)),
                           key: "marker-\(marker.id)", notice: Self.markerStoredMessage) else { return false }
        markers.insert(marker, at: 0)
        saveMarkers()
        return true
    }

    func updateMarker(id: UUID, kind: MarkerKind, title: String, remark: String) {
        guard let index = markers.firstIndex(where: { $0.id == id }) else { return }
        var marker = markers[index]
        marker.kind = kind
        marker.title = title
        marker.remark = remark
        guard storeOffline(OfflineOperation(kind: .marker, scope: offlineScope, marker: marker,
                                            xml: sitxClient.markerXML(marker)),
                           key: "marker-\(id)", notice: Self.markerStoredMessage) else { return }
        if markers[index].kind != kind { selectedMarkerKind = kind }
        markers[index] = marker
        saveMarkers()
    }

    func moveMarker(id: UUID, to coordinate: CLLocationCoordinate2D) {
        guard CLLocationCoordinate2DIsValid(coordinate),
              let index = markers.firstIndex(where: { $0.id == id }) else { return }
        var marker = markers[index]
        marker.latitude = coordinate.latitude
        marker.longitude = coordinate.longitude
        guard storeOffline(OfflineOperation(kind: .marker, scope: offlineScope, marker: marker,
                                            xml: sitxClient.markerXML(marker)),
                           key: "marker-\(id)", notice: Self.markerStoredMessage) else { return }
        markers[index] = marker
        saveMarkers()
    }

    func deleteMarker(id: UUID) {
        guard let index = markers.firstIndex(where: { $0.id == id }) else { return }
        guard storeOffline(OfflineOperation(kind: .delete, scope: offlineScope,
                                            xml: sitxClient.deleteMarkerXML(uid: id.uuidString)),
                           key: "marker-\(id)", notice: String(localized: "Marker deletion stored and will be sent when connected", table: "WatchStatus")) else { return }
        markers.remove(at: index)
        if bloodhoundTargetID == id {
            bloodhoundTargetID = nil
            bloodhoundMapItemID = nil
        }
        saveMarkers()
    }

    func clearAllPoints() {
        let ids = markers.map(\.id)
        for id in ids { deleteMarker(id: id) }
        guard let offlineOutbox else { return }
        for entry in offlineOutbox.entries {
            do {
                let operation = try JSONDecoder().decode(OfflineOperation.self, from: entry.payload)
                guard operation.kind == .marker, operation.marker == nil, let id = operation.markerID else { continue }
                _ = storeOffline(OfflineOperation(kind: .delete, scope: operation.scope,
                                                   xml: sitxClient.deleteMarkerXML(uid: id.uuidString)),
                                  key: entry.key, notice: String(localized: "Marker deletion stored and will be sent when connected", table: "WatchStatus"))
            } catch { reportOfflineError(error) }
        }
    }

    func toggleBloodhound(id: UUID) {
        bloodhoundContactID = nil
        bloodhoundMapItemID = nil
        bloodhoundTargetID = (bloodhoundTargetID == id) ? nil : id
        bloodhoundProximityNotified = false
    }

    func toggleContactBloodhound(uid: String) {
        guard incomingEntities.contains(where: { $0.id == uid && $0.isUser }) else { return }
        bloodhoundTargetID = nil
        bloodhoundMapItemID = nil
        bloodhoundContactID = bloodhoundContactID == uid ? nil : uid
        bloodhoundProximityNotified = false
        requestLocation()
    }

    var bloodhoundTarget: BloodhoundDestination? {
        if let id = bloodhoundMapItemID, let item = incomingEntities.first(where: { $0.id == id && !$0.isUser }) {
            return BloodhoundDestination(latitude: item.latitude, longitude: item.longitude,
                displayTitle: item.callSign.flatMap { $0.isEmpty ? nil : $0 } ?? item.id)
        }
        if let uid = bloodhoundContactID, let contact = incomingEntities.first(where: { $0.id == uid && $0.isUser }) {
            return BloodhoundDestination(latitude: contact.latitude, longitude: contact.longitude,
                displayTitle: contact.callSign.flatMap { $0.isEmpty ? nil : $0 } ?? contact.id)
        }
        guard let id = bloodhoundTargetID, let marker = markers.first(where: { $0.id == id }) else { return nil }
        return BloodhoundDestination(latitude: marker.latitude, longitude: marker.longitude, displayTitle: marker.displayTitle)
    }

    func markIncomingPointsSeen() {
        if !unseenIncomingPointIDs.isEmpty { unseenIncomingPointIDs = [] }
    }

    /// Hides a received point locally; later copies of the same UID stay hidden for a day.
    func removeIncomingPoint(_ id: String) {
        let now = Date()
        dismissedPointIDs = dismissedPointIDs.filter { now.timeIntervalSince($0.value) < Self.mapItemReplyLifetime }
        dismissedPointIDs[id] = now
        UserDefaults.standard.set(dismissedPointIDs.mapValues(\.timeIntervalSince1970), forKey: Self.dismissedPointsKey)
        incomingEntities.removeAll { $0.id == id && !$0.isUser }
        unseenIncomingPointIDs.remove(id)
        if bloodhoundMapItemID == id {
            bloodhoundMapItemID = nil
            bloodhoundProximityNotified = false
        }
    }

    func startBloodhound(toMapItem id: String) async throws {
        guard let item = incomingMapPoints.first(where: { $0.id == id }) else {
            throw ContactChatFailure.message("This map item is no longer available.")
        }
        if !item.isAlert || item.senderUID?.isEmpty == false {
            try await sendMapItemReply(item, text: "Roger, bloodhounding to \(mapItemTitle(item))")
        }
        bloodhoundTargetID = nil
        bloodhoundContactID = nil
        bloodhoundMapItemID = id
        bloodhoundProximityNotified = false
        requestLocation()
    }

    /// Bloodhound from the map point menu. Points sent directly by a user reply "Roger" like RGR;
    /// Data Sync items have no sender, so they start silently.
    func toggleMapItemBloodhound(id: String) async throws {
        if bloodhoundMapItemID == id {
            bloodhoundMapItemID = nil
            bloodhoundProximityNotified = false
            return
        }
        guard let item = incomingMapPoints.first(where: { $0.id == id }) else {
            throw ContactChatFailure.message("This map item is no longer available.")
        }
        if item.missionName == nil, let sender = item.senderUID, !sender.isEmpty, sender != SitxClient.deviceID() {
            try await startBloodhound(toMapItem: id)
            return
        }
        bloodhoundTargetID = nil
        bloodhoundContactID = nil
        bloodhoundMapItemID = id
        bloodhoundProximityNotified = false
        requestLocation()
    }

    func markInPosition() async throws {
        let item = bloodhoundMapItemID.flatMap { id in incomingMapPoints.first { $0.id == id } }
        if let item, !item.isAlert || item.senderUID?.isEmpty == false {
            try await sendMapItemReply(item, text: "In Position at \(mapItemTitle(item))")
        }
        bloodhoundTargetID = nil
        bloodhoundContactID = nil
        bloodhoundMapItemID = nil
        bloodhoundProximityNotified = false
        guard let item, !item.isAlert else { return }
        removeIncomingPoint(item.id)
    }

    /// Retains the original recipient and GeoChat message ID until its route accepts the message.
    private func sendMapItemReply(_ item: IncomingMapEntity, text: String) async throws {
        guard let senderUID = item.senderUID, !senderUID.isEmpty, senderUID != SitxClient.deviceID() else {
            throw ContactChatFailure.message("This point has no sender to reply to.")
        }
        let sender = incomingEntities.first { $0.id == senderUID && $0.isUser && $0.chatRoute != nil }
        let ownUID = SitxClient.deviceID()
        let xml = try TAKChatMessage.outgoing(senderUID: ownUID,
            senderCallSign: SitxCoT.pliCallSign(settings.callSign, uid: ownUID),
            recipientUID: senderUID, recipientCallSign: sender?.callSign ?? senderUID, text: text)
        let route = sender?.chatRoute ?? item.chatRoute
        guard storeOffline(OfflineOperation(kind: .chat, scope: offlineScope, xml: xml,
                                            route: route, recipientUID: senderUID),
                           key: "chat-\(UUID())", notice: String(localized: "Chat stored and will be sent when connected", table: "WatchStatus")) else {
            throw ContactChatFailure.message(offlineNotice ?? "Unable to store reply.")
        }
        if let route, let message = TAKChatMessage.parse(xml, ownUID: ownUID) { recordChat(message, route: route) }
    }

    private func mapItemTitle(_ item: IncomingMapEntity) -> String {
        item.callSign.flatMap { $0.isEmpty ? nil : $0 } ?? item.id
    }

    func chatUnavailableReason(for contact: IncomingMapEntity) -> String? {
        if !contact.isUser { return "Chat is available for user contacts only." }
        guard contact.chatRoute != nil else { return "The contact's chat transport is unknown." }
        return nil
    }

    func sendContactChat(uid: String, route: ContactChatRoute, text: String) async throws {
        let conversation = ContactConversation(uid: uid, route: route)
        let contact = incomingEntities.first(where: { $0.id == uid && $0.chatRoute == route })
        guard contact != nil || contactMessages[conversation] != nil else {
            throw ContactChatFailure.message("This contact is no longer available on that transport.")
        }
        if let contact, let reason = chatUnavailableReason(for: contact) { throw ContactChatFailure.message(reason) }
        let ownUID = SitxClient.deviceID()
        let xml = try TAKChatMessage.outgoing(senderUID: ownUID,
            senderCallSign: SitxCoT.pliCallSign(settings.callSign, uid: ownUID),
            recipientUID: uid, recipientCallSign: contact?.callSign ?? chatTitle(for: conversation), text: text)
        guard let message = TAKChatMessage.parse(xml, ownUID: ownUID) else {
            throw ContactChatFailure.message("Unable to record the outgoing chat message.")
        }
        guard storeOffline(OfflineOperation(kind: .chat, scope: offlineScope, xml: xml,
                                            route: route, recipientUID: uid),
                           key: "chat-\(message.id)", notice: String(localized: "Chat stored and will be sent when connected", table: "WatchStatus")) else {
            throw ContactChatFailure.message(offlineNotice ?? "Unable to store chat.")
        }
        recordChat(message, route: route)
    }

    private func recordChat(_ message: TAKChatMessage, route: ContactChatRoute) {
        let ownUID = SitxClient.deviceID()
        let other = message.senderUID == ownUID ? message.recipientUID : message.senderUID
        let key = ContactConversation(uid: other, route: route)
        if chatInbox.record(message, conversation: key, ownUID: ownUID) {
            WKInterfaceDevice.current().play(.notification)
            chatLogger.notice("New unread GeoChat recorded; notification haptic requested")
        }
    }

    func bloodhoundReading(from location: CLLocation) -> (bearingDegrees: Double, rangeMeters: Double)? {
        guard let target = bloodhoundTarget else { return nil }
        let targetLocation = CLLocation(latitude: target.latitude, longitude: target.longitude)
        let bearing = Self.bearingDegrees(from: location.coordinate, to: target.coordinate)
        return (bearing, location.distance(from: targetLocation))
    }

    func mapPointReading(to coordinate: CLLocationCoordinate2D, from location: CLLocation) -> (
        bearingDegrees: Double, relativeBearingDegrees: Double, rangeMeters: Double, isCompassRelative: Bool
    ) {
        let destination = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let bearing = Self.bearingDegrees(from: location.coordinate, to: coordinate)
        let relative = headingDegrees.map {
            (bearing - $0 + 360).truncatingRemainder(dividingBy: 360)
        } ?? bearing
        return (bearing, relative, location.distance(from: destination), headingDegrees != nil)
    }

    /// Arrow rotation relative to where the watch currently points, so it spins like a real compass.
    func bloodhoundCompassReading(from location: CLLocation) -> (relativeBearingDegrees: Double, rangeMeters: Double, isCompassRelative: Bool)? {
        guard let reading = bloodhoundReading(from: location) else { return nil }
        guard let headingDegrees else {
            return (reading.bearingDegrees, reading.rangeMeters, false)
        }
        let relative = (reading.bearingDegrees - headingDegrees + 360).truncatingRemainder(dividingBy: 360)
        return (relative, reading.rangeMeters, true)
    }

    private static func bearingDegrees(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> Double {
        let lat1 = start.latitude * .pi / 180
        let lat2 = end.latitude * .pi / 180
        let deltaLon = (end.longitude - start.longitude) * .pi / 180
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        let bearing = atan2(y, x) * 180 / .pi
        return (bearing + 360).truncatingRemainder(dividingBy: 360)
    }

    func receiveEntity(_ payload: EntityRelayPayload, at now: Date = Date(), sourceServerID: UUID? = nil,
                       sourceGeneration: Int = 0, expiresAt: Date? = nil, sourceTransport: ContactChatRoute? = nil,
                       notifyNewPoint: Bool = false) {
        if let sourceServerID, sourceGeneration < sourceGenerations[sourceServerID, default: 0] { return }
        guard !payload.uid.isEmpty, !markers.contains(where: { $0.id.uuidString == payload.uid }),
              CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: payload.lat, longitude: payload.lon)) else { return }
        let previousSend = pointSendTimes[payload.uid] ?? incomingEntities.first(where: { $0.id == payload.uid })?.lastSeen
        if payload.emergencyState != nil {
            if let sent = payload.sentAt, let previousSend, sent < previousSend { return }
            if payload.emergencyState == .cancel {
                incomingEntities.removeAll { $0.id == payload.uid }
                unseenIncomingPointIDs.remove(payload.uid)
                let clearedAt = max(payload.sentAt ?? now, clearedAlertSendTimes[payload.uid] ?? .distantPast)
                clearedAlertSendTimes[payload.uid] = clearedAt
                clearedAlertSendTimes = Dictionary(uniqueKeysWithValues: clearedAlertSendTimes
                    .filter { now.timeIntervalSince($0.value) < Self.mapItemReplyLifetime }
                    .sorted { $0.value > $1.value }.prefix(200).map { ($0.key, $0.value) })
                UserDefaults.standard.set(clearedAlertSendTimes.mapValues(\.timeIntervalSince1970),
                                          forKey: Self.clearedAlertSendTimesKey)
                pruneIncomingEntities(now: now)
                return
            }
            // A snapshot must not resurrect an alert already cleared at the same event time.
            if let clearedAt = clearedAlertSendTimes[payload.uid],
               (payload.sentAt ?? now) <= clearedAt { return }
        }
        let isNewerSend = payload.sentAt.map { sent in previousSend.map { sent > $0 } ?? true } ?? false
        let isResend = notifyNewPoint && payload.isHumanEntered && isNewerSend
        if let dismissedAt = dismissedPointIDs[payload.uid] {
            // A removed point stays hidden unless its sender deliberately sends it again.
            guard isResend, let sent = payload.sentAt, sent > dismissedAt else { return }
            dismissedPointIDs.removeValue(forKey: payload.uid)
            UserDefaults.standard.set(dismissedPointIDs.mapValues(\.timeIntervalSince1970), forKey: Self.dismissedPointsKey)
        }
        if let sourceServerID { refreshSource(sourceServerID, generation: sourceGeneration) }
        if let existing = incomingEntities.first(where: { $0.id == payload.uid }),
           existing.lastSeen > now { return }
        let previous = incomingEntities.first(where: { $0.id == payload.uid })
        let metadata = previous.map {
            payload.inheritingMetadata(callSign: $0.callSign, team: $0.team, role: $0.role,
                                       senderUID: $0.senderUID, isUser: $0.isUser)
        } ?? payload
        let entity = IncomingMapEntity(
            id: payload.uid, latitude: payload.lat, longitude: payload.lon,
            type: payload.type, lastSeen: now,
            callSign: metadata.callSign, team: metadata.team, role: metadata.role,
            senderUID: metadata.senderUID,
            sourceServerID: sourceServerID, sourceGeneration: sourceGeneration, expiresAt: expiresAt ?? payload.staleAt,
            isUser: payload.emergencyState == nil && (metadata.isUser == true || SitxCoT.isUser(type: payload.type)),
            sourceTransport: sourceTransport, missionName: previous?.missionName,
            alertCategory: payload.alertCategory, isAlert: payload.emergencyState == .alert
        )
        let isNew: Bool
        if let index = incomingEntities.firstIndex(where: { $0.id == payload.uid }) {
            incomingEntities[index] = entity
            isNew = false
        } else {
            incomingEntities.append(entity)
            isNew = true
        }
        if !entity.isUser, entity.missionName == nil {
            // Only live traffic notifies; cache restores and snapshots repopulate silently.
            let shouldNotify = isNew ? (payload.sentAt == nil || isNewerSend) : isResend
            if notifyNewPoint, shouldNotify, expiresAt.map({ $0 > Date() }) ?? true {
                unseenIncomingPointIDs.insert(entity.id)
                WKInterfaceDevice.current().play(.notification)
                chatLogger.notice("Incoming map point \(entity.type, privacy: .public) \(isNew ? "recorded" : "re-sent", privacy: .public); notification requested")
            }
            if isNewerSend, let sent = payload.sentAt { recordPointSend(payload.uid, at: sent) }
        }
        if entity.isUser { lastOfflineAttempt = nil; forwardOfflineEvents() }
        pruneIncomingEntities(now: now)
        capLiveEntities()
    }

    private func capLiveEntities() {
        let live = incomingEntities.filter { $0.missionName == nil }
        guard live.count > Self.maximumLiveEntities else { return }
        let dropped = Set(live.sorted {
            if $0.isAlert != $1.isAlert { return $0.isAlert }
            return $0.lastSeen > $1.lastSeen
        }.dropFirst(Self.maximumLiveEntities).map(\.id))
        incomingEntities.removeAll { dropped.contains($0.id) }
    }

    private func recordPointSend(_ uid: String, at sent: Date) {
        let now = Date()
        pointSendTimes[uid] = sent
        pointSendTimes = pointSendTimes.filter { now.timeIntervalSince($0.value) < Self.mapItemReplyLifetime }
        if pointSendTimes.count > 200 {
            for (key, _) in pointSendTimes.sorted(by: { $0.value < $1.value }).prefix(pointSendTimes.count - 200) {
                pointSendTimes.removeValue(forKey: key)
            }
        }
        UserDefaults.standard.set(pointSendTimes.mapValues(\.timeIntervalSince1970), forKey: Self.pointSendTimesKey)
    }

    func pruneIncomingEntities(now: Date = Date()) {
        incomingEntities.removeAll {
            $0.missionName == nil &&
                ((!$0.isAlert || $0.expiresAt == nil) && now.timeIntervalSince($0.lastSeen) > 300 ||
                 ($0.expiresAt.map { $0 <= now } ?? false))
        }
        companionMapCache.prune(now: now)
        if !unseenIncomingPointIDs.isEmpty {
            let current = Set(bloodhoundOrderPoints.map(\.id))
            unseenIncomingPointIDs.formIntersection(current)
        }
        if let uid = bloodhoundContactID, !incomingEntities.contains(where: { $0.id == uid }) {
            bloodhoundContactID = nil
            bloodhoundProximityNotified = false
        }
        if let id = bloodhoundMapItemID, !incomingEntities.contains(where: { $0.id == id && !$0.isUser }) {
            bloodhoundMapItemID = nil
            bloodhoundProximityNotified = false
        }
    }

    // MARK: Data Sync

    struct StoredMission: Codable, Equatable {
        let serverID: UUID
        let name: String
        var items: [TAKMissionItem]
        var canEdit: Bool?
    }

    struct MissionItemDetail {
        let serverID: UUID
        let mission: String
        let item: TAKMissionItem
        /// False when the watch's mission role is read-only; nil when the role is unknown.
        let canEdit: Bool?
    }

    func missionItemDetail(id: String) -> MissionItemDetail? {
        guard let entity = incomingEntities.first(where: { $0.id == id }), let name = entity.missionName,
              let serverID = entity.sourceServerID,
              let mission = storedMissions.first(where: { $0.serverID == serverID && $0.name == name }),
              let item = mission.items.first(where: { $0.uid == id }) else { return nil }
        return MissionItemDetail(serverID: serverID, mission: name, item: item, canEdit: mission.canEdit)
    }

    /// Sends an edited Data Sync item to its mission, then shows the change right away. The next sync
    /// restores the server's copy if the server rejected the update.
    func editMissionItem(id: String, title: String? = nil, remark: String? = nil, kind: MarkerKind? = nil,
                         coordinate: CLLocationCoordinate2D? = nil) async throws {
        guard let detail = missionItemDetail(id: id) else {
            throw ContactChatFailure.message("This DataSync item is no longer available.")
        }
        guard detail.canEdit != false else {
            throw ContactChatFailure.message("Your mission role doesn't allow edits.")
        }
        var item = detail.item
        if let title { item.callsign = title.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let remark { item.remark = remark.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let kind {
            let affiliation: String
            switch kind {
            case .friendly: affiliation = "f"
            case .hostile: affiliation = "h"
            case .neutral: affiliation = "n"
            case .unknown: affiliation = "u"
            }
            item.type = TAKMissionAPI.type(item.type, affiliation: affiliation)
        }
        if let coordinate {
            guard CLLocationCoordinate2DIsValid(coordinate) else { return }
            item.lat = coordinate.latitude
            item.lon = coordinate.longitude
        }
        try await companionClient.send(TAKMissionAPI.itemEvent(item, mission: detail.mission), serverID: detail.serverID)
        guard let m = storedMissions.firstIndex(where: { $0.serverID == detail.serverID && $0.name == detail.mission }),
              let i = storedMissions[m].items.firstIndex(where: { $0.uid == id }) else { return }
        storedMissions[m].items[i] = item
        saveStoredMissions()
        if let e = incomingEntities.firstIndex(where: { $0.id == id }) {
            let old = incomingEntities[e]
            incomingEntities[e] = IncomingMapEntity(
                id: id, latitude: item.lat, longitude: item.lon, type: item.type, lastSeen: Date(),
                callSign: item.callsign, team: old.team, role: old.role, senderUID: old.senderUID,
                sourceServerID: old.sourceServerID, sourceGeneration: old.sourceGeneration, expiresAt: nil,
                isUser: old.isUser, sourceTransport: old.sourceTransport, missionName: old.missionName)
        }
    }

    /// Removes a Data Sync item from its mission on the server (for every subscriber) and from this watch.
    func deleteMissionItem(id: String) async throws {
        guard let detail = missionItemDetail(id: id) else {
            throw ContactChatFailure.message("This DataSync item is no longer available.")
        }
        guard detail.canEdit != false else {
            throw ContactChatFailure.message("Your mission role doesn't allow deleting items.")
        }
        if let error = await companionClient.removeMissionItem(serverID: detail.serverID, mission: detail.mission, uid: id) {
            throw ContactChatFailure.message(error)
        }
        if let m = storedMissions.firstIndex(where: { $0.serverID == detail.serverID && $0.name == detail.mission }) {
            storedMissions[m].items.removeAll { $0.uid == id }
            saveStoredMissions()
        }
        incomingEntities.removeAll { $0.id == id && !$0.isUser }
        unseenIncomingPointIDs.remove(id)
        if bloodhoundMapItemID == id {
            bloodhoundMapItemID = nil
            bloodhoundProximityNotified = false
        }
    }

    @Published private(set) var storedMissions: [StoredMission] = []

    /// Mission items live in a file: up to 999 items can outgrow the ~1 MB watchOS UserDefaults limit.
    private static var missionItemsFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DataSyncMissions.json")
    }

    private func saveStoredMissions() {
        do {
            let url = Self.missionItemsFileURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(storedMissions).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            chatLogger.error("Unable to save Data Sync items: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadStoredMissions() -> [StoredMission]? {
        if let data = try? Data(contentsOf: missionItemsFileURL) {
            return try? JSONDecoder().decode([StoredMission].self, from: data)
        }
        // Builds before 10 kept mission items in UserDefaults; move them to the file once.
        guard let data = UserDefaults.standard.data(forKey: missionItemsKey) else { return nil }
        UserDefaults.standard.removeObject(forKey: missionItemsKey)
        guard let stored = try? JSONDecoder().decode([StoredMission].self, from: data) else { return nil }
        try? FileManager.default.createDirectory(at: missionItemsFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: missionItemsFileURL, options: .atomic)
        return stored
    }

    /// Data Sync items drawn on the map: the nearest `maximumDrawnMissionItems`, refreshed when the map opens,
    /// after moving `drawnMissionRefreshDistance`, and when mission items change.
    static let maximumDrawnMissionItems = 99
    private static let drawnMissionRefreshDistance: CLLocationDistance = 100
    @Published private(set) var drawnMissionItemIDs: Set<String> = []
    private var drawnMissionAnchor: CLLocation?

    var mapEntities: [IncomingMapEntity] {
        incomingEntities.filter { $0.missionName == nil || drawnMissionItemIDs.contains($0.id) || $0.id == bloodhoundMapItemID }
    }

    func refreshDrawnMissionItems() {
        let missionItems = incomingEntities.filter { $0.missionName != nil }
        let ids: Set<String>
        if missionItems.count <= Self.maximumDrawnMissionItems {
            ids = Set(missionItems.map(\.id))
        } else if let location = lastLocation {
            ids = Set(missionItems
                .map { ($0.id, location.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))) }
                .sorted { $0.1 < $1.1 }.prefix(Self.maximumDrawnMissionItems).map(\.0))
        } else {
            ids = Set(missionItems.prefix(Self.maximumDrawnMissionItems).map(\.id))
        }
        drawnMissionAnchor = lastLocation
        if ids != drawnMissionItemIDs { drawnMissionItemIDs = ids }
    }

    /// Replaces a server's mission items with its loaded subscriptions. A mission whose items failed to load keeps
    /// its previous items; unsubscribed or deleted missions leave the map.
    func applyMissions(_ server: TAKMissionServer) {
        guard server.isLoaded else { return }
        let previous = storedMissions.filter { $0.serverID == server.id }
        var updated = storedMissions.filter { $0.serverID != server.id }
        let otherItems = updated.reduce(0) { $0 + $1.items.count }
        for mission in server.missions where mission.subscribed {
            let kept = previous.first { $0.name == mission.name }
            if let items = mission.items {
                updated.append(StoredMission(serverID: server.id, name: mission.name, items: items,
                                             canEdit: mission.canEdit ?? kept?.canEdit))
            } else if var kept {
                if let canEdit = mission.canEdit { kept.canEdit = canEdit }
                updated.append(kept)
            }
        }
        // Across servers the watch keeps at most `maximumItemsTotal` items; this server's missions absorb the excess.
        var allowance = max(0, TAKMissionAPI.maximumItemsTotal - otherItems)
        for i in updated.indices where updated[i].serverID == server.id {
            if updated[i].items.count > allowance { updated[i].items = Array(updated[i].items.prefix(allowance)) }
            allowance -= updated[i].items.count
        }
        storedMissions = updated
        saveStoredMissions()
        UserDefaults.standard.set(server.missions.contains { $0.subscribed } || updated.contains { $0.serverID != server.id },
                                  forKey: Self.missionSubscriptionsFlagKey)
        installMissionItems(serverID: server.id)
    }

    private func installMissionItems(serverID: UUID) {
        var desired: [String: (item: TAKMissionItem, mission: String)] = [:]
        for mission in storedMissions where mission.serverID == serverID {
            for item in mission.items where desired[item.uid] == nil { desired[item.uid] = (item, mission.name) }
        }
        incomingEntities.removeAll { $0.sourceServerID == serverID && $0.missionName != nil && desired[$0.id] == nil }
        let now = Date()
        let ownUID = SitxClient.deviceID()
        let generation = sourceGenerations[serverID, default: 0]
        for (uid, entry) in desired {
            guard uid != ownUID, dismissedPointIDs[uid] == nil,
                  !markers.contains(where: { $0.id.uuidString == uid }) else { continue }
            let existing = incomingEntities.firstIndex { $0.id == uid }
            let old = existing.map { incomingEntities[$0] }
            let item = entry.item
            let entity = IncomingMapEntity(
                id: uid, latitude: item.lat, longitude: item.lon, type: item.type,
                lastSeen: old?.lastSeen ?? now, callSign: item.callsign ?? old?.callSign,
                team: old?.team, role: old?.role, senderUID: old?.senderUID,
                sourceServerID: serverID, sourceGeneration: max(generation, old?.sourceGeneration ?? 0),
                expiresAt: nil, isUser: old?.isUser ?? SitxCoT.isUser(type: item.type),
                sourceTransport: old?.sourceTransport, missionName: entry.mission)
            if let existing { incomingEntities[existing] = entity } else { incomingEntities.append(entity) }
            unseenIncomingPointIDs.remove(uid)
        }
        refreshDrawnMissionItems()
    }

    private func refreshSource(_ id: UUID, generation: Int) {
        guard generation > sourceGenerations[id, default: 0] else { return }
        sourceGenerations[id] = generation
        incomingEntities.removeAll { $0.sourceServerID == id && $0.sourceGeneration < generation && $0.missionName == nil }
        companionMapCache.remove(sourceID: id, beforeGeneration: generation)
        saveCompanionMapCache()
    }

    private func saveCompanionMapCache() {
        companionMapCacheWrites.cancel()
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(companionMapCache), forKey: Self.companionCacheKey)
            #if DEBUG && targetEnvironment(simulator)
            loadTestCacheWrites += 1
            #endif
            mapCacheError = nil
        } catch { mapCacheError = "Unable to save cached map: \(error.localizedDescription)" }
    }

    private lazy var companionMapCacheWrites = MapCacheWriteBatcher { [weak self] in
        self?.saveCompanionMapCache()
    }

    #if DEBUG && targetEnvironment(simulator)
    private var loadTestCacheWrites = 0
    private struct LoadStage: Codable {
        let name: String
        let events: Int
        let elapsedSeconds: Double
        let maxHeartbeatDelaySeconds: Double
        let liveContacts: Int
        let cachedContacts: Int
        let cacheBytes: Int
        let cacheWrites: Int
    }

    private var loadTestStarted: Bool {
        get { UserDefaults.standard.bool(forKey: "WearTAK.loadTestStarted") }
        set { UserDefaults.standard.set(newValue, forKey: "WearTAK.loadTestStarted") }
    }

    private func checkSimulatorBloodhoundAlerts() async throws {
        let now = Date()
        let prefix = "bloodhound-alert-check-\(UUID())"
        let pointID = prefix + "-point"
        let alertID = prefix + "-alert"
        let newerAlertID = prefix + "-newer"
        defer {
            incomingEntities.removeAll { $0.id.hasPrefix(prefix) }
            for id in [pointID, alertID, newerAlertID] { pointSendTimes.removeValue(forKey: id) }
            UserDefaults.standard.set(pointSendTimes.mapValues(\.timeIntervalSince1970), forKey: Self.pointSendTimesKey)
            clearedAlertSendTimes.removeValue(forKey: alertID)
            UserDefaults.standard.set(clearedAlertSendTimes.mapValues(\.timeIntervalSince1970),
                                      forKey: Self.clearedAlertSendTimesKey)
            bloodhoundMapItemID = nil
        }
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else {
                throw NSError(domain: "WearTAK.LoadTest", code: 7,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        let point = EntityRelayPayload(uid: pointID, lat: 38, lon: -77, type: "a-n-G", sentAt: now)
        let alert = EntityRelayPayload(uid: alertID, lat: 38, lon: -77, type: "b-a-o",
            sentAt: now, emergencyState: .alert, alertCategory: "Injury", staleAt: now.addingTimeInterval(600))
        let newerAlert = EntityRelayPayload(uid: newerAlertID, lat: 39, lon: -77, type: "b-a-o-tbl",
            sentAt: now.addingTimeInterval(1), emergencyState: .alert, staleAt: now.addingTimeInterval(600))
        receiveEntity(point, at: now)
        receiveEntity(alert, at: now)
        receiveEntity(newerAlert, at: now.addingTimeInterval(1))
        let ids = bloodhoundOrderPoints.filter { $0.id.hasPrefix(prefix) }.map(\.id)
        try require(ids == [newerAlertID, alertID, pointID], "Bloodhound alerts must precede ordinary points, newest first")
        try require(mapEntities.contains { $0.id == alertID && $0.isAlert }, "Remote alerts must appear on the map")
        try await toggleMapItemBloodhound(id: alertID)
        try require(bloodhoundMapItemID == alertID && bloodhoundTarget?.latitude == alert.lat,
                    "The point menu must navigate to an alert without a reply address")
        var cancel = alert
        cancel.emergencyState = .cancel
        cancel.sentAt = now.addingTimeInterval(2)
        receiveEntity(cancel, at: now.addingTimeInterval(2))
        try require(!bloodhoundOrderPoints.contains { $0.id == alertID } && bloodhoundMapItemID == nil,
                    "Cancellation must remove the alert and stop Bloodhound")
        try require(!mapEntities.contains { $0.id == alertID }, "Cancellation must remove the alert from the map")
        receiveEntity(alert, at: now.addingTimeInterval(3))
        try require(!bloodhoundOrderPoints.contains { $0.id == alertID }, "A replay must not resurrect a cancelled alert")
        var reactivated = alert
        reactivated.sentAt = now.addingTimeInterval(4)
        receiveEntity(reactivated, at: now.addingTimeInterval(4))
        receiveEntity(cancel, at: now.addingTimeInterval(5))
        try require(bloodhoundOrderPoints.contains { $0.id == alertID }, "A delayed cancellation must not clear a newer alert")
        pruneIncomingEntities(now: now.addingTimeInterval(301))
        try require(bloodhoundOrderPoints.contains { $0.id == newerAlertID }, "An active alert must remain until its stale time")
        pruneIncomingEntities(now: now.addingTimeInterval(600))
        try require(!bloodhoundOrderPoints.contains { $0.id == newerAlertID }, "An expired alert must leave the picker")
        try require(!mapEntities.contains { $0.id == newerAlertID }, "An expired alert must leave the map")
    }

    func runSimulatorLoadTest() async {
        guard !loadTestStarted else { return }
        loadTestStarted = true
        var stages: [LoadStage] = []
        let source = UUID()
        var session = UUID()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        do {
            try await checkSimulatorBloodhoundAlerts()
            for (name, rate, count, detailBytes) in [
                ("10-events-per-second", 10, 50, 0),
                ("100-events-per-second", 100, 500, 0),
                ("500-events-per-second", 500, 2_500, 0),
                ("large-48KB-details", 50, 250, 48_000),
                ("new-map-point-notifications", 100, 250, 0),
                ("5000-event-burst", 0, 5_000, 0),
                ("reconnect-and-lifecycle", 100, 500, 0)
            ] {
                let started = Date()
                let initialWrites = loadTestCacheWrites
                var maxDelay = 0.0
                let heartbeat = Task { @MainActor in
                    while !Task.isCancelled {
                        let before = Date()
                        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                        maxDelay = max(maxDelay, Date().timeIntervalSince(before) - 0.05)
                    }
                }
                defer { heartbeat.cancel() }
                for index in 0..<count {
                    if name == "reconnect-and-lifecycle", index.isMultiple(of: 50) {
                        setAppActive(false)
                        session = UUID()
                        setAppActive(true)
                    }
                    let now = Date()
                    let isPoint = name == "new-map-point-notifications"
                    let uid = isPoint ? "load-point-\(index)" : "load-\(index % 5000)"
                    let type = isPoint ? "a-n-G" : "a-f-G-U-C"
                    let xml = """
                    <event uid="\(uid)" type="\(type)" time="\(formatter.string(from: now))" stale="\(formatter.string(from: now.addingTimeInterval(300)))"><point lat="38.0" lon="-77.0"/><detail><contact callsign="LOAD-\(index)"/><remarks>\(String(repeating: "A", count: detailBytes))</remarks></detail></event>
                    """
                    let data = try BridgeWire.Message(kind: .cot, xml: xml, sourceServerID: source,
                        sourceGeneration: 1, sessionID: session).encoded()
                    try companionClient.receiveLoadTestMessage(data)
                    guard incomingEntities.count <= Self.maximumLiveEntities,
                          companionMapCache.events.count <= CompanionMapCache.maximumEvents,
                          mapCacheError == nil else {
                        throw NSError(domain: "WearTAK.LoadTest", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: mapCacheError ?? "Contact limit exceeded"])
                    }
                    if rate > 0 {
                        let wait = Double(index + 1) / Double(rate) - Date().timeIntervalSince(started)
                        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                        else { await Task.yield() }
                    } else if index.isMultiple(of: 10) {
                        await Task.yield()
                    }
                }
                // Allow pending UI and heartbeat work to drain before measuring.
                try await Task.sleep(for: .milliseconds(100))
                heartbeat.cancel()
                await heartbeat.value
                companionMapCacheWrites.flush()
                guard let stored = UserDefaults.standard.data(forKey: Self.companionCacheKey) else {
                    throw NSError(domain: "WearTAK.LoadTest", code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "Cache flush did not persist data"])
                }
                let restored = try JSONDecoder().decode(CompanionMapCache.self, from: stored)
                guard restored.events.map(\.xml) == companionMapCache.events.map(\.xml) else {
                    throw NSError(domain: "WearTAK.LoadTest", code: 6,
                        userInfo: [NSLocalizedDescriptionKey: "Cache flush persisted stale data"])
                }
                let bytes = try JSONEncoder().encode(companionMapCache).count
                guard bytes < CompanionMapCache.maximumStorageBytes else {
                    throw NSError(domain: "WearTAK.LoadTest", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Cached map exceeds storage byte budget"])
                }
                stages.append(LoadStage(name: name, events: count,
                    elapsedSeconds: Date().timeIntervalSince(started), maxHeartbeatDelaySeconds: maxDelay,
                    liveContacts: incomingEntities.count, cachedContacts: companionMapCache.events.count,
                    cacheBytes: bytes, cacheWrites: loadTestCacheWrites - initialWrites))
            }
            let oversized = Data(repeating: 65, count: BridgeWire.maximumMessageBytes + 1)
            do {
                try companionClient.receiveLoadTestMessage(oversized)
                throw NSError(domain: "WearTAK.LoadTest", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Oversized message accepted"])
            } catch BridgeWire.Failure.tooLarge {}
            do {
                let malformed = try BridgeWire.Message(kind: .cot, xml: "<event><point>").encoded()
                try companionClient.receiveLoadTestMessage(malformed)
                throw NSError(domain: "WearTAK.LoadTest", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Malformed XML accepted"])
            } catch BridgeWire.Failure.invalidCoT {}
            let report = try JSONEncoder().encode(stages)
            let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
            try report.write(to: directory.appendingPathComponent("watch-load-report.json"), options: .atomic)
        } catch {
            chatLogger.error("Simulator load test failed: \(error.localizedDescription, privacy: .public)")
            mapCacheError = "Simulator load test failed: \(error.localizedDescription)"
        }
    }
    #endif

    private func saveMarkers() {
        if let data = try? JSONEncoder().encode(markers) {
            UserDefaults.standard.set(data, forKey: Self.markerStorageKey)
        }
    }

    func startEmergencyAlert(type: ManualAlertType) {
        guard activeAlertType == nil else { return }
        guard storeAlert(state: .alert, type: type.rawValue) else { return }
        activeAlertType = type
        UserDefaults.standard.set(type.rawValue, forKey: "WearTAK.manualAlertType")
        publishAlertReportingState()
    }

    func cancelEmergencyAlert() {
        guard let type = activeAlertType else { return }
        guard storeAlert(state: .cancel, type: type.rawValue) else { return }
        activeAlertType = nil
        UserDefaults.standard.removeObject(forKey: "WearTAK.manualAlertType")
        publishAlertReportingState()
    }

    func updateAutomaticAlert(_ category: AutomaticAlertCategory?) {
        guard category != activeAutomaticAlert else { return }
        let previousCategory = activeAutomaticAlert
        activeAutomaticAlert = category
        publishAlertReportingState()
        automaticAlertDeliveryFailed = category != nil && connectionState != .connected
        if category != nil {
            WKInterfaceDevice.current().play(.notification)
        }

        if let previousCategory, previousCategory != category {
            automaticAlertDeliveryFailed = !storeAlert(state: .cancel, type: previousCategory.rawValue)
        }
        if let category {
            automaticAlertDeliveryFailed = !storeAlert(state: .alert, type: category.rawValue) || !sitxClient.hasReadyOutput
        }
    }

    /// Mirrors updateAutomaticAlert but tracks each environmental category independently,
    /// since pressure and immersion alerts can be active at the same time.
    func setEnvironmentalAlert(_ category: EnvironmentalAlertCategory, active: Bool) {
        let alreadyActive = activeEnvironmentalAlerts.contains(category)
        guard active != alreadyActive else { return }
        if active {
            activeEnvironmentalAlerts.insert(category)
            WKInterfaceDevice.current().play(.notification)
        } else {
            activeEnvironmentalAlerts.remove(category)
        }
        publishAlertReportingState()
        if active && connectionState != .connected {
            automaticAlertDeliveryFailed = true
        }

        automaticAlertDeliveryFailed = !storeAlert(state: active ? .alert : .cancel, type: category.rawValue)
            || (active && !sitxClient.hasReadyOutput)
    }

    private var offlineScope: String {
        "\(settings.relayProvider)|\(settings.sitxEnabled)|\(settings.sitxApiHost)|\(sitxClient.selectedGroupID)|\(settings.multicastEnabled)|\(settings.multicastAddress)|\(settings.multicastPort)"
    }

    private func reportOfflineError(_ error: Error) {
        offlineNotice = error.localizedDescription
        chatLogger.error("Offline forwarding: \(error.localizedDescription, privacy: .public)")
    }

    private func expireOfflineEvents() {
        guard let offlineOutbox else { return }
        do {
            if try offlineOutbox.expire() > 0 {
                offlineExpiryNotice = String(localized: "Unsent events expired after 24 hours.", table: "WatchStatus")
                chatLogger.warning("Unsent offline events expired after 24 hours")
            }
            queuedEventCount = offlineOutbox.entries.count
        } catch { reportOfflineError(error) }
    }

    @discardableResult
    private func storeOffline(_ operation: OfflineOperation, key: String, notice: String) -> Bool {
        guard let offlineOutbox else {
            reportOfflineError(OfflineOutbox.Failure.unreadable)
            return false
        }
        do {
            expireOfflineEvents()
            try offlineOutbox.enqueue(key: key, payload: JSONEncoder().encode(operation))
            queuedEventCount = offlineOutbox.entries.count
            offlineNotice = notice
            lastOfflineAttempt = nil
            forwardOfflineEvents()
            return true
        } catch {
            reportOfflineError(error)
            return false
        }
    }

    private func storeAlert(state: EmergencyState, type: String) -> Bool {
        let xml = usableMarkerCoordinate != nil || state == .cancel ? sitxClient.emergencyXML(state: state, type: type) : nil
        let notice = state == .cancel
            ? String(localized: "Cancel alert stored and will be sent when connected and/or location is updated", table: "WatchStatus")
            : String(localized: "Alert stored and will be sent when connected and/or location is updated", table: "WatchStatus")
        return storeOffline(OfflineOperation(kind: .alert, scope: offlineScope, alertState: state,
                                             alertType: type, xml: xml),
                            key: "alert-\(type)", notice: notice)
    }

    private func routeReady(_ route: ContactChatRoute) -> Bool {
        switch route {
        case .companion: return companionClient.isReady
        case .multicast: return multicastClient.isReady
        case .sitx: return sitxClient.isSitxConnected
        }
    }

    private func forwardOfflineEvents() {
        guard isAppActive, !forwardingOffline, let offlineOutbox,
              lastOfflineAttempt.map({ Date().timeIntervalSince($0) >= 5 }) ?? true else { return }
        expireOfflineEvents()
        guard !offlineOutbox.entries.isEmpty else { return }
        forwardingOffline = true
        lastOfflineAttempt = Date()
        Task {
            defer { forwardingOffline = false; queuedEventCount = offlineOutbox.entries.count }
            for entry in offlineOutbox.entries {
                guard isAppActive else { return }
                guard Date().timeIntervalSince(entry.createdAt) < OfflineOutbox.retention else {
                    expireOfflineEvents()
                    continue
                }
                guard offlineOutbox.entries.contains(where: { $0.id == entry.id }) else { continue }
                do {
                    var operation = try JSONDecoder().decode(OfflineOperation.self, from: entry.payload)
                    guard operation.scope == offlineScope else {
                        offlineNotice = String(localized: "Stored events are waiting for their original network configuration.", table: "WatchStatus")
                        continue
                    }
                    if operation.xml == nil, operation.kind == .marker,
                       let id = operation.markerID, let kind = operation.markerKind,
                       let coordinate = usableMarkerCoordinate {
                        let marker = WatchMarker(id: id, kind: kind, latitude: coordinate.latitude,
                            longitude: coordinate.longitude, createdAt: entry.createdAt,
                            title: operation.title, remark: operation.remark)
                        operation.marker = marker
                        operation.xml = sitxClient.markerXML(marker)
                        try offlineOutbox.replacePayload(id: entry.id, payload: JSONEncoder().encode(operation))
                        if !markers.contains(where: { $0.id == id }) { markers.insert(marker, at: 0); saveMarkers() }
                    }
                    if operation.xml == nil, operation.kind == .alert,
                       let state = operation.alertState, let type = operation.alertType,
                       usableMarkerCoordinate != nil {
                        operation.xml = sitxClient.emergencyXML(state: state, type: type)
                        try offlineOutbox.replacePayload(id: entry.id, payload: JSONEncoder().encode(operation))
                    }
                    guard let xml = operation.xml else { continue }
                    if operation.kind == .chat {
                        if operation.route == nil, let recipient = operation.recipientUID,
                           let route = incomingEntities.first(where: { $0.id == recipient && $0.isUser })?.chatRoute {
                            operation.route = route
                            try offlineOutbox.replacePayload(id: entry.id, payload: JSONEncoder().encode(operation))
                        }
                        guard let route = operation.route else { continue }
                        guard routeReady(route) else { continue }
                        switch route {
                        case .companion(let server): try await companionClient.sendChat(xml, serverID: server)
                        case .multicast: try await multicastClient.send(xml)
                        case .sitx: try await sitxClient.sendContactChat(xml)
                        }
                    } else {
                        guard sitxClient.hasReadyOutput else { continue }
                        try await sitxClient.sendQueuedEvent(xml)
                    }
                    try offlineOutbox.acknowledge(id: entry.id)
                    offlineNotice = String(localized: "Accepted by transport; recipient delivery is not confirmed.", table: "WatchStatus")
                } catch {
                    reportOfflineError(error)
                    // Keep the original payload/ID for retry. Other destinations can still make progress.
                }
            }
        }
    }
}

extension WatchSessionModel: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updateLocationAvailability()
        guard isAppActive else { return }
        guard manager.authorizationStatus == .authorizedAlways ||
                manager.authorizationStatus == .authorizedWhenInUse else {
            stopHeadingUpdates()
            return
        }
        startHeadingUpdates()
        if liveLocationRequested || (connectionState == .connected && transport.pliReportingRoute == .standaloneSitx) {
            manager.startUpdatingLocation()
        } else {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        lastLocation = location
        sitxClient.currentLocation = location
        if drawnMissionAnchor.map({ location.distance(from: $0) > Self.drawnMissionRefreshDistance }) ?? true {
            refreshDrawnMissionItems()
        }
        lastOfflineAttempt = nil
        forwardOfflineEvents()
        checkBloodhoundProximity(at: location)
        guard connectionState == .connected else { return }
        sendPLIIfDue(for: location)
    }

    private func sendPLIIfDue(for location: CLLocation) {
          guard isAppActive, !isSendingPLI, location.horizontalAccuracy >= 0,
              abs(location.timestamp.timeIntervalSinceNow) < 120 else { return }
        #if DEBUG && targetEnvironment(simulator)
        stepSimulatedBiometrics()
        #endif
        let hasActiveAlert = activeAlertType != nil || activeAutomaticAlert != nil || !activeEnvironmentalAlerts.isEmpty
        let interval: TimeInterval
        if hasActiveAlert {
            interval = TimeInterval(settings.alertingReportingInterval)
        } else if settings.reportingStrategy == .constant {
            interval = TimeInterval(settings.constantReportingInterval)
        } else if location.speed < 0.5 {
            interval = TimeInterval(settings.stationaryReportingInterval)
        } else if location.speed < 2.5 {
            interval = TimeInterval(settings.onFootReportingInterval)
        } else {
            interval = TimeInterval(settings.vehicleReportingInterval)
        }

        let effectiveInterval = settings.reportingInterval(base: interval, isOnWiFi: isOnWiFi)
        guard transport.pliReportingRoute == .standaloneSitx else {
            Task {
                try? await transport.sendPLI(coordinate: location.coordinate, reportingInterval: effectiveInterval)
            }
            return
        }
        guard lastPLISentAt.map({ Date().timeIntervalSince($0) >= effectiveInterval }) ?? true else { return }
        isSendingPLI = true
        Task {
            defer { isSendingPLI = false }
            do {
                try await transport.sendPLI(coordinate: location.coordinate, reportingInterval: effectiveInterval)
                lastPLISentAt = Date()
            } catch {
                if !sitxClient.hasReadyOutput { connectionState = .failed }
            }
        }
    }

    /// Latest heart rate/exertion for outbound PLI and alert biometrics on every route.
    func updateBiometrics(heartRate: Int?, exertion: Int?, measuredAt: Date?) {
        var biometrics = WatchBiometrics(heartRate: heartRate, exertion: exertion, measuredAt: measuredAt)
        #if DEBUG && targetEnvironment(simulator)
        if heartRate == nil {
            biometrics = Self.simulatedBiometrics()
            startSimulatedBiometrics()
        }
        #endif
        biometrics.ageYears = Calendar.current.component(.year, from: Date()) - settings.birthYear
        biometrics.batdokCotEnabled = settings.batdokCotEnabled
        sitxClient.biometrics = biometrics
        companionClient.setBiometrics(biometrics)
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Simulator has no heart-rate sensor; fake vitals let outbound CoT biometrics be tested in other TAK tools.
    /// Heart rate drifts a few BPM per step (random walk within 65–110) so each PLI shows a slightly different value.
    private static var simulatedHeartRate = 80

    private static func simulatedBiometrics(now: Date = Date()) -> WatchBiometrics {
        simulatedHeartRate = min(110, max(65, simulatedHeartRate + Int.random(in: -3...3)))
        // Same formula as PhysiologyMonitor for a 35-year-old: 208 - 0.7 * 35 = 183.5 max.
        let exertion = Int((Double(simulatedHeartRate) / 183.5 * 100).rounded())
        return WatchBiometrics(heartRate: simulatedHeartRate, exertion: exertion, measuredAt: now)
    }

    /// Steps the fake vitals; called on a timer (feeds Companion's phone-GPS PLI) and before each watch PLI.
    private func stepSimulatedBiometrics() {
        guard simulatedBiometricsTimer != nil else { return }
        let biometrics = Self.simulatedBiometrics()
        sitxClient.biometrics = biometrics
        companionClient.setBiometrics(biometrics)
    }

    private func startSimulatedBiometrics() {
        guard simulatedBiometricsTimer == nil else { return }
        simulatedBiometricsTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stepSimulatedBiometrics() }
        }
    }
    #endif

    private func publishAlertReportingState() {
        companionClient.setAlertActive(
            activeAlertType != nil || activeAutomaticAlert != nil || !activeEnvironmentalAlerts.isEmpty
        )
    }

    private func checkBloodhoundProximity(at location: CLLocation) {
        guard settings.bloodhoundProximityVibrationEnabled,
              let reading = bloodhoundReading(from: location) else {
            bloodhoundProximityNotified = false
            return
        }
        guard reading.rangeMeters <= Double(settings.bloodhoundProximityRadius) else {
            bloodhoundProximityNotified = false
            return
        }
        guard !bloodhoundProximityNotified else { return }
        bloodhoundProximityNotified = true
        WKInterfaceDevice.current().play(.notification)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        lastLocation = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else {
            headingDegrees = nil
            return
        }
        headingDegrees = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
    }
}
