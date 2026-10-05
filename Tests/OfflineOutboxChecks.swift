import Foundation

@main
struct OfflineOutboxChecks {
    static func main() throws {
        let name = "WearTAK.outbox-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let queue = try OfflineOutbox(defaults: defaults)
        let marker = try queue.enqueue(key: "marker-1", payload: Data("create".utf8), now: now)
        let deleted = try queue.enqueue(key: "marker-1", payload: Data("delete".utf8), now: now)
        try queue.acknowledge(id: marker.id)
        precondition(queue.entries == [deleted], "Late acknowledgements must not erase replacements")
        let alert = try queue.enqueue(key: "alert-1", payload: Data("active".utf8), now: now)
        let cancel = try queue.enqueue(key: "alert-1", payload: Data("cancel".utf8), now: now)
        try queue.acknowledge(id: alert.id)
        precondition(queue.entries.last == cancel)
        let restored = try OfflineOutbox(defaults: defaults)
        precondition(restored.entries == queue.entries, "Restart preserves payloads, ordering, IDs and timestamps")
        try restored.replacePayload(id: deleted.id, payload: Data("resolved location".utf8))
        precondition(restored.entries[0].id == deleted.id && restored.entries[0].createdAt == now)
        let beforeExpiry = try restored.expire(now: now.addingTimeInterval(86_399))
        let atExpiry = try restored.expire(now: now.addingTimeInterval(86_400))
        precondition(beforeExpiry == 0 && atExpiry == 2)
        for index in 0..<OfflineOutbox.maximumEntries {
            try restored.enqueue(key: "chat-\(index)", payload: Data("stable-message-id-\(index)".utf8), now: now)
        }
        do {
            try restored.enqueue(key: "overflow", payload: Data(), now: now)
            preconditionFailure("Queue count limit not enforced")
        } catch OfflineOutbox.Failure.full {}
        precondition(restored.entries.count == 200)
        try restored.enqueue(key: "chat-0", payload: Data("newer".utf8), now: now)
        precondition(restored.entries.count == 200, "Replacement works at capacity")
        let beforeOversize = restored.entries
        do {
            try restored.enqueue(key: "chat-0", payload: Data(repeating: 1, count: OfflineOutbox.maximumBytes), now: now)
            preconditionFailure("Byte limit not enforced")
        } catch OfflineOutbox.Failure.full {}
        precondition(restored.entries == beforeOversize)
        precondition(restored.entries.last?.payload == Data("newer".utf8), "Failed writes preserve previous state")
        defaults.set(Data("corrupt".utf8), forKey: "corrupt")
        do {
            _ = try OfflineOutbox(defaults: defaults, storageKey: "corrupt")
            preconditionFailure("Corrupt storage silently accepted")
        } catch OfflineOutbox.Failure.unreadable {}
        precondition(defaults.data(forKey: "corrupt") == Data("corrupt".utf8))
        print("Offline outbox checks passed")
    }
}
