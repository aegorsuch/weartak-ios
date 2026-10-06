import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// The watch user's TAK identity and reporting settings, published by the watch through
/// WatchConnectivity application context. Companion reports phone GPS only under this identity.
struct WatchReportingIdentity: Codable, Equatable {
    nonisolated static let contextKey = "WearTAKWatch.reportingIdentity"
    static let currentVersion = 1
    static let maximumAge: TimeInterval = 7 * 86_400
    static let maximumClockSkew: TimeInterval = 300

    var version: Int = Self.currentVersion
    var uid: String
    var callSign: String
    var team: String
    var role: String
    var companionSelected: Bool
    var constantStrategy: Bool
    var constantInterval: Int
    var stationaryInterval: Int
    var onFootInterval: Int
    var vehicleInterval: Int
    var issuedAt: Date
    var alertingInterval: Int?
    var alertActive: Bool?

    /// Matches the watch's own PLI callsign fallback so both sources describe the same user.
    var resolvedCallSign: String {
        let trimmed = callSign.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "WEARTAK-\(uid.prefix(8))" : trimmed
    }

    var resolvedRole: String {
        let trimmed = role.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Team Member" : trimmed
    }

    func hasSameSettings(as other: Self) -> Bool {
        var copy = other
        copy.issuedAt = issuedAt
        return copy == self
    }

    func validated(now: Date = Date()) throws -> Self {
        guard version == Self.currentVersion else { throw Failure.unsupportedVersion }
        guard UUID(uuidString: uid) != nil, uid == uid.lowercased() else { throw Failure.invalidUID }
        guard Self.isSafe(callSign, maximum: 64, allowEmpty: true) else { throw Failure.invalidField("callsign") }
        guard Self.isSafe(team, maximum: 32, allowEmpty: false) else { throw Failure.invalidField("team") }
        guard Self.isSafe(role, maximum: 64, allowEmpty: true) else { throw Failure.invalidField("role") }
        for value in [constantInterval, stationaryInterval, onFootInterval, vehicleInterval] where !(1...86_400).contains(value) {
            throw Failure.invalidField("reporting interval")
        }
        if let alertingInterval, !(1...86_400).contains(alertingInterval) {
            throw Failure.invalidField("alerting interval")
        }
        if alertActive == true, alertingInterval == nil {
            throw Failure.invalidField("alerting interval")
        }
        guard issuedAt.timeIntervalSince(now) <= Self.maximumClockSkew else { throw Failure.futureDated }
        guard now.timeIntervalSince(issuedAt) <= Self.maximumAge else { throw Failure.stale }
        guard companionSelected else { throw Failure.companionNotSelected }
        return self
    }

    func contextValue() throws -> Data { try JSONEncoder().encode(self) }

    /// Returns nil when the watch has not published an identity; throws for malformed values.
    static func decode(contextValue: Any?) throws -> Self? {
        guard let contextValue else { return nil }
        guard let data = contextValue as? Data, data.count <= 4_096 else { throw Failure.invalidField("identity payload") }
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw Failure.invalidField("identity payload") }
    }

    private static func isSafe(_ value: String, maximum: Int, allowEmpty: Bool) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (allowEmpty || !trimmed.isEmpty) && value.count <= maximum &&
            !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    enum Failure: LocalizedError, Equatable {
        case missing, unsupportedVersion, invalidUID, invalidField(String), stale, futureDated,
             companionNotSelected, mismatchedUID, watchUnavailable

        var errorDescription: String? {
            switch self {
            case .missing: return "Open WearTAK on the watch to share its TAK identity with Companion."
            case .unsupportedVersion: return "Update both WearTAK apps to matching versions."
            case .invalidUID: return "The watch sent an invalid TAK UID."
            case .invalidField(let field): return "The watch sent an invalid \(field)."
            case .stale: return "The watch identity is more than 7 days old. Open WearTAK on the watch."
            case .futureDated: return "The watch identity is dated in the future. Check the watch and phone clocks."
            case .companionNotSelected: return "Select WearTAK Companion as the watch's TAK Relay to report phone GPS."
            case .mismatchedUID: return "The watch is reporting a different TAK UID. Open WearTAK on the watch to resync."
            case .watchUnavailable: return "No paired watch with WearTAK installed is active."
            }
        }
    }
}

