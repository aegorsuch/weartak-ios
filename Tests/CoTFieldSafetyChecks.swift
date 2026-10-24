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
        let oldFallback = AlertLocationHistory.fillingMissingAlertLocation(xml, ownUID: "watch", fix: good,
            now: now.addingTimeInterval(101))
        precondition(oldFallback.contains("lat=\"38.0\"") && oldFallback.contains("ce=\"9999999.0\""))
        var olderPhone = good
        olderPhone.timestamp = good.timestamp.addingTimeInterval(-600)
        olderPhone.latitude = 20
        precondition(AlertLocationHistory.fillingMissingAlertLocation(oldFallback, ownUID: "watch", fix: olderPhone,
            now: now.addingTimeInterval(101)) == oldFallback, "Older phone history must not displace newer watch history")
        var newerPhone = good
        newerPhone.latitude = 39
        let replaced = AlertLocationHistory.fillingMissingAlertLocation(oldFallback, ownUID: "watch", fix: newerPhone,
            now: now.addingTimeInterval(101))
        precondition(replaced == oldFallback, "Equal measurement time must preserve the existing watch fix")
        newerPhone.timestamp = now
        precondition(AlertLocationHistory.fillingMissingAlertLocation(oldFallback, ownUID: "watch", fix: newerPhone,
            now: now.addingTimeInterval(101)).contains("lat=\"39.0\""))
        precondition(history.lastKnown(at: now.addingTimeInterval(86_400)) == good)
        let restoredFix = try JSONDecoder().decode(PhoneLocationFix.self, from: JSONEncoder().encode(good))
        precondition(restoredFix == good)
        var refreshed = good
        refreshed.latitude = 39
        refreshed.timestamp = now
        let update = AlertLocationHistory.refreshingAlert(filled, ownUID: "watch", fix: refreshed, now: now)!
        precondition(update.contains("lat=\"39.0\"") && update.contains("uid=\"watch-alert-911\""))
        precondition(update.contains("time=\"") && update.contains("stale=\""))
        precondition(AlertLocationHistory.refreshingAlert(filled, ownUID: "other", fix: refreshed, now: now) == nil)
        let manualXML = xml.replacingOccurrences(of: "<emergency", with: "<weartak manualAlert=\"true\"/><emergency")
        let manualFilled = AlertLocationHistory.fillingMissingAlertLocation(manualXML, ownUID: "watch", fix: good, now: now)
        precondition(manualFilled.contains("lat=\"38.0\"") && manualFilled.contains("manualAlert=\"true\""),
                     "A manual alert may receive its first good phone location before its one send")
        let geofence = manualXML.replacingOccurrences(of: "type=\"b-a-o\"", with: "type=\"b-a-g\"")
        precondition(AlertLocationHistory.fillingMissingAlertLocation(geofence, ownUID: "watch", fix: good, now: now)
            .contains("lat=\"38.0\""), "Phone relay must recognize geofence kind for first-fix filling")
        for seconds in [1.0, 5.0, 10.0, 60.0] {
            var nextFix = refreshed
            nextFix.timestamp = now.addingTimeInterval(seconds)
            precondition(AlertLocationHistory.refreshingAlert(manualFilled, ownUID: "watch",
                fix: nextFix, now: nextFix.timestamp) == nil,
                "New phone fixes must not generate duplicate manual alerts")
        }
        let nestedMarker = filled.replacingOccurrences(of: "<detail>", with: "<detail><container><weartak manualAlert=\"true\"/></container>")
        precondition(AlertLocationHistory.refreshingAlert(nestedMarker, ownUID: "watch", fix: refreshed, now: now) != nil,
                     "Only direct detail metadata may suppress automatic tracking")
        let cancelXML = xml.replacingOccurrences(of: "type=\"b-a-o\"", with: "type=\"b-a-o-can\"")
        precondition(AlertLocationHistory.refreshingAlert(cancelXML, ownUID: "watch", fix: refreshed, now: now) == nil)
        let noPoint = xml.replacingOccurrences(of: "<point lat=\"0\" lon=\"0\" ce=\"9999999\"/>", with: "")
        precondition(AlertLocationHistory.fillingMissingAlertLocation(noPoint, ownUID: "watch", fix: good, now: now)
            .contains("lat=\"38.0\""))
        var throttle = SelfLocationRefreshPolicy()
        precondition(throttle.request(at: now))
        for _ in 0..<18 { precondition(!throttle.request(at: now.addingTimeInterval(4.99))) }
        precondition(throttle.request(at: now.addingTimeInterval(5)))
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
        print("PASS: retained last-known fixes, honest CE, fresh emergency updates, cancellation safety, GPS throttling and relay receipts")
    }
}
