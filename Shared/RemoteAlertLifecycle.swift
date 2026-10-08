import Foundation

enum EmergencyState: String, Codable {
    case alert = "ALERT"
    case cancel = "CANCEL"
}

enum RemoteAlertSource: Hashable, Codable {
    case server(UUID), sitx, multicast, relay
}

struct RemoteAlertLocation: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    let observedAt: Date
    let staleAt: Date?

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite &&
            (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

struct RemoteAlertUpdate {
    let uid: String
    let state: EmergencyState
    let sentAt: Date
    let staleAt: Date?
    let type: String
    let senderUID: String?
    let callSign: String?
    let category: String?
    let location: RemoteAlertLocation?
}

/// One emergency per CoT UID, with independently removable transport ownership.
/// Ordering and dismissal survive source cleanup and have no time-based expiry.
struct RemoteAlertLifecycle: Codable {
    struct Copy: Codable {
        let source: RemoteAlertSource
        var generation: Int
        let sentAt: Date
        let staleAt: Date?
        let type: String
        let senderUID: String?
        let callSign: String?
        let category: String?
        let location: RemoteAlertLocation?

        func isStale(at now: Date) -> Bool {
            (staleAt ?? sentAt.addingTimeInterval(300)) <= now ||
                location.map { ($0.staleAt ?? $0.observedAt.addingTimeInterval(300)) <= now } == true
        }

        var isLastKnown: Bool { location.map { $0.observedAt < sentAt } ?? false }
    }

    private struct Record: Codable {
        var latest: Date
        var cancelledAt: Date?
        var dismissed = false
        var copies: [Copy] = []
    }

    struct Alert {
        let uid: String
        let copy: Copy
    }

    enum Outcome: String {
        case accepted, cancelled, dismissed, ownAlert, outOfOrder, invalid
    }

    private var records: [String: Record] = [:]

    var visibleAlerts: [Alert] {
        records.compactMap { uid, record in
            guard !record.dismissed, let copy = record.copies.sorted(by: {
                if $0.sentAt != $1.sentAt { return $0.sentAt > $1.sentAt }
                if ($0.location != nil) != ($1.location != nil) { return $0.location != nil }
                return String(describing: $0.source) < String(describing: $1.source)
            }).first else { return nil }
            return Alert(uid: uid, copy: copy)
        }.sorted {
            if $0.copy.sentAt != $1.copy.sentAt { return $0.copy.sentAt > $1.copy.sentAt }
            return $0.uid < $1.uid
        }
    }

    mutating func receive(_ update: RemoteAlertUpdate, source: RemoteAlertSource,
                          generation: Int = 0, ownUID: String) -> Outcome {
        guard !update.uid.isEmpty, generation >= 0, update.sentAt.timeIntervalSince1970.isFinite,
              update.location?.isValid != false else { return .invalid }
        if update.uid == ownUID || update.senderUID == ownUID ||
            update.uid == ownUID + "-9-1-1" || update.uid.hasPrefix(ownUID + "-alert-") {
            return .ownAlert
        }
        var record = records[update.uid] ?? Record(latest: update.sentAt)
        guard update.sentAt >= record.latest else { return .outOfOrder }
        if update.state == .cancel {
            record.latest = update.sentAt
            record.cancelledAt = update.sentAt
            record.dismissed = false
            record.copies = []
            records[update.uid] = record
            return .cancelled
        }
        guard record.cancelledAt.map({ update.sentAt > $0 }) ?? true else { return .outOfOrder }
        let previous = record.copies.first { $0.source == source }
        let metadata = previous ?? record.copies.max { $0.sentAt < $1.sentAt }
        let senderUID = update.senderUID.flatMap { $0.isEmpty ? nil : $0 } ?? metadata?.senderUID
        let callSign = update.callSign.flatMap { $0.isEmpty ? nil : $0 } ?? metadata?.callSign
        let category = update.category.flatMap { $0.isEmpty ? nil : $0 } ?? metadata?.category
        let copy = Copy(source: source, generation: generation, sentAt: update.sentAt,
                        staleAt: update.staleAt, type: update.type,
                        senderUID: senderUID, callSign: callSign, category: category,
                        location: update.location ?? previous?.location)
        record.latest = update.sentAt
        record.copies.removeAll { $0.source == source }
        record.copies.append(copy)
        records[update.uid] = record
        return record.dismissed ? .dismissed : .accepted
    }

    mutating func dismiss(uid: String) {
        guard var record = records[uid], !record.copies.isEmpty else { return }
        record.dismissed = true
        records[uid] = record
    }

    mutating func remove(source: RemoteAlertSource, beforeGeneration: Int? = nil) {
        for uid in Array(records.keys) {
            records[uid]?.copies.removeAll { copy in
                copy.source == source && (beforeGeneration.map { copy.generation < $0 } ?? true)
            }
        }
    }

    mutating func retainServers(_ enabled: Set<UUID>) {
        for uid in Array(records.keys) {
            records[uid]?.copies.removeAll {
                if case .server(let id) = $0.source { return !enabled.contains(id) }
                return false
            }
        }
    }

    mutating func resetServerGenerations() {
        for uid in Array(records.keys) {
            guard var record = records[uid] else { continue }
            for index in record.copies.indices {
                if case .server = record.copies[index].source { record.copies[index].generation = 0 }
            }
            records[uid] = record
        }
    }

    mutating func importCancellations(_ times: [String: Date]) {
        for (uid, time) in times where records[uid] == nil {
            records[uid] = Record(latest: time, cancelledAt: time)
        }
    }
}
