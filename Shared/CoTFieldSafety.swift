import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Alert coordinates are last-known measurements, never an unqualified live fix.
struct AlertLocationHistory {
    static let storageKey = "WearTAK.lastValidLocation"
    static let maximumAge: TimeInterval = 120
    private(set) var lastValid: PhoneLocationFix?

    mutating func receive(_ fix: PhoneLocationFix, now: Date = Date()) {
        guard Self.isUsable(fix, now: fix.timestamp), fix.timestamp <= now.addingTimeInterval(5),
              lastValid.map({ fix.timestamp >= $0.timestamp }) ?? true else { return }
        lastValid = fix
    }

    func usable(at now: Date = Date()) -> PhoneLocationFix? {
        lastValid.flatMap { Self.isUsable($0, now: now) ? $0 : nil }
    }

    func lastKnown(at now: Date = Date()) -> PhoneLocationFix? {
        lastValid.flatMap { $0.timestamp <= now.addingTimeInterval(5) ? $0 : nil }
    }

    static func circularError(_ fix: PhoneLocationFix, now: Date = Date()) -> Double {
        isUsable(fix, now: now) ? fix.horizontalAccuracy : 9_999_999
    }

    static func isUsable(_ fix: PhoneLocationFix, now: Date) -> Bool {
        fix.latitude.isFinite && fix.longitude.isFinite &&
            (-90...90).contains(fix.latitude) && (-180...180).contains(fix.longitude) &&
            !(fix.latitude == 0 && fix.longitude == 0) &&
            fix.horizontalAccuracy.isFinite && (0..<9_999_999).contains(fix.horizontalAccuracy) &&
            (-5...maximumAge).contains(now.timeIntervalSince(fix.timestamp))
    }

    static func detail(_ fix: PhoneLocationFix, now: Date = Date()) -> String {
        let time = ISO8601DateFormatter().string(from: fix.timestamp)
        return "<remarks>Last-known GPS fix: \(time); accuracy \(fix.horizontalAccuracy) m at measurement</remarks>"
    }

    /// Companion may have the good PLI fix even when watch GPS is unavailable.
    static func fillingMissingAlertLocation(_ xml: String, ownUID: String, fix: PhoneLocationFix?,
                                           now: Date = Date()) -> String {
        guard let fix, isUsable(fix, now: fix.timestamp), fix.timestamp <= now.addingTimeInterval(5) else { return xml }
        let delegate = AlertLocationRewriter(fix: fix, now: now)
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.isAlert, delegate.needsLocation,
              delegate.parentUID == ownUID || delegate.uid?.hasPrefix(ownUID + "-alert-") == true else { return xml }
        if delegate.hasPosition, let measuredAt = delegate.measuredAt, measuredAt >= fix.timestamp { return xml }
        return delegate.output
    }

    static func refreshingAlert(_ xml: String, ownUID: String, fix: PhoneLocationFix,
                                now: Date = Date()) -> String? {
        guard isUsable(fix, now: now) else { return nil }
        let delegate = AlertLocationRewriter(fix: fix, now: now, refresh: true)
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.isAlert,
              delegate.parentUID == ownUID || delegate.uid?.hasPrefix(ownUID + "-alert-") == true else { return nil }
        return delegate.output
    }
}

struct SelfLocationRefreshPolicy {
    static let requestInterval: TimeInterval = 5
    static let acquisitionWindow: TimeInterval = 5
    private(set) var requestedAt: Date?

    mutating func request(at now: Date = Date()) -> Bool {
        guard requestedAt.map({ now.timeIntervalSince($0) >= Self.requestInterval }) ?? true else { return false }
        requestedAt = now
        return true
    }
}

private final class AlertLocationRewriter: NSObject, XMLParserDelegate {
    let fix: PhoneLocationFix
    var output = ""
    var uid: String?
    var parentUID: String?
    var isAlert = false
    var needsLocation = false
    var hasPosition = false
    var measuredAt: Date?
    private var hasPoint = false
    private var remarks: String?
    private var depth = 0
    private let now: Date
    private let refresh: Bool