/// Latest watch vitals, shared with Companion so phone-GPS PLI carries the same biometrics as the watch's own PLI.
/// Wire format matches WearOS WearTAK: readable `<remarks>` plus a structured `<biometrics>` block.
struct WatchBiometrics: Codable, Equatable {
    nonisolated static let contextKey = "WearTAKWatch.biometrics"
    static let maximumAge: TimeInterval = 300
    static let deviceModel = "WATCHOS"

    var heartRate: Int?
    var exertion: Int?
    var measuredAt: Date?

    /// Readings older than five minutes (or from the future) are reported as N/A.
    func fresh(now: Date = Date()) -> Self {
        guard let measuredAt, now.timeIntervalSince(measuredAt) <= Self.maximumAge,
              measuredAt.timeIntervalSince(now) <= WatchReportingIdentity.maximumClockSkew else { return Self() }
        return Self(heartRate: heartRate.flatMap { (1...300).contains($0) ? $0 : nil },
                    exertion: exertion.flatMap { (0...250).contains($0) ? $0 : nil }, measuredAt: measuredAt)
    }

    var remarks: String {
        "Exert:\(exertion.map(String.init) ?? "N/A")%;HR:\(heartRate.map(String.init) ?? "N/A")"
    }

    /// `<biometrics>` device element; `alertAttributes` are already-escaped attributes for alert events.
    func biometricsElement(uid: String, alertAttributes: String = "") -> String {
        "<biometrics\(alertAttributes)><device><model>\(Self.deviceModel)</model><uid>\(PhonePLI.escape(uid))</uid>" +
            "<hr>\(heartRate.map(String.init) ?? "N/A")</hr>" +
            "<exert>\(exertion.map(String.init) ?? "N/A")</exert></device></biometrics>"
    }

    func pliDetail(uid: String) -> String {
        "<remarks>\(remarks)</remarks>" + biometricsElement(uid: uid)
    }

    func contextValue() throws -> Data { try JSONEncoder().encode(self) }

