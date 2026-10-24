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
        precondition(parse(type: "b-a-o-pan").first?.emergencyState == .alert)
        precondition(parse(type: "b-a-o-opn").first?.emergencyState == .alert)
        precondition(parse(type: "b-a-g").first?.emergencyState == .alert)
        precondition(parse(type: "b-a-g", point: "").first?.hasUsableLocation == false)
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
        for category in ["911 Alert", "Ring The Bell", "Geofence Breached", "In Contact"] {
            let detail = "<link uid=\"alpha\" relation=\"p-p\"/><emergency type=\"\(category)\">ALPHA</emergency>"
            let received = parse(detail: detail)
            precondition(received.first?.emergencyState == .alert && received.first?.alertCategory == category)
            let cancelled = parse(type: "b-a-o-can", detail: detail)
            precondition(cancelled.first?.emergencyState == .cancel && cancelled.first?.alertCategory == category)
            let restored = try JSONDecoder().decode(EntityRelayPayload.self,
                from: JSONEncoder().encode(received[0]))
            precondition(restored.alertCategory == category)
        }
        precondition(parse(detail: "<link uid=\"alpha\" relation=\"p-c\" parent_callsign=\"ALPHA\"/><remarks>Pressure Alert</remarks>").first?.alertCategory == "Pressure Alert")
        precondition(parse(point: "").first?.hasUsableLocation == false)
        precondition(parse(point: "<point lat=\"9999999\" lon=\"9999999\"/>").first?.hasUsableLocation == false)
        precondition(parse(type: "b-a-o-can", point: "").first?.emergencyState == .cancel)
        precondition(parse(type: "a-f-G-U-C", point: "").isEmpty)
        precondition(parse(type: "a-f-G-U-C", lifetime: -1).isEmpty)
        precondition(parse(detail: "<link uid=\"parent\" relation=\"p-p\"><point lat=\"1\" lon=\"2\"/></link>").first?.lat == 38)
        precondition(parse(type: "b-t-f").isEmpty)
        precondition(parse(type: "b-m-p-s-p-i").first?.isUser == false)
        precondition(parse(type: "a-n-G").first?.emergencyState == nil)
        for type in ["a-n-A-C-F", "a-n-A-C-H", "a-f-Z", "b-m-p-s-m"] {
            let point = parse(type: type, detail: "<contact callsign=\"TRACK\"/>").first
            precondition(point?.type == type && point?.callSign == "TRACK" &&
                         point?.isUser == false && point?.hasChatEndpoint == false)
            precondition(parse(type: type, lifetime: -1).isEmpty)
        }
        let symbols: [(String, CoTMapSymbol)] = [
            ("A-C-F", .fixedWing), ("A-C-H", .rotaryWing), ("A-M-F-Q", .uav), ("A-M", .uav),
            ("S", .sea), ("G-U-C-I-I", .vehicle), ("G-U-S-M", .medical), ("G-A", .canine),
            ("G-E-W", .weapon)
        ]
        for affiliation in ["f", "u", "h", "n", "a", "s", "j", "k", "p", "o"] {
            for (function, expected) in symbols {
                let type = "a-\(affiliation)-\(function)"
                precondition(CoTMapSymbol(cotType: type) == expected)
                let point = parse(type: type, detail: "<contact callsign=\"SYMBOL\"/><takv device=\"ATOS\"/>").first
                precondition(point?.type == type && point?.isUser == false && point?.hasChatEndpoint == false)
                precondition(point?.staleAt == now.addingTimeInterval(300))
                precondition(parse(type: type, lifetime: -1).isEmpty)
            }
        }
        precondition(CoTMapSymbol(cotType: "b-m-p-s-p-i") == .spi)
        precondition(CoTMapSymbol(cotType: "a-f-A-C-F-extra") == .fixedWing)
        for type in ["a-f-G-U-C", "a-f-Z", "a-f-A-C-FF", "a-f-G-U-C-I", "b-m-p-s-m", "invalid"] {
            precondition(CoTMapSymbol(cotType: type) == nil, "Unsupported types must use existing fallback")
        }
        precondition(parse(type: "b-m-p-s-p-i", lifetime: -1).isEmpty)
        precondition(parse(type: "b-m-p-s-p-i", point: "").isEmpty)
        precondition(parse(type: "a-f-G-U-C-I-I", detail: "<contact endpoint=\"*:-1:stcp\"/>").first?.isUser == true)
        precondition(parse(type: "a-f-Z", detail: "<contact endpoint=\"*:-1:stcp\"/>").first?.hasChatEndpoint == true)
        let circle = parse(type: "u-d-c-c", detail: "<shape><ellipse major=\"100\" minor=\"100\" angle=\"0\"/></shape>").first
        precondition(circle?.circleRadius == 100)
        precondition(parse(type: "u-d-c-c", detail: "<shape><ellipse major=\"nan\" minor=\"nan\"/></shape>").first?.circleRadius == nil)
        precondition(parse(type: "u-d-c-c", detail: "<shape><ellipse major=\"100\" minor=\"50\"/></shape>").first?.circleRadius == nil)
        let deletion = parse(type: "t-x-d-d", detail: "<link uid=\"target\" relation=\"p-p\"/><__forcedelete/>", point: "").first
        precondition(deletion?.deletedUID == "target" && deletion?.hasUsableLocation == false)
        precondition(parse(type: "t-x-d-d", detail: "<link uid=\"self\"/>", point: "").isEmpty)
        precondition(parse(type: "t-x-d-d", point: "").isEmpty)
        precondition(parse(type: "t-x-d-d", detail: "<link uid=\"target\"/>", lifetime: -1, point: "").isEmpty)
        var deleted = CoTMapDeletionHistory()
        deleted.receive(uid: "target", at: now, now: now)
        precondition(!deleted.allows(uid: "target", at: now, now: now))
        precondition(!deleted.allows(uid: "target", at: now.addingTimeInterval(-1), now: now))
        precondition(deleted.allows(uid: "target", at: now.addingTimeInterval(1), now: now))
        precondition(deleted.allows(uid: "other", at: now, now: now))
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
        let restoredDelete = try JSONDecoder().decode(EntityRelayPayload.self, from: JSONEncoder().encode(deletion!))
        precondition(restoredDelete.deletedUID == "target")
        let restoredCircle = try JSONDecoder().decode(EntityRelayPayload.self, from: JSONEncoder().encode(circle!))
        precondition(restoredCircle.circleRadius == 100)
        print("PASS: ATAK/WearTAK alerts, parent links, own-alert suppression, stale/location-less emergencies and relay compatibility")
    }
}