    init(fix: PhoneLocationFix, now: Date = Date(), refresh: Bool = false) {
        self.fix = fix
        self.now = now
        self.refresh = refresh
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        var values = attributes
        if depth == 1, name == "event" {
            uid = values["uid"]
            let type = values["type"] ?? ""
            isAlert = (type == "b-a-o" || type.hasPrefix("b-a-o-")) && !type.hasPrefix("b-a-o-can")
            if refresh {
                values["time"] = ISO8601DateFormatter().string(from: now)
                values["start"] = ISO8601DateFormatter().string(from: now)
                values["stale"] = ISO8601DateFormatter().string(from: now.addingTimeInterval(86_400))
            }
        }

        if depth == 3, name == "link", values["relation"] == "p-p" { parentUID = values["uid"] }
        if depth == 2, name == "point" {
            hasPoint = true
            let lat = values["lat"].flatMap(Double.init), lon = values["lon"].flatMap(Double.init)
            let ce = values["ce"].flatMap(Double.init)
            hasPosition = (lat.map { $0.isFinite && (-90...90).contains($0) } ?? false) &&
                (lon.map { $0.isFinite && (-180...180).contains($0) } ?? false) && !(lat == 0 && lon == 0)
            needsLocation = !hasPosition || !(ce.map { $0.isFinite && (0..<9_999_999).contains($0) } ?? false)
            if needsLocation || refresh {
                values["lat"] = String(fix.latitude)
                values["lon"] = String(fix.longitude)
                values["ce"] = String(AlertLocationHistory.circularError(fix, now: now))
                values["hae"] = "9999999"
                values["le"] = "9999999"
            }
        }
        if depth == 2, name == "detail", !hasPoint {
            needsLocation = true
            output += "<point lat=\"\(fix.latitude)\" lon=\"\(fix.longitude)\" ce=\"\(AlertLocationHistory.circularError(fix, now: now))\" hae=\"9999999\" le=\"9999999\"/>"
        }
        if depth == 3, name == "remarks" { remarks = "" }
        output += "<" + name
        for key in values.keys.sorted() { output += " \(key)=\"\(PhonePLI.escape(values[key]!))\"" }
        output += ">"
        if depth == 2, name == "detail" { output += AlertLocationHistory.detail(fix) }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        output += PhonePLI.escape(string)
        if remarks != nil { remarks? += string }
    }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        output += PhonePLI.escape(String(decoding: data, as: UTF8.self))
        if remarks != nil { remarks? += String(decoding: data, as: UTF8.self) }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if depth == 3, name == "remarks", let text = remarks {
            let prefix = "Last-known GPS fix: "
            if text.hasPrefix(prefix), let timestamp = text.dropFirst(prefix.count).split(separator: ";").first,
               let date = ISO8601DateFormatter().date(from: String(timestamp)) {
                measuredAt = max(measuredAt ?? .distantPast, date)
            }
            remarks = nil
        }
        output += "</\(name)>"
        depth -= 1
    }
}

struct CoTRelayReceiptLedger: Codable {
    static let maximumRecords = 512
    static let retention: TimeInterval = 86_400
    struct Receipt: Codable {
        let id: UUID
        let createdAt: Date
        var outputs: Set<UUID>
    }
    private(set) var receipts: [Receipt] = []

    func outputs(for id: UUID, now: Date = Date()) -> Set<UUID> {
        receipts.first { $0.id == id && now.timeIntervalSince($0.createdAt) <= Self.retention }?.outputs ?? []
    }

    mutating func accept(_ id: UUID, output: UUID, now: Date = Date()) {
        receipts.removeAll { now.timeIntervalSince($0.createdAt) > Self.retention }
        if let index = receipts.firstIndex(where: { $0.id == id }) {
            receipts[index].outputs.insert(output)
        } else {
            receipts.append(Receipt(id: id, createdAt: now, outputs: [output]))
        }
        if receipts.count > Self.maximumRecords { receipts.removeFirst(receipts.count - Self.maximumRecords) }
    }
}
