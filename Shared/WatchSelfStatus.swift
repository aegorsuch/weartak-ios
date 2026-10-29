import Foundation

/// Ephemeral SELF_STATUS v1. Never persist snapshots or put them in a delivery outbox.
struct WatchSelfStatus: Equatable {
    struct PPE: Equatable {
        let level: String
        let savedAt: String?
    }

    struct Physio: Equatable {
        var hr: Int?
        var measuredAt: String?
        var exert: Double? = nil
        var exertMeasuredAt: String? = nil
        var sktF: Double? = nil
        var sktFMeasuredAt: String? = nil
    }

    let version: Int
    let session: String
    let seq: Int64
    let deviceUid: String
    let model: String
    var ppe: PPE?
    var physio: Physio?

    static let supportedVersion = 1
    static let snapshotLifetime: TimeInterval = 300
    static let levels = ["None", "MOPP 0", "MOPP 1", "MOPP 2", "MOPP 3", "MOPP 4"]

    enum Failure: LocalizedError {
        case invalid, wrongSource, changedSession, replayed
        var errorDescription: String? {
            switch self {
            case .invalid: return "Invalid watch self-status snapshot."
            case .wrongSource: return "Watch self-status does not match the connected watch."
            case .changedSession: return "Watch self-status session changed without a new connection."
            case .replayed: return "Out-of-order watch self-status snapshot rejected."
            }
        }
    }

    func validated() throws -> Self {
        guard version == Self.supportedVersion, seq >= 0,
              (1...128).contains(session.utf16.count),
              !session.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !deviceUid.isEmpty, deviceUid.utf8.count <= 256,
              !deviceUid.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              ["WATCHOS", "GARMIN"].contains(model) else { throw Failure.invalid }
        if let ppe {
            guard Self.levels.contains(ppe.level),
                  ppe.savedAt.map({ Self.date($0) != nil }) ?? true else { throw Failure.invalid }
        }
        if let physio {
            func valid(_ present: Bool, _ validValue: Bool, _ timestamp: String?) -> Bool {
                present ? validValue && timestamp.flatMap(Self.date) != nil : timestamp == nil
            }
            guard valid(physio.hr != nil, physio.hr.map { (20...250).contains($0) } ?? false, physio.measuredAt),
                  valid(physio.exert != nil, physio.exert.map { $0.isFinite && (0...1).contains($0) } ?? false, physio.exertMeasuredAt),
                  valid(physio.sktF != nil, physio.sktF.map { $0.isFinite && (59...113).contains($0) } ?? false, physio.sktFMeasuredAt),
                  physio.hr != nil || physio.exert != nil || physio.sktF != nil else { throw Failure.invalid }
        }
        return self
    }

    func fresh(now: Date = Date()) -> Self {
        var value = self
        guard var physio else { return value }
        func current(_ timestamp: String?) -> Bool {
            guard let timestamp, let date = Self.date(timestamp) else { return false }
            return (-30...120).contains(now.timeIntervalSince(date))
        }
        if !current(physio.measuredAt) { physio.hr = nil; physio.measuredAt = nil }
        if !current(physio.exertMeasuredAt) { physio.exert = nil; physio.exertMeasuredAt = nil }
        if !current(physio.sktFMeasuredAt) { physio.sktF = nil; physio.sktFMeasuredAt = nil }
        value.physio = physio.hr != nil || physio.exert != nil || physio.sktF != nil ? physio : nil
        return value
    }

    var remarks: String {
        var parts: [String] = []
        if let ppe, ppe.level != "None" { parts.append(ppe.level.replacingOccurrences(of: " ", with: "")) }
        func time(_ timestamp: String?) -> String? {
            guard let timestamp, let measuredAt = Self.date(timestamp) else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "HH:mm:ss'Z'"
            return formatter.string(from: measuredAt)
        }
        if let physio {
            if let hr = physio.hr, let time = time(physio.measuredAt) {
                parts.append("HR: \(hr) bpm @ \(time)")
            }
            if let skin = physio.sktF, let time = time(physio.sktFMeasuredAt) {
                let value = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), skin)
                parts.append("Skin: \(value)F @ \(time)")
            }
            if let exert = physio.exert, let time = time(physio.exertMeasuredAt) {
                parts.append("Exert: \(Int((exert * 100).rounded()))% @ \(time)")
            }
        }
        return parts.joined(separator: "; ")
    }

    func appendingRemarks(to userRemarks: String) -> String {
        let managed = remarks
        guard !managed.isEmpty else { return userRemarks }
        return userRemarks.isEmpty ? managed : "\(userRemarks)\n\(managed)"
    }

    func biometrics(escapedUID: String) -> String {
        guard let physio,
              ["WATCHOS", "GARMIN"].contains(model) else { return "" }
        let sampleTime = physio.measuredAt.flatMap(Self.date).map { " sampleTime=\"\(Self.timestamp($0))\"" } ?? ""
        var detail = "<physiology version=\"1\"><device\(sampleTime)><model>\(model)</model><uid>\(escapedUID)</uid>"
        if let hr = physio.hr { detail += "<hr>\(hr)</hr>" }
        if let exert = physio.exert, let measuredAt = physio.exertMeasuredAt.flatMap(Self.date) {
            detail += "<exert sampleTime=\"\(Self.timestamp(measuredAt))\">\(exert)</exert>"
        }
        if let skin = physio.sktF, let measuredAt = physio.sktFMeasuredAt.flatMap(Self.date) {
            let celsius = (skin - 32) * 5 / 9
            detail += "<skt sampleTime=\"\(Self.timestamp(measuredAt))\">\(celsius)</skt>"
        }
        return detail + "</device></physiology>"
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(_ value: String) -> Date? {
        guard value.utf8.count <= 40,
              value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$"#,
                          options: .regularExpression) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

extension WatchSelfStatus.PPE: Codable {
    private enum CodingKeys: String, CodingKey { case level, savedAt }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.contains(.savedAt) else { throw WatchSelfStatus.Failure.invalid }
        level = try values.decode(String.self, forKey: .level)
        savedAt = try values.decodeIfPresent(String.self, forKey: .savedAt)
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(level, forKey: .level)
        try values.encode(savedAt, forKey: .savedAt)
    }
}

