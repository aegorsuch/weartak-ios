import CoreLocation
import Foundation

enum EmergencyState: String, Codable { case alert = "ALERT", cancel = "CANCEL" }

@main
struct BloodhoundAlertChecks {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinate = CLLocationCoordinate2D(latitude: 38, longitude: -77)
        func parse(type: String = "b-a-o", detail: String = "", lifetime: TimeInterval = 300,
                   uid: String = "remote-alert") -> [EntityRelayPayload] {
            let xml = SitxCoT.event(uid: uid, type: type, coordinate: coordinate,
                                    detail: detail, lifetime: lifetime, now: now)
            return SitxCoT.parse(Data(xml.utf8), excluding: "self", now: now)
        }

        let alert = parse(detail: "<contact callsign=\"ALPHA\"/><link uid=\"alpha\" relation=\"p-p\"/><emergency type=\"Injury\">ALPHA</emergency>")
        precondition(alert.count == 1 && alert[0].emergencyState == .alert && alert[0].isUser == false)
        precondition(alert[0].callSign == "ALPHA" && alert[0].senderUID == "alpha" && alert[0].alertCategory == "Injury")
        precondition(alert[0].lat == 38 && alert[0].lon == -77)
        precondition(alert[0].sentAt == now && alert[0].staleAt == now.addingTimeInterval(300))
        precondition(parse(type: "b-a-o-tbl").first?.emergencyState == .alert)
        precondition(parse(type: "b-a-o-can").first?.emergencyState == .cancel)
        precondition(parse(detail: "<emergency cancel=\"true\"/>").first?.emergencyState == .cancel)
        precondition(parse(detail: "<emergency cancel=\"1\"/>").first?.emergencyState == .cancel)
        precondition(parse(type: "b-a-o-can", detail: "<emergency type=\"Injury\"/>").first?.emergencyState == .cancel)
        precondition(parse(lifetime: -1).isEmpty)
        precondition(parse(type: "b-a-o-can", lifetime: -1).first?.emergencyState == .cancel)
        precondition(parse(uid: "self").isEmpty)
        precondition(parse(detail: "<link uid=\"self\" relation=\"p-p\"/>").isEmpty)
        precondition(parse(type: "b-t-f").isEmpty)
        precondition(parse(type: "b-m-p-s-p-i").isEmpty)
        precondition(parse(type: "a-n-G").first?.emergencyState == nil)
        precondition(parse(type: "a-f-G-U-C").first?.isUser == true)
        precondition(parse(type: "a-f-G-U-C", detail: "<emergency type=\"911 Alert\"/>").first?.isUser == false)
        precondition(SitxCoT.parse(Data("<event>broken".utf8), excluding: "self", now: now).isEmpty)

        let restored = try JSONDecoder().decode(EntityRelayPayload.self, from: JSONEncoder().encode(alert[0]))
        precondition(restored.emergencyState == .alert && restored.alertCategory == "Injury" && restored.staleAt == alert[0].staleAt)
        let legacy = try JSONDecoder().decode(EntityRelayPayload.self,
            from: Data(#"{"uid":"legacy","lat":38,"lon":-77,"type":"a-n-G"}"#.utf8))
        precondition(legacy.emergencyState == nil && legacy.alertCategory == nil && legacy.staleAt == nil)
        print("PASS: remote alert parsing, cancellation, expiry, self exclusion, ordinary CoT and relay compatibility")
    }
}
