import Combine
import CoreLocation
import Foundation

enum ConnectionState: String {
    case disconnected = "Offline"
    case connecting = "Connecting"
    case connected = "Connected"
    case failed = "Connection failed"
}

enum EmergencyState: String, Codable {
    case alert = "ALERT"
    case cancel = "CANCEL"
}

struct WatchMarker: Identifiable {
    let id = UUID()
    let kind: MarkerKind
    let coordinate: CLLocationCoordinate2D?
    let createdAt: Date
}

enum MarkerKind: String, CaseIterable, Identifiable {
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

struct UnconfiguredTAKTransport: TAKTransport {
    func connect() async throws {}
    func sendPLI(coordinate: CLLocationCoordinate2D) async throws {}
    func sendMarker(_ marker: WatchMarker) async throws {}
    func sendEmergencyAlert(state: EmergencyState, type: String) async throws {}
}

@MainActor
final class WatchSessionModel: NSObject, ObservableObject {
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var markers: [WatchMarker] = []
    @Published private(set) var isAlerting = false
    @Published var selectedMarkerKind: MarkerKind = .unknown

    private let locationManager = CLLocationManager()
    private let transport: TAKTransport

    init(transport: TAKTransport = UnconfiguredTAKTransport()) {
        self.transport = transport
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestLocation() {
        locationManager.requestWhenInUseAuthorization()
        locationManager.requestLocation()
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
                connectionState = .failed
            }
        }
    }

    func dropMarker() {
        let marker = WatchMarker(
            kind: selectedMarkerKind,
            coordinate: lastLocation?.coordinate,
            createdAt: Date()
        )
        markers.insert(marker, at: 0)
        Task {
            try? await transport.sendMarker(marker)
        }
    }

    func toggleEmergencyAlert() {
        let state: EmergencyState = isAlerting ? .cancel : .alert
        isAlerting.toggle()
        Task {
            try? await transport.sendEmergencyAlert(state: state, type: "Manual Alert")
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
}
