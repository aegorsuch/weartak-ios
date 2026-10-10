import Foundation

struct GarminDeliveryLedger: Codable {
    static let maximumRecords = 256
    static let retention: TimeInterval = 86_400 + 300

    struct Record: Codable {
        let deviceID: UUID
        let messageID: String
        let fingerprint: Data
        let requestID: UUID
        let xml: String
        let receivedAt: Date
        var accepted = false
    }

    private(set) var records: [Record] = []

    static func storageURL() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent("WearTAK-Garmin-delivery.json")
    }

    func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    mutating func reserve(deviceID: UUID, messageID: String, fingerprint: Data,
                          now: Date = Date(), makeXML: () throws -> String) throws -> Record {
        records.removeAll { now.timeIntervalSince($0.receivedAt) > Self.retention }
        if let record = records.first(where: { $0.deviceID == deviceID && $0.messageID == messageID }) {
            guard record.fingerprint == fingerprint else { throw Failure.changedPayload }
            return record
        }
        guard !messageID.isEmpty, messageID.count <= 128, fingerprint.count <= 6_000,
              records.count < Self.maximumRecords else { throw Failure.full }
        let record = Record(deviceID: deviceID, messageID: messageID, fingerprint: fingerprint,
                            requestID: UUID(), xml: try makeXML(), receivedAt: now)
        records.append(record)
        return record
    }

    mutating func accept(_ requestID: UUID) throws {
        guard let index = records.firstIndex(where: { $0.requestID == requestID }) else { throw Failure.missing }
        records[index].accepted = true
    }

    enum Failure: LocalizedError {
        case changedPayload, full, missing
        var errorDescription: String? {
            switch self {
            case .changedPayload: return "A Garmin retry changed its payload. The original event was retained."
            case .full: return "The Garmin delivery ledger is full. Existing events were retained; retry later."
            case .missing: return "The Garmin delivery record is unavailable. Retry the event."
            }
        }
    }
}
