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
        case .friendly: return "Friendly 2525D point"
        case .neutral: return "Neutral 2525D point"
        case .unknown: return "Unknown 2525D point"
        case .hostile: return "Hostile 2525D point"
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

    var chatRoute: ContactChatRoute? {
        if let sourceServerID { return .companion(sourceServerID) }
        return sourceTransport
    }

    var teamColor: TeamColor? { TeamColor(cotName: team) }
    var roleBadge: String? { SitxCoT.roleBadge(role) }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var kind: MarkerKind {
        if type.contains("a-h-") { return .hostile }
        if type.contains("a-f-") { return .friendly }
        return .unknown
    }
}

enum MarkerKind: String, CaseIterable, Identifiable, Codable {
    case friendly = "Friendly"
    case neutral = "Neutral"
    case unknown = "Unknown"
    case hostile = "Hostile"

    var id: String { rawValue }
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

enum ContactChatRoute: Hashable {
    case companion(UUID), multicast, sitx
}

private enum ContactChatFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}

private struct PendingMapItemReply {
    let recipientUID: String
    let recipientCallSign: String
    let text: String
    let messageID: String
    let createdAt: Date
}

enum PLIReportingRoute {
    case phoneRelay
    case standaloneSitx
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

extension TAKTransport {
    var pliReportingRoute: PLIReportingRoute { .phoneRelay }
}

enum TAKTransportError: Error {
    case notConfigured
}

struct UnconfiguredTAKTransport: TAKTransport {
    func connect() async throws { throw TAKTransportError.notConfigured }
    func sendPLI(coordinate: CLLocationCoordinate2D) async throws { throw TAKTransportError.notConfigured }
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
    private static let markerStorageKey = "WearTAK.droppedPoints"
    private static let companionCacheKey = "WearTAK.cachedCompanionMap"
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
    private var pendingMapItemReplies: [PendingMapItemReply] = []
    private static let mapItemReplyLifetime: TimeInterval = 24 * 60 * 60
    @Published private var chatInbox = TAKChatInbox<ContactConversation>()

    var contactMessages: [ContactConversation: [TAKChatMessage]] { chatInbox.messages }
    var unreadChatCounts: [ContactConversation: Int] { chatInbox.unreadCounts }
    var unreadChatCount: Int { chatInbox.unreadCount }

