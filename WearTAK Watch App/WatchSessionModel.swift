import Combine
import CoreLocation
import Foundation
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
    let kind: MarkerKind
    let latitude: Double
    let longitude: Double
    let createdAt: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
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
    func sendEmergencyAlert(state: EmergencyState, type: String) async throws
}

enum TAKTransportError: Error {
    case notConfigured
}

struct UnconfiguredTAKTransport: TAKTransport {
    func connect() async throws { throw TAKTransportError.notConfigured }
    func sendPLI(coordinate: CLLocationCoordinate2D) async throws { throw TAKTransportError.notConfigured }
    func sendMarker(_ marker: WatchMarker) async throws { throw TAKTransportError.notConfigured }
    func sendEmergencyAlert(state: EmergencyState, type: String) async throws { throw TAKTransportError.notConfigured }
}

@MainActor
final class WatchSessionModel: NSObject, ObservableObject {
    private static let markerStorageKey = "WearTAK.droppedPoints"

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var markers: [WatchMarker] = []
    @Published private(set) var activeAlertType: ManualAlertType?
    @Published private(set) var activeAutomaticAlert: AutomaticAlertCategory?
    @Published private(set) var automaticAlertDeliveryFailed = false
    @Published var selectedMarkerKind: MarkerKind = .unknown

    private let locationManager = CLLocationManager()
    private let transport: TAKTransport
    private var automaticAlertTask: Task<Void, Never>?
    private var deliveredAutomaticAlert: AutomaticAlertCategory?

    init(transport: TAKTransport? = nil) {
        self.transport = transport ?? UnconfiguredTAKTransport()
        super.init()
        if let data = UserDefaults.standard.data(forKey: Self.markerStorageKey) {
            markers = (try? JSONDecoder().decode([WatchMarker].self, from: data)) ?? []
        }
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
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

    func connect() {
        connectionState = .connecting
        Task {
            do {
                try await transport.connect()
                connectionState = .connected
                if let coordinate = lastLocation?.coordinate {
                    try await transport.sendPLI(coordinate: coordinate)
                }
            } catch {
                connectionState = error is TAKTransportError ? .unconfigured : .failed
            }
        }
    }

    func dropMarker() -> Bool {
        guard let coordinate = lastLocation?.coordinate else { return false }
        let marker = WatchMarker(
            id: UUID(),
            kind: selectedMarkerKind,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            createdAt: Date()
        )
        markers.insert(marker, at: 0)
        if let data = try? JSONEncoder().encode(markers) {
            UserDefaults.standard.set(data, forKey: Self.markerStorageKey)
        }
        Task {
            try? await transport.sendMarker(marker)
        }
        return true
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
}

extension WatchSessionModel: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus == .authorizedAlways ||
                manager.authorizationStatus == .authorizedWhenInUse else { return }
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        lastLocation = location
        guard connectionState == .connected else { return }
        Task {
            try? await transport.sendPLI(coordinate: location.coordinate)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        lastLocation = nil
    }
}
