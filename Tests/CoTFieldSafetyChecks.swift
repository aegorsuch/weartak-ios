import Foundation

@main
struct CoTFieldSafetyChecks {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let good = PhoneLocationFix(latitude: 38, longitude: -77, horizontalAccuracy: 12,
            altitude: 30, verticalAccuracy: 5, speed: 0, course: 0, timestamp: now.addingTimeInterval(-20))
        var history = AlertLocationHistory()
        precondition(history.usable(at: now) == nil)
        history.receive(good, now: now)
        var invalid = good
        invalid.latitude = 0
        invalid.longitude = 0
        history.receive(invalid, now: now)
        invalid = good
        invalid.horizontalAccuracy = -1
        history.receive(invalid, now: now)
        invalid = good
        invalid.horizontalAccuracy = .infinity
        history.receive(invalid, now: now)
        invalid = good
        invalid.timestamp = now.addingTimeInterval(6)
        history.receive(invalid, now: now)
        invalid = good
        invalid.timestamp = now.addingTimeInterval(-121)
        history.receive(invalid, now: now)
        precondition(history.usable(at: now) == good)
        precondition(history.usable(at: now.addingTimeInterval(101)) == nil)
        let xml = """
        <event uid="watch-alert-911" type="b-a-o"><point lat="0" lon="0" ce="9999999"/><detail><contact callsign="A&amp;B"/><link uid="watch" relation="p-p"/><emergency type="911">A&amp;B</emergency></detail></event>
        """
        let filled = AlertLocationHistory.fillingMissingAlertLocation(xml, ownUID: "watch", fix: good, now: now)
        precondition(filled.contains("lat=\"38.0\"") && filled.contains("lon=\"-77.0\"") && filled.contains("ce=\"12.0\""))
        precondition(filled.contains("Last-known GPS fix:") && filled.contains("A&amp;B"))
        precondition(AlertLocationHistory.fillingMissingAlertLocation(xml, ownUID: "other", fix: good, now: now) == xml)
        precondition(AlertLocationHistory.fillingMissingAlertLocation(xml, ownUID: "watch", fix: nil, now: now) == xml)
        precondition(AlertLocationHistory.fillingMissingAlertLocation(xml, ownUID: "watch", fix: good,
            now: now.addingTimeInterval(101)) == xml)
        let valid = xml.replacingOccurrences(of: "lat=\"0\" lon=\"0\" ce=\"9999999\"", with: "lat=\"40\" lon=\"-70\" ce=\"8\"")
        precondition(AlertLocationHistory.fillingMissingAlertLocation(valid, ownUID: "watch", fix: good, now: now) == valid)
        precondition(AlertLocationHistory.fillingMissingAlertLocation(xml.replacingOccurrences(of: "b-a-o", with: "a-f-G"),
            ownUID: "watch", fix: good, now: now).contains("lat=\"0\""))

        var ledger = CoTRelayReceiptLedger()
        let request = UUID(), output = UUID(), other = UUID()
        for _ in 0..<18 {
            if !ledger.outputs(for: request, now: now).contains(output) {
                ledger.accept(request, output: output, now: now)
            }
        }
        precondition(ledger.receipts.count == 1 && ledger.outputs(for: request, now: now) == [output])
        let restored = try JSONDecoder().decode(CoTRelayReceiptLedger.self, from: JSONEncoder().encode(ledger))
        precondition(restored.outputs(for: request, now: now) == [output])
        precondition(!restored.outputs(for: request, now: now).contains(other))
        ledger.accept(request, output: other, now: now)
        precondition(ledger.outputs(for: request, now: now) == [output, other])
        let cancel = UUID()
        precondition(ledger.outputs(for: cancel, now: now).isEmpty)
        ledger.accept(cancel, output: output, now: now)
        precondition(ledger.outputs(for: request, now: now.addingTimeInterval(86_401)).isEmpty)
        for _ in 0..<600 { ledger.accept(UUID(), output: output, now: now) }
        precondition(ledger.receipts.count == CoTRelayReceiptLedger.maximumRecords)
        print("PASS: bounded last-valid alert fixes, honest measured accuracy, phone PLI fallback, relay retry receipts and bounds")
    }
}
