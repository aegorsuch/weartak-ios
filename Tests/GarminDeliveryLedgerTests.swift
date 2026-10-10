import Foundation

@main
struct GarminDeliveryLedgerTests {
    static func main() throws {
        let device = UUID()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fingerprint = Data("event".utf8)
        var ledger = GarminDeliveryLedger()
        let original = try ledger.reserve(deviceID: device, messageID: "event-1",
            fingerprint: fingerprint, now: now) { "<event original />" }
        let retry = try ledger.reserve(deviceID: device, messageID: "event-1",
            fingerprint: fingerprint, now: now) { fatalError("A retry must not regenerate CoT.") }
        precondition(retry.requestID == original.requestID && retry.xml == original.xml && !retry.accepted)
        try ledger.accept(original.requestID)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try ledger.save(to: url)
        var restored = try JSONDecoder().decode(GarminDeliveryLedger.self, from: Data(contentsOf: url))
        let accepted = try restored.reserve(deviceID: device, messageID: "event-1",
            fingerprint: fingerprint, now: now) { fatalError("Accepted retry must not resend.") }
        precondition(accepted.accepted && accepted.requestID == original.requestID)
        do {
            _ = try restored.reserve(deviceID: device, messageID: "event-1",
                fingerprint: Data("changed".utf8), now: now) { "<changed />" }
            fatalError("Changed payload must be rejected.")
        } catch GarminDeliveryLedger.Failure.changedPayload {}
        let otherDevice = try restored.reserve(deviceID: UUID(), messageID: "event-1",
            fingerprint: fingerprint, now: now) { "<other />" }
        precondition(otherDevice.requestID != original.requestID && !otherDevice.accepted)
        for i in 2..<GarminDeliveryLedger.maximumRecords {
            _ = try restored.reserve(deviceID: device, messageID: "event-\(i)",
                fingerprint: fingerprint, now: now) { "<new />" }
        }
        do {
            _ = try restored.reserve(deviceID: device, messageID: "overflow",
                fingerprint: fingerprint, now: now) { "<overflow />" }
            fatalError("Live records must never be evicted for overflow.")
        } catch GarminDeliveryLedger.Failure.full {}
        let boundary = try restored.reserve(deviceID: device, messageID: "event-1",
            fingerprint: fingerprint, now: now.addingTimeInterval(GarminDeliveryLedger.retention)) { "<unexpected />" }
        precondition(boundary.accepted)
        let expired = try restored.reserve(deviceID: device, messageID: "event-1",
            fingerprint: fingerprint, now: now.addingTimeInterval(GarminDeliveryLedger.retention + 1)) { "<new />" }
        precondition(!expired.accepted && expired.requestID != original.requestID && restored.records.count == 1)
        do {
            try restored.save(to: url.appendingPathComponent("missing").appendingPathComponent("ledger.json"))
            fatalError("Persistence errors must propagate.")
        } catch let error as CocoaError {
            precondition(error.code == .fileNoSuchFile)
        }
        print("PASS: stable retries, accepted restart, payload conflicts, device isolation, capacity, expiry, persistence errors")
    }
}