extension WatchSelfStatus.Physio: Codable {
    private enum CodingKeys: String, CodingKey { case hr, measuredAt, exert, exertMeasuredAt, sktF, sktFMeasuredAt }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hr = values.contains(.hr) ? try values.decode(Int.self, forKey: .hr) : nil
        measuredAt = values.contains(.measuredAt) ? try values.decode(String.self, forKey: .measuredAt) : nil
        exert = values.contains(.exert) ? try values.decode(Double.self, forKey: .exert) : nil
        exertMeasuredAt = values.contains(.exertMeasuredAt) ? try values.decode(String.self, forKey: .exertMeasuredAt) : nil
        sktF = values.contains(.sktF) ? try values.decode(Double.self, forKey: .sktF) : nil
        sktFMeasuredAt = values.contains(.sktFMeasuredAt) ? try values.decode(String.self, forKey: .sktFMeasuredAt) : nil
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(hr, forKey: .hr)
        try values.encodeIfPresent(measuredAt, forKey: .measuredAt)
        try values.encodeIfPresent(exert, forKey: .exert)
        try values.encodeIfPresent(exertMeasuredAt, forKey: .exertMeasuredAt)
        try values.encodeIfPresent(sktF, forKey: .sktF)
        try values.encodeIfPresent(sktFMeasuredAt, forKey: .sktFMeasuredAt)
    }
}

extension WatchSelfStatus: Codable {
    private enum CodingKeys: String, CodingKey { case version, session, seq, deviceUid, model, ppe, physio }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.contains(.ppe), values.contains(.physio) else { throw Failure.invalid }
        version = try values.decode(Int.self, forKey: .version)
        session = try values.decode(String.self, forKey: .session)
        seq = try values.decode(Int64.self, forKey: .seq)
        deviceUid = try values.decode(String.self, forKey: .deviceUid)
        model = try values.decode(String.self, forKey: .model)
        ppe = try values.decodeIfPresent(PPE.self, forKey: .ppe)
        physio = try values.decodeIfPresent(Physio.self, forKey: .physio)
        _ = try validated()
    }

    func encode(to encoder: Encoder) throws {
        _ = try validated()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(session, forKey: .session)
        try values.encode(seq, forKey: .seq)
        try values.encode(deviceUid, forKey: .deviceUid)
        try values.encode(model, forKey: .model)
        try values.encode(ppe, forKey: .ppe)
        try values.encode(physio, forKey: .physio)
    }
}

struct WatchSelfStatusReceiver {
    private var boundSession: String?
    private var lastSequence: Int64?
    private var snapshot: WatchSelfStatus?
    private var receivedAt: Date?

    mutating func disconnect() { self = Self() }

    mutating func receive(_ value: WatchSelfStatus, uid: String, model: String, now: Date = Date()) throws {
        _ = try value.validated()
        guard value.deviceUid == uid, value.model == model else { throw WatchSelfStatus.Failure.wrongSource }
        if let boundSession, value.session != boundSession { throw WatchSelfStatus.Failure.changedSession }
        if let lastSequence, value.seq <= lastSequence { throw WatchSelfStatus.Failure.replayed }
        boundSession = value.session
        lastSequence = value.seq
        snapshot = value
        receivedAt = now
    }

    func current(now: Date = Date()) -> WatchSelfStatus? {
        guard let snapshot, let receivedAt else { return nil }
        let age = now.timeIntervalSince(receivedAt)
        guard age >= 0, age < WatchSelfStatus.snapshotLifetime else { return nil }
        return snapshot.fresh(now: now)
    }
}
