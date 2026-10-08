import Foundation

@main
struct BloodhoundAlertChecks {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = ISO8601DateFormatter()
        func parse(type: String = "b-a-o", detail: String = "", lifetime: TimeInterval = 300,
                   uid: String = "remote-alert", point: String = "<point lat=\"38\" lon=\"-77\"/>") -> [EntityRelayPayload] {
            let xml = """
            <event uid="\(uid)" type="\(type)" time="\(formatter.string(from: now))" stale="\(formatter.string(from: now.addingTimeInterval(lifetime)))">
            \(point)<detail>\(detail)</detail></event>
            """
            return SitxCoT.parse(Data(xml.utf8), excluding: "self", now: now)
        }

        let alert = parse(detail: "<contact callsign=\"ALPHA\"/><link uid=\"alpha\" relation=\"p-p\"/><emergency type=\"Injury\">ALPHA</emergency>")
        precondition(alert.count == 1 && alert[0].emergencyState == .alert && alert[0].isUser == false)
        precondition(alert[0].callSign == "ALPHA" && alert[0].senderUID == "alpha" && alert[0].alertCategory == "Injury")
        precondition(alert[0].lat == 38 && alert[0].lon == -77)
        precondition(alert[0].sentAt == now && alert[0].staleAt == now.addingTimeInterval(300))
        precondition(parse(type: "b-a-o-tbl").first?.emergencyState == .alert)
        precondition(parse(type: "b-a-o-can").first?.emergencyState == .cancel)
        precondition(parse(type: "b-a-o-can-custom").first?.emergencyState == .cancel)
        precondition(parse(detail: "<emergency cancel=\"true\"/>").first?.emergencyState == .cancel)
        precondition(parse(detail: "<emergency cancel=\"1\"/>").first?.emergencyState == .cancel)
        precondition(parse(type: "b-a-o-can", detail: "<emergency type=\"Injury\"/>").first?.emergencyState == .cancel)
        precondition(parse(lifetime: -1).first?.emergencyState == .alert)
        precondition(parse(type: "b-a-o-can", lifetime: -1).first?.emergencyState == .cancel)
        precondition(parse(uid: "self").isEmpty)
        precondition(parse(detail: "<link uid=\"self\" relation=\"p-p\"/>").isEmpty)
        precondition(parse(detail: "<link uid=\"self\" relation=\"p-c\"/>").isEmpty)
        precondition(parse(uid: "self-9-1-1").isEmpty)
        precondition(parse(uid: "self-alert-Injury").isEmpty)
        precondition(parse(detail: "<link uid=\"self\" relation=\"p-p\"/><link uid=\"other\" relation=\"p-p\"/>").isEmpty)
        let atak = parse(detail: "<emergency type=\"911 Alert\">ATAK ALPHA</emergency>", uid: "alpha-9-1-1")
        precondition(atak.first?.senderUID == "alpha" && atak.first?.callSign == "ATAK ALPHA")
        precondition(parse(detail: "<link uid=\"alpha\" relation=\"p-c\" parent_callsign=\"ALPHA\"/><remarks>Pressure Alert</remarks>").first?.alertCategory == "Pressure Alert")
        precondition(parse(point: "").first?.hasUsableLocation == false)
        precondition(parse(point: "<point lat=\"9999999\" lon=\"9999999\"/>").first?.hasUsableLocation == false)
        precondition(parse(type: "b-a-o-can", point: "").first?.emergencyState == .cancel)
        precondition(parse(type: "a-f-G-U-C", point: "").isEmpty)
        precondition(parse(type: "a-f-G-U-C", lifetime: -1).isEmpty)
        precondition(parse(detail: "<link uid=\"parent\" relation=\"p-p\"><point lat=\"1\" lon=\"2\"/></link>").first?.lat == 38)
        precondition(parse(type: "b-t-f").isEmpty)
        precondition(parse(type: "b-m-p-s-p-i").isEmpty)
        precondition(parse(type: "a-n-G").first?.emergencyState == nil)
        precondition(parse(type: "a-f-G-U-C").first?.isUser == true)
        precondition(parse(type: "a-f-G-U-C", detail: "<emergency type=\"911 Alert\"/>").first?.isUser == false)
        let manual = parse(detail: "<contact callsign=\"WATCH\"/><link uid=\"watch\" relation=\"p-p\"/><emergency type=\"Gunshot Injury\">WATCH</emergency>",
                           uid: "watch-alert-Gunshot Injury")
        precondition(manual.first?.senderUID == "watch" && manual.first?.alertCategory == "Gunshot Injury")
        let sensor = parse(type: "a-f-G-U-C", detail: "<link uid=\"watch\" relation=\"p-c\"/><emergency type=\"Pressure Alert\">WATCH</emergency>")
        precondition(sensor.first?.emergencyState == .alert && sensor.first?.alertCategory == "Pressure Alert")
        precondition(parse(detail: "<emergency cancel=\"TRUE\"/>").first?.emergencyState == .cancel)
        precondition(SitxCoT.parse(Data("<event uid=\"bad-time\" type=\"b-a-o\" time=\"broken\"><detail/></event>".utf8),
                                 excluding: "self", now: now).isEmpty)
        precondition(SitxCoT.parse(Data("<event>broken".utf8), excluding: "self", now: now).isEmpty)

        let restored = try JSONDecoder().decode(EntityRelayPayload.self, from: JSONEncoder().encode(alert[0]))
        precondition(restored.emergencyState == .alert && restored.alertCategory == "Injury" && restored.staleAt == alert[0].staleAt)
        let legacy = try JSONDecoder().decode(EntityRelayPayload.self,
            from: Data(#"{"uid":"legacy","lat":38,"lon":-77,"type":"a-n-G"}"#.utf8))
        precondition(legacy.emergencyState == nil && legacy.alertCategory == nil && legacy.staleAt == nil)
        let noLocation = parse(point: "")[0]
        let restoredNoLocation = try JSONDecoder().decode(EntityRelayPayload.self, from: JSONEncoder().encode(noLocation))
        precondition(restoredNoLocation.hasUsableLocation == false)
        print("PASS: ATAK/WearTAK alerts, parent links, own-alert suppression, stale/location-less emergencies and relay compatibility")
    }
}