    static func decode(contextValue: Any?) -> Self? {
        guard let data = contextValue as? Data, data.count <= 1_024 else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

struct PhoneLocationFix: Equatable {
    var latitude: Double
    var longitude: Double
    var horizontalAccuracy: Double
    var altitude: Double
    var verticalAccuracy: Double
    var speed: Double
    var course: Double
    var timestamp: Date
}

enum PhoneReportingPolicy {
    static let minimumInterval: TimeInterval = 10
    static let maximumInterval: TimeInterval = 600
    static let maximumHorizontalAccuracy: Double = 100
    static let maximumFixAge: TimeInterval = 30
    static let maximumFixFutureSkew: TimeInterval = 5
    static let suppressionGrace: TimeInterval = 90

    /// Uses the watch's reporting strategy, bounded so the phone neither floods servers nor goes silent.
    static func interval(for identity: WatchReportingIdentity, speed: Double) -> TimeInterval {
        let base: Int
        if identity.alertActive == true, let alertingInterval = identity.alertingInterval {
            base = alertingInterval
        } else if identity.constantStrategy { base = identity.constantInterval }
        else if speed < 0.5 { base = identity.stationaryInterval }
        else if speed < 2.5 { base = identity.onFootInterval }
        else { base = identity.vehicleInterval }
        return min(max(TimeInterval(base), minimumInterval), maximumInterval)
    }

    static func staleLifetime(interval: TimeInterval) -> TimeInterval {
        min(max(interval, minimumInterval), maximumInterval) * 3 + 60
    }

    static func validate(_ fix: PhoneLocationFix, now: Date = Date()) throws {
        guard (-90...90).contains(fix.latitude), (-180...180).contains(fix.longitude),
              !(fix.latitude == 0 && fix.longitude == 0) else { throw FixFailure.invalidCoordinate }
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= maximumHorizontalAccuracy else {
            throw FixFailure.inaccurate(fix.horizontalAccuracy)
        }
        guard fix.timestamp.timeIntervalSince(now) <= maximumFixFutureSkew else { throw FixFailure.futureDated }
        guard now.timeIntervalSince(fix.timestamp) <= maximumFixAge else { throw FixFailure.stale }
    }

    static func isDue(lastSentAt: Date?, interval: TimeInterval, now: Date = Date()) -> Bool {
        guard let lastSentAt else { return true }
        let elapsed = now.timeIntervalSince(lastSentAt)
        return elapsed < 0 || elapsed >= interval
    }

    /// The watch PLI is dropped only while the phone has recently reported this same user.
    static func suppressesWatchPLI(lastPhoneReportAt: Date?, interval: TimeInterval, now: Date = Date()) -> Bool {
        guard let lastPhoneReportAt else { return false }
        let elapsed = now.timeIntervalSince(lastPhoneReportAt)
        return elapsed >= -maximumFixFutureSkew && elapsed <= interval + suppressionGrace
    }

    static func canUsePhonePLI(lastPhoneReportAt: Date?, latestFix: PhoneLocationFix?,
                              interval: TimeInterval, now: Date = Date()) -> Bool {
        guard let latestFix else { return false }
        do { try validate(latestFix, now: now) }
        catch { return false }
        return suppressesWatchPLI(lastPhoneReportAt: lastPhoneReportAt, interval: interval, now: now)
    }

    enum FixFailure: LocalizedError, Equatable {
        case invalidCoordinate, inaccurate(Double), stale, futureDated
        var errorDescription: String? {
            switch self {
            case .invalidCoordinate: return "Phone GPS returned an invalid coordinate."
            case .inaccurate(let meters):
                return meters < 0 ? "Phone GPS fix has no accuracy estimate."
                    : "Phone GPS accuracy is \(Int(meters)) m; waiting for 100 m or better."
            case .stale: return "Phone GPS fix is older than 30 seconds."
            case .futureDated: return "Phone GPS fix is dated in the future."
            }
        }
    }
}

enum PhoneAuthorization: Equatable {
    case notDetermined, whenInUse, always, denied, restricted
}

/// Explains what the user must change so Companion keeps TAK connected while the phone is locked.
/// iOS only lets Companion hold TAK streams in the background while phone location reporting runs.
enum PhoneBackgroundAdvice {
    static func message(hasServers: Bool, authorization: PhoneAuthorization, preciseLocation: Bool,
                        servicesEnabled: Bool) -> String? {
        guard hasServers else { return nil }
        guard servicesEnabled else { return "Turn on Location Services so the watch stays connected to TAK while this phone is locked." }
        switch authorization {
        case .always:
            return preciseLocation ? nil
                : "Turn on Precise Location so the watch stays connected to TAK while this phone is locked."
        case .restricted:
            return "Location access is restricted, so the watch will lose TAK when this phone is locked."
        case .notDetermined, .whenInUse, .denied:
            return "Set Location to Always (with Precise Location on) so the watch stays connected to TAK while this phone is locked or in your pocket."
        }
    }

    /// Short form shown on the watch.
    static func watchReason(authorization: PhoneAuthorization, preciseLocation: Bool, servicesEnabled: Bool) -> String? {
        guard servicesEnabled else { return "turn on Location Services" }
        switch authorization {
        case .always: return preciseLocation ? nil : "turn on Precise Location"
        case .restricted: return "location restricted"
        case .notDetermined, .whenInUse, .denied: return "set Location to Always"
        }
    }
}

/// Pure decision for whether phone location reporting may run, so lifecycle guards are testable.
enum PhoneReportingGate {
    enum Decision: Equatable {
        case run
        case requestWhenInUse
        case blocked(String)
    }

    static func decide(enabledConfiguredServers: Int,
                       identity: Result<WatchReportingIdentity, WatchReportingIdentity.Failure>,
                       authorization: PhoneAuthorization, preciseLocation: Bool, servicesEnabled: Bool,
                       appActive: Bool, alreadyRunning: Bool) -> Decision {
        guard enabledConfiguredServers > 0 else { return .blocked("Enable a TAK server with a certificate.") }
        guard servicesEnabled else { return .blocked("Location Services are off on this phone.") }
        switch authorization {
        case .denied: return .blocked("Location access denied. Allow it in Settings > WearTAK Companion > Location.")
        case .restricted: return .blocked("Location access is restricted on this phone.")
        case .notDetermined:
            return appActive ? .requestWhenInUse : .blocked("Open Companion to allow location access.")
        case .whenInUse, .always: break
        }
        guard preciseLocation else { return .blocked("Turn on Precise Location for WearTAK Companion in Settings.") }
        if case .failure(let failure) = identity { return .blocked(failure.localizedDescription) }
        // While-in-use access only permits starting in the foreground; an already running session may continue.
        guard appActive || alreadyRunning || authorization == .always else {
            return .blocked("Open Companion to start phone location reporting.")
        }
        return .run
    }
}

enum PhonePLI {
    static let type = "a-f-G-U-C"

    static func event(identity: WatchReportingIdentity, fix: PhoneLocationFix, interval: TimeInterval,
                      appVersion: String, osVersion: String, biometrics: WatchBiometrics? = nil,
                      now: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let time = formatter.string(from: now)
        let start = formatter.string(from: min(fix.timestamp, now))
        let stale = formatter.string(from: now.addingTimeInterval(PhoneReportingPolicy.staleLifetime(interval: interval)))
        let hasAltitude = fix.verticalAccuracy >= 0
        let hae = hasAltitude ? number(fix.altitude) : "9999999"
        let le = hasAltitude ? number(fix.verticalAccuracy) : "9999999"
        let name = escape(identity.resolvedCallSign)
        var detail = "<contact callsign=\"\(name)\" endpoint=\"*:-1:stcp\"/>" +
            "<__group name=\"\(escape(identity.team))\" role=\"\(escape(identity.resolvedRole))\"/>" +
            "<takv device=\"iPhone\" platform=\"WearTAK Companion\" os=\"\(escape(osVersion))\" version=\"\(escape(appVersion))\"/>" +
            "<uid Droid=\"\(name)\"/>" +
            "<precisionlocation geopointsrc=\"GPS\" altsrc=\"\(hasAltitude ? "GPS" : "???")\"/>"
        if fix.speed >= 0, fix.course >= 0 {
            detail += "<track course=\"\(number(fix.course))\" speed=\"\(number(fix.speed))\"/>"
        }
        if let biometrics { detail += biometrics.fresh(now: now).pliDetail(uid: identity.uid) }
        return "<event version=\"2.0\" uid=\"\(escape(identity.uid))\" type=\"\(type)\" time=\"\(time)\" start=\"\(start)\" stale=\"\(stale)\" how=\"m-g\">" +
            "<point lat=\"\(number(fix.latitude, digits: 7))\" lon=\"\(number(fix.longitude, digits: 7))\" hae=\"\(hae)\" ce=\"\(number(fix.horizontalAccuracy))\" le=\"\(le)\"/>" +
            "<detail>\(detail)</detail></event>"
    }

    /// True only for the watch's own position report: matching UID and user PLI type. Alerts and points never match.
    static func isSelfPLI(_ xml: String, uid: String) -> Bool {
        guard let header = header(xml) else { return false }
        return header.uid == uid && header.type == type
    }

    static func header(_ xml: String) -> (uid: String, type: String)? {
        let data = Data(xml.utf8)
        guard CoTStreamFramer.isEvent(data) else { return nil }
        let delegate = EventHeaderParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let uid = delegate.uid, let type = delegate.type else { return nil }
        return (uid, type)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func number(_ value: Double, digits: Int = 1) -> String {
        String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

private final class EventHeaderParser: NSObject, XMLParserDelegate {
    var uid: String?
    var type: String?
    private var started = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        guard !started else { return }
        started = true
        if elementName == "event" { uid = attributes["uid"]; type = attributes["type"] }
    }
}
