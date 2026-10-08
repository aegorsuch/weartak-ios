import Foundation

@main
struct TAKMulticastChecks {
    static func main() throws {
        let sa = TAKMulticastEndpoint(address: "239.2.3.1", port: 6969)
        precondition(
            TAKMulticast.receiveEndpoints(address: sa.address, port: sa.port) == [
                sa, TAKMulticast.chat, TAKMulticast.directCoT,
            ])
        precondition(
            TAKMulticast.receiveEndpoints(address: TAKMulticast.chat.address, port: TAKMulticast.chat.port) == [
                TAKMulticast.chat, TAKMulticast.directCoT,
            ])
        precondition(
            TAKMulticast.receiveEndpoints(address: "239.5.6.7", port: 7000).first
                == TAKMulticastEndpoint(address: "239.5.6.7", port: 7000))
        precondition(
            TAKMulticast.receiveEndpoints(address: TAKMulticast.directCoT.address, port: 6969) == [
                TAKMulticast.directCoT, TAKMulticast.chat,
            ])
        let pli = "<event type='a-f-G-U-C'><detail><contact callsign='WATCH' endpoint=\"*:-1:stcp\"/></detail></event>"
        let (prepared, destination) = TAKMulticast.outbound(pli, address: sa.address, port: sa.port)
        precondition(destination == sa && prepared.contains("224.10.10.1:17012:udp"))
        precondition(pli.contains("*:-1:stcp"))
        let chat = "<event type='b-t-f'><detail><__chat/></detail></event>"
        precondition(TAKMulticast.outbound(chat, address: "239.5.6.7", port: 7000).1 == TAKMulticast.chat)
        for type in ["b-a-o", "a-f-G"] {
            let xml = "<event type='\(type)'><detail><contact callsign='POINT'/></detail></event>"
            precondition(TAKMulticast.outbound(xml, address: sa.address, port: sa.port).0 == xml)
        }
        let sensor = pli.replacingOccurrences(of: "</detail>", with: "<emergency type='Pressure'/></detail>")
        precondition(TAKMulticast.outbound(sensor, address: sa.address, port: sa.port).0 == sensor)
        let decodedXML = try TAKDatagramDecoder.decode(Data(chat.utf8))
        precondition(decodedXML == chat)

        func varint(_ number: UInt64) -> [UInt8] {
            var value = number
            var bytes: [UInt8] = []
            repeat {
                var byte = UInt8(value & 127)
                value >>= 7
                if value != 0 { byte |= 128 }
                bytes.append(byte)
            } while value != 0
            return bytes
        }
        func field(_ number: Int, _ bytes: [UInt8]) -> [UInt8] {
            varint(UInt64(number << 3 | 2)) + varint(UInt64(bytes.count)) + bytes
        }
        func string(_ number: Int, _ text: String) -> [UInt8] { field(number, Array(text.utf8)) }
        func integer(_ number: Int, _ value: UInt64) -> [UInt8] {
            varint(UInt64(number << 3)) + varint(value)
        }
        func double(_ number: Int, _ value: Double) -> [UInt8] {
            varint(UInt64(number << 3 | 1)) + (0..<8).map { UInt8(truncatingIfNeeded: value.bitPattern >> ($0 * 8)) }
        }
        func event(_ detail: [UInt8], type: String = "a-f-G-E-V-C") -> [UInt8] {
            string(1, type) + string(5, "phone") + integer(6, 4_070_908_800_000) + integer(7, 4_070_908_800_000)
                + integer(8, 4_070_908_860_000) + string(9, "m-g") + field(15, detail) + string(100, "future field")
        }
        func datagram(_ event: [UInt8]) -> Data { Data([0xbf, 1, 0xbf] + field(2, event)) }
        let detail =
            field(2, string(1, "224.10.10.1:17012:udp") + string(2, "ATAK & K9"))
            + field(3, string(1, "Green") + string(2, "K9")) + field(5, integer(1, 75)) + field(6, string(2, "ATAK"))
        let xml = try TAKDatagramDecoder.decode(datagram(event(detail)))!
        precondition(xml.contains("lat=\"0.0\"") && xml.contains("lon=\"0.0\""))
        precondition(xml.contains("callsign=\"ATAK &amp; K9\"") && xml.contains("battery=\"75\""))
        let parsed = SitxCoT.parse(Data(xml.utf8), excluding: "self", now: Date(timeIntervalSince1970: 4_070_908_801))
        precondition(parsed.first?.callSign == "ATAK & K9" && parsed.first?.isUser == true)
        let positionedXML = try TAKDatagramDecoder.decode(
            datagram(
                event(
                    detail + field(7, double(1, 1.5) + double(2, 90))) + double(10, 38) + double(11, -77)))!
        precondition(positionedXML.contains("speed=\"1.5\"") && positionedXML.contains("course=\"90.0\""))
        let positioned = SitxCoT.parse(
            Data(positionedXML.utf8), excluding: "self",
            now: Date(timeIntervalSince1970: 4_070_908_801))
        precondition(positioned.first?.lat == 38 && positioned.first?.lon == -77)
        let alertXML = try TAKDatagramDecoder.decode(
            datagram(
                event(
                    string(1, "<link uid='sender' relation='p-p'/><emergency type='Injury'>ALPHA</emergency>"),
                    type: "b-a-o") + double(10, 38) + double(11, -77)))!
        let alert = SitxCoT.parse(
            Data(alertXML.utf8), excluding: "self",
            now: Date(timeIntervalSince1970: 4_070_908_900))
        precondition(alert.first?.emergencyState == .alert && alert.first?.senderUID == "sender")
        let opaque =
            string(1, "<contact callsign='Opaque'/><remarks>Hi &amp; bye</remarks>") + field(2, string(2, "Typed"))
        let opaqueXML = try TAKDatagramDecoder.decode(datagram(event(opaque)))!
        precondition(opaqueXML.contains("Opaque") && !opaqueXML.contains("Typed"))
        let chatXML = try TAKDatagramDecoder.decode(
            datagram(
                event(
                    string(
                        1,
                        "<__chat/><remarks>Binary chat</remarks>"), type: "b-t-f")))!
        precondition(TAKMulticast.outbound(chatXML, address: sa.address, port: sa.port).1 == TAKMulticast.chat)
        let control = try TAKDatagramDecoder.decode(Data([0xbf, 1, 0xbf] + field(1, integer(1, 1))))
        precondition(control == nil)
        for bad in [
            Data(), Data([0xbf, 2, 0xbf]), Data([0xbf, 1, 0xbf, 18, 20, 1]),
            datagram(event(string(1, "<!DOCTYPE detail>"))),
            datagram(event(string(1, "<contact>"))), Data([0xff]),
            Data([0xbf, 1, 0xbf, 0]), Data([0xbf, 1, 0xbf, 18, 1, 8]),
            Data("<event>".utf8), Data("<!DOCTYPE event><event/>".utf8),
            datagram(event(detail) + double(10, .nan)),
            datagram(event(detail) + integer(10, 38)),
            datagram(event(field(2, integer(2, 10)))),
            Data([0xbf, 1, 0xbf] + Array(repeating: 0xff, count: 11)),
        ] {
            do {
                _ = try TAKDatagramDecoder.decode(bad)
                preconditionFailure("Malformed packet accepted: \(bad.map { String(format: "%02x", $0) }.joined())")
            } catch TAKDatagramDecoder.Failure.invalid {}
        }
        print(
            "PASS: multicast subscriptions, GeoChat routing, UDP PLI identity, XML/v1 decoding, typed/opaque details and rejection"
        )
    }

}
