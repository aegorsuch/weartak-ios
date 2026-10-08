import Foundation

@main
struct RemoteAlertLifecycleChecks {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let serverA = RemoteAlertSource.server(UUID())
        let serverB = RemoteAlertSource.server(UUID())
        var store = RemoteAlertLifecycle()
        func update(_ offset: TimeInterval, state: EmergencyState = .alert,
                    uid: String = "atak-9-1-1", located: Bool = true,
                    lifetime: TimeInterval = 10, lat: Double = 38) -> RemoteAlertUpdate {
            let sent = now.addingTimeInterval(offset)
            let stale = sent.addingTimeInterval(lifetime)
            return RemoteAlertUpdate(uid: uid, state: state, sentAt: sent, staleAt: stale,
                type: state == .cancel ? "b-a-o-can" : "b-a-o-tbl", senderUID: "atak",
                callSign: "ALPHA", category: "Injury",
                location: located ? RemoteAlertLocation(latitude: lat, longitude: -77,
                    observedAt: sent, staleAt: stale) : nil)
        }
        func receive(_ event: RemoteAlertUpdate, source: RemoteAlertSource = .multicast,
                     generation: Int = 0) -> RemoteAlertLifecycle.Outcome {
            store.receive(event, source: source, generation: generation, ownUID: "self")
        }
        func restored(_ value: RemoteAlertLifecycle) throws -> RemoteAlertLifecycle {
            try JSONDecoder().decode(RemoteAlertLifecycle.self, from: JSONEncoder().encode(value))
        }

        precondition(receive(update(0, uid: "self")) == .ownAlert)
        precondition(receive(update(0, uid: "self-9-1-1")) == .ownAlert)
        precondition(receive(update(0, uid: "self-alert-Injury")) == .ownAlert)
        let ownParent = RemoteAlertUpdate(uid: "different-event", state: .alert, sentAt: now,
            staleAt: now.addingTimeInterval(10), type: "b-a-o", senderUID: "self",
            callSign: nil, category: nil, location: nil)
        precondition(receive(ownParent) == .ownAlert)
        precondition(store.visibleAlerts.isEmpty)
        precondition(receive(update(0), source: serverA, generation: 2) == .accepted)
        precondition(receive(update(0), source: serverB) == .accepted)
        precondition(receive(update(0), source: .sitx) == .accepted)
        precondition(receive(update(0), source: .multicast) == .accepted)
        precondition(receive(update(0), source: .relay) == .accepted)
        precondition(store.visibleAlerts.count == 1, "Deduplicate all transports by alert UID")
        precondition(!store.visibleAlerts[0].copy.isStale(at: now.addingTimeInterval(9)))
        precondition(store.visibleAlerts[0].copy.isStale(at: now.addingTimeInterval(10)))
        store = try restored(store)
        precondition(store.visibleAlerts.count == 1, "Stale alerts survive restarts")
        precondition(store.visibleAlerts[0].copy.isStale(at: now.addingTimeInterval(1_000_000)))
        store.remove(source: serverA, beforeGeneration: 2)
        var generationStore = RemoteAlertLifecycle()
        precondition(generationStore.receive(update(0), source: serverA, generation: 2, ownUID: "self") == .accepted)
        generationStore.remove(source: serverA, beforeGeneration: 2)
        precondition(generationStore.visibleAlerts.count == 1)
        generationStore.resetServerGenerations()
        generationStore.remove(source: serverA, beforeGeneration: 1)
        precondition(generationStore.visibleAlerts.isEmpty)
        store.remove(source: serverA, beforeGeneration: 3)
        store.remove(source: .sitx)
        store.remove(source: .relay)
        store.remove(source: .multicast)
        precondition(store.visibleAlerts.count == 1 && store.visibleAlerts[0].copy.source == serverB)
        precondition(receive(update(20, lat: 39), source: serverB) == .accepted)
        precondition(!store.visibleAlerts[0].copy.isStale(at: now.addingTimeInterval(21)))
        precondition(receive(update(19, lat: 40), source: serverB) == .outOfOrder)
        precondition(store.visibleAlerts[0].copy.location?.latitude == 39)
        precondition(receive(update(31, located: false), source: serverB) == .accepted)
        precondition(store.visibleAlerts[0].copy.location?.latitude == 39)
        precondition(store.visibleAlerts[0].copy.isLastKnown)
        precondition(store.visibleAlerts[0].copy.isStale(at: now.addingTimeInterval(31)),
                     "A location-less update cannot make old coordinates live")
        let blankMetadata = RemoteAlertUpdate(uid: "atak-9-1-1", state: .alert,
            sentAt: now.addingTimeInterval(31), staleAt: now.addingTimeInterval(41),
            type: "b-a-o", senderUID: "", callSign: "", category: "", location: nil)
        precondition(receive(blankMetadata, source: serverB) == .accepted)
        precondition(store.visibleAlerts[0].copy.callSign == "ALPHA" &&
                     store.visibleAlerts[0].copy.senderUID == "atak" &&
                     store.visibleAlerts[0].copy.category == "Injury")
        precondition(receive(update(32, uid: "no-location", located: false)) == .accepted)
        precondition(store.visibleAlerts.first { $0.uid == "no-location" }?.copy.location == nil)
        precondition(receive(update(33, uid: "no-location", located: true)) == .accepted)
        precondition(store.visibleAlerts.first { $0.uid == "no-location" }?.copy.location != nil)
        precondition(receive(update(34, uid: "invalid", lat: 999)) == .invalid)
        precondition(receive(update(0, uid: "already-stale", lifetime: -1)) == .accepted)
        precondition(store.visibleAlerts.first { $0.uid == "already-stale" }?.copy.isStale(at: now) == true)

        store.dismiss(uid: "atak-9-1-1")
        store = try restored(store)
        precondition(receive(update(31), source: serverB) == .dismissed)
        precondition(receive(update(40), source: serverB) == .dismissed)
        precondition(receive(update(40), source: .multicast) == .dismissed)
        precondition(!store.visibleAlerts.contains { $0.uid == "atak-9-1-1" })
        precondition(receive(update(39, state: .cancel, located: false)) == .outOfOrder)
        precondition(receive(update(41), source: serverB) == .dismissed)
        store = try restored(store)
        precondition(receive(update(41, state: .cancel, located: false)) == .cancelled)
        precondition(receive(update(41)) == .outOfOrder, "Cancellation wins at equal time")
        store = try restored(store)
        precondition(receive(update(40)) == .outOfOrder)
        precondition(receive(update(42)) == .accepted, "Newer activation reuses the ATAK UID")
        precondition(receive(update(41, state: .cancel)) == .outOfOrder)
        precondition(store.visibleAlerts.contains { $0.uid == "atak-9-1-1" })
        precondition(store.visibleAlerts.contains { $0.uid == "no-location" }, "Other emergencies are unaffected")
        precondition(receive(update(43, state: .cancel)) == .cancelled)
        store.remove(source: .multicast)
        store = try restored(store)
        precondition(receive(update(42)) == .outOfOrder, "Source cleanup must preserve tombstones")
        precondition(receive(update(44), source: serverA) == .accepted)
        store.retainServers([])
        precondition(!store.visibleAlerts.contains { $0.uid == "atak-9-1-1" })

        var migrated = RemoteAlertLifecycle()
        migrated.importCancellations(["legacy": now])
        precondition(migrated.receive(update(0, uid: "legacy"), source: .sitx, ownUID: "self") == .outOfOrder)
        print("PASS: shared alert ownership, ordering, stale retention, location safety, persistence, dismissal and reused UID reactivation")
    }
}
