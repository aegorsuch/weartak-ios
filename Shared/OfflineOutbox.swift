import Foundation

/// Durable operation intents. Removing an acknowledged generation must not remove a newer replacement.
final class OfflineOutbox {
    struct Entry: Codable, Equatable, Identifiable {
        let id: UUID
        let key: String
        let createdAt: Date
        var payload: Data
    }

    enum Failure: LocalizedError {
        case full, unreadable
        var errorDescription: String? {
            switch self {
            case .full: return "Offline queue is full. Reconnect before adding more events."
            case .unreadable: return "Unable to read the offline queue. Stored events have not been overwritten."
            }
        }
    }

    static let retention: TimeInterval = 24 * 60 * 60
    static let maximumEntries = 200
    static let maximumBytes = 1_048_576
    private let defaults: UserDefaults
    private let storageKey: String
    private(set) var entries: [Entry] = []

    init(defaults: UserDefaults = .standard, storageKey: String = "WearTAK.offlineOutbox") throws {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey) {
            guard data.count <= Self.maximumBytes,
                  let restored = try? JSONDecoder().decode([Entry].self, from: data),
                  restored.count <= Self.maximumEntries,
                  Set(restored.map(\.id)).count == restored.count,
                  Set(restored.map(\.key)).count == restored.count,
                  restored.allSatisfy({ !$0.key.isEmpty }) else { throw Failure.unreadable }
            entries = restored
        }
    }

    @discardableResult
    func enqueue(key: String, payload: Data, now: Date = Date()) throws -> Entry {
        var next = entries.filter { $0.key != key }
        let entry = Entry(id: UUID(), key: key, createdAt: now, payload: payload)
        next.append(entry)
        try commit(next)
        return entry
    }

    func replacePayload(id: UUID, payload: Data) throws {
        var next = entries
        guard let index = next.firstIndex(where: { $0.id == id }) else { return }
        next[index].payload = payload
        try commit(next)
    }

    func acknowledge(id: UUID) throws {
        try commit(entries.filter { $0.id != id })
    }

    @discardableResult
    func expire(now: Date = Date()) throws -> Int {
        let next = entries.filter { now.timeIntervalSince($0.createdAt) < Self.retention && $0.createdAt <= now }
        let removed = entries.count - next.count
        if removed > 0 { try commit(next) }
        return removed
    }

    private func commit(_ next: [Entry]) throws {
        guard next.count <= Self.maximumEntries else { throw Failure.full }
        let data = try JSONEncoder().encode(next)
        guard data.count <= Self.maximumBytes else { throw Failure.full }
        defaults.set(data, forKey: storageKey)
        entries = next
    }
}
