import CoreLocation
import Foundation

/// Owns the phone's CLLocationManager for automatic PLI reporting. It only starts when PhoneBridgeModel's
/// gate allows it and stops as soon as servers, identity or authorization are no longer valid.
@MainActor
final class PhoneLocationReporter: NSObject, CLLocationManagerDelegate {
    private static let alwaysRequestedKey = "WearTAK.companion.alwaysLocationRequested"
    private let manager = CLLocationManager()
    private let defaults: UserDefaults
    private(set) var isRunning = false
    private(set) var servicesEnabled = true
    var onFix: ((PhoneLocationFix) -> Void)?
    var onAuthorizationChange: (() -> Void)?
    var onError: ((String) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        manager.delegate = self
        manager.activityType = .other
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = kCLDistanceFilterNone
        // Automatic pauses cannot resume in the background, which would silently end reporting.
        manager.pausesLocationUpdatesAutomatically = false
        refreshServicesEnabled()
    }

    var authorization: PhoneAuthorization {
        switch manager.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .authorizedWhenInUse: return .whenInUse
        case .authorizedAlways: return .always
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    var preciseLocation: Bool { manager.accuracyAuthorization == .fullAccuracy }

    var permissionSummary: String {
        switch authorization {
        case .notDetermined: return "Not requested"
        case .whenInUse: return "While Using (starts only while Companion is open)"
        case .always: return "Always"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        }
    }

    func requestWhenInUse() { manager.requestWhenInUseAuthorization() }

    func start(appActive: Bool) {
        guard !isRunning else { return }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        isRunning = true
        // Escalate once, from the foreground, after While Using is granted and reporting has started. Always lets
        // Companion resume reporting when iOS wakes it in the background for a watch request.
        if appActive, authorization == .whenInUse, !defaults.bool(forKey: Self.alwaysRequestedKey) {
            defaults.set(true, forKey: Self.alwaysRequestedKey)
            manager.requestAlwaysAuthorization()
        }
    }

    func stop() {
        guard isRunning else { return }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        isRunning = false
    }

    func refreshServicesEnabled() {
        Task { [weak self] in
            // locationServicesEnabled() can block, so it is kept off the main actor.
            let enabled = await Task.detached { CLLocationManager.locationServicesEnabled() }.value
            guard let self, self.servicesEnabled != enabled else { return }
            self.servicesEnabled = enabled
            self.onAuthorizationChange?()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            self?.refreshServicesEnabled()
            self?.onAuthorizationChange?()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let coordinate = location.coordinate
        let horizontal = location.horizontalAccuracy, altitude = location.altitude
        let vertical = location.verticalAccuracy, speed = location.speed
        let course = location.course, timestamp = location.timestamp
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            self.onFix?(PhoneLocationFix(latitude: coordinate.latitude, longitude: coordinate.longitude,
                horizontalAccuracy: horizontal, altitude: altitude, verticalAccuracy: vertical,
                speed: speed, course: course, timestamp: timestamp))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let code = (error as? CLError)?.code
        let description = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch code {
            case .denied:
                self.stop()
                self.onError?("Location access denied. Allow it in Settings > WearTAK Companion > Location.")
                self.onAuthorizationChange?()
            case .locationUnknown:
                self.onError?("Waiting for a phone GPS fix.")
            default:
                self.onError?("Phone GPS error: \(description)")
            }
        }
    }
}