    var chatConversations: [ContactConversation] { chatInbox.conversations }
    var incomingMapPoints: [IncomingMapEntity] { incomingEntities.filter { !$0.isUser } }

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
    private var callSignSubscription: AnyCancellable?
    private var sitxRelaySubscriptions: Set<AnyCancellable> = []
    private var isSendingPLI = false
    #if DEBUG && targetEnvironment(simulator)
    private var simulatedBiometricsTimer: Timer?
    #endif
    private var isAppActive = true
    private var lastFixRequestAt: Date?
    private var incomingEntityTask: Task<Void, Never>?
    private var incomingPruneTimer: Timer?
    private var automaticAlertTask: Task<Void, Never>?
    private var deliveredAutomaticAlert: AutomaticAlertCategory?
    private var environmentalAlertTasks: [EnvironmentalAlertCategory: Task<Void, Never>] = [:]
    private var deliveredEnvironmentalAlerts: Set<EnvironmentalAlertCategory> = []
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
        callSignSubscription = settings.$callSign.removeDuplicates().dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastPLISentAt = nil
                guard self.isAppActive, self.connectionState == .connected else { return }
                if let location = self.lastLocation {
                    self.sendPLIIfDue(for: location)
                } else {
                    self.requestLocation()
                }
            }
        }
        selectedMarkerKind = MarkerKind(rawValue: UserDefaults.standard.string(forKey: "WearTAK.lastMarkerKind") ?? "") ?? .unknown
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
                self.saveCompanionMapCache()
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
                    sourceGeneration: 0, expiresAt: entity.expiresAt, isUser: entity.isUser)
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
        if active {
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
        guard let coordinate = lastLocation?.coordinate else { return false }
        return addMarker(at: coordinate, kind: selectedMarkerKind, title: defaultPointTitle(), remark: "")
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
        selectedMarkerKind = kind
        let marker = WatchMarker(
            id: UUID(),
            kind: kind,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            createdAt: Date(),
            title: title,
            remark: remark
        )
        markers.insert(marker, at: 0)
        saveMarkers()
        Task {
            try? await transport.sendMarker(marker)
        }
        return true
    }

    func updateMarker(id: UUID, kind: MarkerKind, title: String, remark: String) {
        guard let index = markers.firstIndex(where: { $0.id == id }) else { return }
        if markers[index].kind != kind { selectedMarkerKind = kind }
        markers[index].kind = kind
        markers[index].title = title
        markers[index].remark = remark
        let marker = markers[index]
        saveMarkers()
        Task {
            try? await transport.sendMarker(marker)
        }
    }

    func moveMarker(id: UUID, to coordinate: CLLocationCoordinate2D) {
        guard CLLocationCoordinate2DIsValid(coordinate),
              let index = markers.firstIndex(where: { $0.id == id }) else { return }
        markers[index].latitude = coordinate.latitude
        markers[index].longitude = coordinate.longitude
        let marker = markers[index]
        saveMarkers()
        Task {
            try? await transport.sendMarker(marker)
        }
    }

    func deleteMarker(id: UUID) {
        guard let index = markers.firstIndex(where: { $0.id == id }) else { return }
        markers.remove(at: index)
        if bloodhoundTargetID == id {
            bloodhoundTargetID = nil
            bloodhoundMapItemID = nil
        }
        saveMarkers()
        Task {
            try? await transport.deleteMarker(uid: id.uuidString)
        }
    }

    func clearAllPoints() {
        let ids = markers.map(\.id)
        markers.removeAll()
        bloodhoundTargetID = nil
        bloodhoundMapItemID = nil
        saveMarkers()
        Task {
            for id in ids {
                try? await transport.deleteMarker(uid: id.uuidString)
            }
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
        bloodhoundTargetID = nil
        bloodhoundContactID = nil
        bloodhoundMapItemID = id
        bloodhoundProximityNotified = false
        requestLocation()
        try await sendMapItemReply(item, text: "Roger, bloodhounding to \(mapItemTitle(item))")
    }

    func markInPosition() async throws {
        let item = bloodhoundMapItemID.flatMap { id in incomingMapPoints.first { $0.id == id } }
        bloodhoundTargetID = nil
        bloodhoundContactID = nil
        bloodhoundMapItemID = nil
        bloodhoundProximityNotified = false
        guard let item else { return }
        removeIncomingPoint(item.id)
        try await sendMapItemReply(item, text: "In Position at \(mapItemTitle(item))")
    }

    /// Sends now on the best known route. If the sender isn't currently visible, the reply is also queued and
    /// resent with the same message ID once their PLI arrives, so receivers de-duplicate it.
    private func sendMapItemReply(_ item: IncomingMapEntity, text: String) async throws {
        guard settings.chatEnabled else { throw ContactChatFailure.message("Enable Chat in settings.") }
        guard let senderUID = item.senderUID, !senderUID.isEmpty, senderUID != SitxClient.deviceID() else {
            throw ContactChatFailure.message("This point has no sender to reply to.")
        }
        let sender = incomingEntities.first { $0.id == senderUID && $0.isUser && $0.chatRoute != nil }
        let reply = PendingMapItemReply(recipientUID: senderUID, recipientCallSign: sender?.callSign ?? senderUID,
                                        text: text, messageID: UUID().uuidString, createdAt: Date())
        if let sender, let route = sender.chatRoute, chatUnavailableReason(for: sender) == nil {
            try await deliverMapItemReply(reply, route: route)
            return
        }
        pendingMapItemReplies.append(reply)
        chatLogger.notice("Map item reply queued until sender PLI is seen")
        guard let route = item.chatRoute else { return }
        do { try await deliverMapItemReply(reply, route: route) }
        catch { chatLogger.error("Map item reply best-effort send failed: \(error.localizedDescription, privacy: .public)") }
    }

    private func deliverMapItemReply(_ reply: PendingMapItemReply, route: ContactChatRoute) async throws {
        let ownUID = SitxClient.deviceID()
        let xml = try TAKChatMessage.outgoing(senderUID: ownUID,
            senderCallSign: SitxCoT.pliCallSign(settings.callSign, uid: ownUID),
            recipientUID: reply.recipientUID, recipientCallSign: reply.recipientCallSign,
            text: reply.text, messageID: reply.messageID)
        switch route {
        case .companion(let serverID): try await companionClient.sendChat(xml, serverID: serverID)
        case .multicast: try await multicastClient.send(xml)
        case .sitx: try await sitxClient.sendContactChat(xml)
        }
        chatLogger.notice("Map item reply accepted by transport")
        if let message = TAKChatMessage.parse(xml, ownUID: ownUID) { recordChat(message, route: route) }
    }

    private func flushMapItemReplies(to sender: IncomingMapEntity) {
        pendingMapItemReplies.removeAll { Date().timeIntervalSince($0.createdAt) > Self.mapItemReplyLifetime }
        guard sender.isUser, let route = sender.chatRoute, chatUnavailableReason(for: sender) == nil else { return }
        let due = pendingMapItemReplies.filter { $0.recipientUID == sender.id }
        guard !due.isEmpty else { return }
        pendingMapItemReplies.removeAll { $0.recipientUID == sender.id }
        Task {
            for reply in due {
                do { try await deliverMapItemReply(reply, route: route) }
                catch {
                    pendingMapItemReplies.append(reply)
                    chatLogger.error("Queued map item reply failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func mapItemTitle(_ item: IncomingMapEntity) -> String {
        item.callSign.flatMap { $0.isEmpty ? nil : $0 } ?? item.id
    }

    func chatUnavailableReason(for contact: IncomingMapEntity) -> String? {
        if !settings.chatEnabled { return "Enable Chat in settings." }
        if !contact.isUser { return "Chat is available for user contacts only." }
        guard let route = contact.chatRoute else { return "The contact's chat transport is unknown." }
        switch route {
        case .companion:
            if !companionClient.isReady { return "Connect Companion to the contact's TAK server to send chat." }
        case .multicast:
            if !multicastClient.isReady { return "Connect local TAK multicast to send chat." }
        case .sitx:
            if !sitxClient.isSitxConnected { return "Connect to this contact's Sit(x) source to send chat." }
        }
        return nil
    }

    func sendContactChat(uid: String, route: ContactChatRoute, text: String) async throws {
        let conversation = ContactConversation(uid: uid, route: route)
        let contact = incomingEntities.first(where: { $0.id == uid && $0.chatRoute == route })
        guard contact != nil || contactMessages[conversation] != nil else {
            throw ContactChatFailure.message("This contact is no longer available on that transport.")
        }
        guard settings.chatEnabled else { throw ContactChatFailure.message("Enable Chat in settings.") }
        if let contact, let reason = chatUnavailableReason(for: contact) { throw ContactChatFailure.message(reason) }
        let ownUID = SitxClient.deviceID()
        let xml = try TAKChatMessage.outgoing(senderUID: ownUID,
            senderCallSign: SitxCoT.pliCallSign(settings.callSign, uid: ownUID),
            recipientUID: uid, recipientCallSign: contact?.callSign ?? chatTitle(for: conversation), text: text)
        switch route {
        case .companion(let serverID): try await companionClient.sendChat(xml, serverID: serverID)
        case .multicast: try await multicastClient.send(xml)
        case .sitx: try await sitxClient.sendContactChat(xml)
        }
        chatLogger.notice("Outgoing GeoChat accepted by transport")
        guard let message = TAKChatMessage.parse(xml, ownUID: ownUID) else {
            throw ContactChatFailure.message("Unable to record the outgoing chat message.")
        }
        recordChat(message, route: route)
    }

    private func recordChat(_ message: TAKChatMessage, route: ContactChatRoute) {
        let ownUID = SitxClient.deviceID()
        let other = message.senderUID == ownUID ? message.recipientUID : message.senderUID
        let key = ContactConversation(uid: other, route: route)
        if chatInbox.record(message, conversation: key, ownUID: ownUID), settings.chatEnabled {
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
            sourceServerID: sourceServerID, sourceGeneration: sourceGeneration, expiresAt: expiresAt,
            isUser: metadata.isUser == true || SitxCoT.isUser(type: payload.type), sourceTransport: sourceTransport
        )
        let isNew: Bool
        if let index = incomingEntities.firstIndex(where: { $0.id == payload.uid }) {
            incomingEntities[index] = entity
            isNew = false
        } else {
            incomingEntities.append(entity)
            isNew = true
        }
        if !entity.isUser {
            // Only live traffic notifies; cache restores and snapshots repopulate silently.
            let shouldNotify = isNew ? (payload.sentAt == nil || isNewerSend) : isResend
            if notifyNewPoint, shouldNotify, expiresAt.map({ $0 > Date() }) ?? true {
                unseenIncomingPointIDs.insert(entity.id)
                WKInterfaceDevice.current().play(.notification)
                chatLogger.notice("Incoming map point \(entity.type, privacy: .public) \(isNew ? "recorded" : "re-sent", privacy: .public); notification requested")
            }
            if isNewerSend, let sent = payload.sentAt { recordPointSend(payload.uid, at: sent) }
        }
        if entity.isUser, !pendingMapItemReplies.isEmpty { flushMapItemReplies(to: entity) }
        pruneIncomingEntities(now: now)
        if incomingEntities.count > 50 {
            incomingEntities.sort { $0.lastSeen > $1.lastSeen }
            incomingEntities.removeLast(incomingEntities.count - 50)
        }
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
            now.timeIntervalSince($0.lastSeen) > 300 || ($0.expiresAt.map { $0 <= now } ?? false)
        }
        companionMapCache.prune(now: now)
        if !unseenIncomingPointIDs.isEmpty {
            let current = Set(incomingEntities.lazy.filter { !$0.isUser }.map(\.id))
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

    private func refreshSource(_ id: UUID, generation: Int) {
        guard generation > sourceGenerations[id, default: 0] else { return }
        sourceGenerations[id] = generation
        incomingEntities.removeAll { $0.sourceServerID == id && $0.sourceGeneration < generation }
        companionMapCache.remove(sourceID: id, beforeGeneration: generation)
        saveCompanionMapCache()
    }

    private func saveCompanionMapCache() {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(companionMapCache), forKey: Self.companionCacheKey)
            mapCacheError = nil
        } catch { mapCacheError = "Unable to save cached map: \(error.localizedDescription)" }
    }

    private func saveMarkers() {
        if let data = try? JSONEncoder().encode(markers) {
            UserDefaults.standard.set(data, forKey: Self.markerStorageKey)
        }
    }

    func startEmergencyAlert(type: ManualAlertType) {
        guard activeAlertType == nil else { return }
        activeAlertType = type
        publishAlertReportingState()
        Task {
            try? await transport.sendEmergencyAlert(state: .alert, type: type.rawValue)
        }
    }

    func cancelEmergencyAlert() {
        guard let type = activeAlertType else { return }
        activeAlertType = nil
        publishAlertReportingState()
        Task {
            try? await transport.sendEmergencyAlert(state: .cancel, type: type.rawValue)
        }
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

        let pending = automaticAlertTask
        automaticAlertTask = Task {
            await pending?.value
            if let previousCategory, previousCategory != category {
                do {
                    try await transport.sendEmergencyAlert(state: .cancel, type: previousCategory.rawValue)
                    self.deliveredAutomaticAlert = nil
                } catch {
                    automaticAlertDeliveryFailed = true
                }
            }
            if let category, category == activeAutomaticAlert, deliveredAutomaticAlert == nil {
                do {
                    try await transport.sendEmergencyAlert(state: .alert, type: category.rawValue)
                    deliveredAutomaticAlert = category
                    automaticAlertDeliveryFailed = false
                } catch {
                    automaticAlertDeliveryFailed = true
                }
            } else if category == nil {
                automaticAlertDeliveryFailed = false
            }
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

        let pending = environmentalAlertTasks[category]
        environmentalAlertTasks[category] = Task {
            await pending?.value
            do {
                if active {
                    try await transport.sendEmergencyAlert(state: .alert, type: category.rawValue)
                    deliveredEnvironmentalAlerts.insert(category)
                    automaticAlertDeliveryFailed = false
                } else {
                    try await transport.sendEmergencyAlert(state: .cancel, type: category.rawValue)
                    deliveredEnvironmentalAlerts.remove(category)
                }
            } catch {
                automaticAlertDeliveryFailed = true
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
        guard transport.pliReportingRoute == .standaloneSitx else {
            Task {
                try? await transport.sendPLI(coordinate: location.coordinate)
            }
            return
        }
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
        guard lastPLISentAt.map({ Date().timeIntervalSince($0) >= effectiveInterval }) ?? true else { return }
        isSendingPLI = true
        Task {
            defer { isSendingPLI = false }
            do {
                try await transport.sendPLI(coordinate: location.coordinate)
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
