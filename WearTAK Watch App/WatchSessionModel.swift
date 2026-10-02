import Combine
import CoreLocation
import Foundation
import Network
import WatchKit

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

protocol TAKTransport {
    func connect() async throws
    func sendPLI(coordinate: CLLocationCoordinate2D) async throws
    func sendMarker(_ marker: WatchMarker) async throws
    func deleteMarker(uid: String) async throws
    func sendEmergencyAlert(state: EmergencyState, type: String) async throws
    func incomingEntities() -> AsyncStream<EntityRelayPayload>
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
    private static let markerStorageKey = "WearTAK.droppedPoints"

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var markers: [WatchMarker] = []
    @Published private(set) var incomingEntities: [IncomingMapEntity] = []
    @Published private(set) var bloodhoundTargetID: UUID?
    @Published private(set) var headingDegrees: Double?
    @Published private(set) var activeAlertType: ManualAlertType?
    @Published private(set) var activeAutomaticAlert: AutomaticAlertCategory?
    @Published private(set) var activeEnvironmentalAlerts: Set<EnvironmentalAlertCategory> = []
    @Published private(set) var automaticAlertDeliveryFailed = false
    @Published var selectedMarkerKind: MarkerKind = .unknown

    private let locationManager = CLLocationManager()
    private let transport: TAKTransport
    private let settings: AppSettings
    private var incomingEntityTask: Task<Void, Never>?
    private var incomingPruneTimer: Timer?
    private var automaticAlertTask: Task<Void, Never>?
    private var deliveredAutomaticAlert: AutomaticAlertCategory?
    private var environmentalAlertTasks: [EnvironmentalAlertCategory: Task<Void, Never>] = [:]
    private var deliveredEnvironmentalAlerts: Set<EnvironmentalAlertCategory> = []
    private var bloodhoundProximityNotified = false
    private var isUpdatingHeading = false
    private var lastPLISentAt: Date?
    private let networkPathMonitor = NWPathMonitor()
    private var isOnWiFi = false

    init(transport: TAKTransport? = nil, settings: AppSettings) {
        self.transport = transport ?? UnconfiguredTAKTransport()
        self.settings = settings
        super.init()
        if let data = UserDefaults.standard.data(forKey: Self.markerStorageKey) {
            markers = (try? JSONDecoder().decode([WatchMarker].self, from: data)) ?? []
        }
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        networkPathMonitor.pathUpdateHandler = { [weak self] path in
            let usesWiFi = path.status == .satisfied && path.usesInterfaceType(.wifi)
            Task { @MainActor [weak self] in
                self?.isOnWiFi = usesWiFi
            }
        }
        networkPathMonitor.start(queue: DispatchQueue(label: "WearTAK.networkPath"))
        incomingPruneTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pruneIncomingEntities() }
        }
    }

    func requestLocation() {
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

    func startHeadingUpdates() {
        guard CLLocationManager.headingAvailable(), !isUpdatingHeading else { return }
        isUpdatingHeading = true
        locationManager.startUpdatingHeading()
    }

    func stopHeadingUpdates() {
        guard isUpdatingHeading else { return }
        isUpdatingHeading = false
        locationManager.stopUpdatingHeading()
        headingDegrees = nil
    }

    func connect() {
        connectionState = .connecting
        Task {
            do {
                try await transport.connect()
                connectionState = .connected
                if locationManager.authorizationStatus == .authorizedAlways ||
                    locationManager.authorizationStatus == .authorizedWhenInUse {
                    locationManager.startUpdatingLocation()
                }
                incomingEntityTask?.cancel()
                incomingEntityTask = Task {
                    for await payload in transport.incomingEntities() {
                        guard !Task.isCancelled else { break }
                        receiveEntity(payload)
                    }
                }
                if let coordinate = lastLocation?.coordinate {
                    try await transport.sendPLI(coordinate: coordinate)
                    lastPLISentAt = Date()
                }
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
        saveMarkers()
        Task {
            for id in ids {
                try? await transport.deleteMarker(uid: id.uuidString)
            }
        }
    }

    func toggleBloodhound(id: UUID) {
        bloodhoundTargetID = (bloodhoundTargetID == id) ? nil : id
        bloodhoundProximityNotified = false
    }

    var bloodhoundTarget: WatchMarker? {
        guard let bloodhoundTargetID else { return nil }
        return markers.first { $0.id == bloodhoundTargetID }
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

    func receiveEntity(_ payload: EntityRelayPayload, at now: Date = Date()) {
        guard !payload.uid.isEmpty,
              CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: payload.lat, longitude: payload.lon)) else { return }
        let entity = IncomingMapEntity(
            id: payload.uid, latitude: payload.lat, longitude: payload.lon,
            type: payload.type, lastSeen: now
        )
        if let index = incomingEntities.firstIndex(where: { $0.id == payload.uid }) {
            incomingEntities[index] = entity
        } else {
            incomingEntities.append(entity)
        }
        pruneIncomingEntities(now: now)
        if incomingEntities.count > 50 {
            incomingEntities.sort { $0.lastSeen > $1.lastSeen }
            incomingEntities.removeLast(incomingEntities.count - 50)
        }
    }

    func pruneIncomingEntities(now: Date = Date()) {
        incomingEntities.removeAll { now.timeIntervalSince($0.lastSeen) > 300 }
    }

    private func saveMarkers() {
        if let data = try? JSONEncoder().encode(markers) {
            UserDefaults.standard.set(data, forKey: Self.markerStorageKey)
        }
    }

    func startEmergencyAlert(type: ManualAlertType) {
        guard activeAlertType == nil else { return }
        activeAlertType = type
        Task {
            try? await transport.sendEmergencyAlert(state: .alert, type: type.rawValue)
        }
    }

    func cancelEmergencyAlert() {
        guard let type = activeAlertType else { return }
        activeAlertType = nil
        Task {
            try? await transport.sendEmergencyAlert(state: .cancel, type: type.rawValue)
        }
    }

    func updateAutomaticAlert(_ category: AutomaticAlertCategory?) {
        guard category != activeAutomaticAlert else { return }
        activeAutomaticAlert = category
        automaticAlertDeliveryFailed = category != nil && connectionState != .connected
        if category != nil {
            WKInterfaceDevice.current().play(.notification)
        }

        let pending = automaticAlertTask
        automaticAlertTask = Task {
            await pending?.value
            if let deliveredAutomaticAlert, deliveredAutomaticAlert != category {
                do {
                    try await transport.sendEmergencyAlert(state: .cancel, type: deliveredAutomaticAlert.rawValue)
                    self.deliveredAutomaticAlert = nil
                } catch {
                    automaticAlertDeliveryFailed = true
                    return
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
                } else if deliveredEnvironmentalAlerts.contains(category) {
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
        guard manager.authorizationStatus == .authorizedAlways ||
                manager.authorizationStatus == .authorizedWhenInUse else { return }
        if connectionState == .connected {
            manager.startUpdatingLocation()
        } else {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        lastLocation = location
        checkBloodhoundProximity(at: location)
        guard connectionState == .connected else { return }
        sendPLIIfDue(for: location)
    }

    private func sendPLIIfDue(for location: CLLocation) {
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
        lastPLISentAt = Date()
        Task {
            try? await transport.sendPLI(coordinate: location.coordinate)
        }
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
        headingDegrees = newHeading.magneticHeading
    }
}
