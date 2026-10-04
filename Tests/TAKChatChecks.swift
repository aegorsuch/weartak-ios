import Foundation

@main
struct TAKChatChecks {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let xml = try TAKChatMessage.outgoing(senderUID: "watch-uid", senderCallSign: "ODIN & Watch",
            recipientUID: "atak-uid", recipientCallSign: "K9 <Partner>", text: "Test <message> & reply", now: now)
        precondition(xml.contains("type=\"b-t-f\"") && xml.contains("destinations=\"atak-uid\""))
        let event = CompanionMapEvent(xml: xml, sourceServerID: UUID(), sourceGeneration: 0, receivedAt: now)
        precondition(!event.isValid)
        guard let incoming = TAKChatMessage.parse(xml, ownUID: "atak-uid"),
              let outgoing = TAKChatMessage.parse(xml, ownUID: "watch-uid") else {
            fatalError("Chat event did not round-trip")
        }
        precondition(incoming == outgoing && incoming.senderUID == "watch-uid" && incoming.recipientUID == "atak-uid")
        precondition(incoming.senderCallSign == "ODIN & Watch" && incoming.text == "Test <message> & reply" &&
                     incoming.sentAt == now)
        let cdata = xml.replacingOccurrences(of: "Test &lt;message&gt; &amp; reply",
                                             with: "<![CDATA[Test <message> & reply]]>")
        precondition(TAKChatMessage.parse(cdata, ownUID: "atak-uid")?.text == incoming.text)
        precondition(TAKChatMessage.parse(xml, ownUID: "unrelated-uid") == nil)
        precondition(TAKChatMessage.parse("<!DOCTYPE event><event/>", ownUID: "watch-uid") == nil)
        precondition(TAKChatMessage.parse(xml.replacingOccurrences(of: "type=\"b-t-f\"", with: "type=\"a-f-G-U-C\""),
                                         ownUID: "watch-uid") == nil)
        for text in ["", " \n", String(repeating: "a", count: 2_001), "\u{0001}"] {
            do {
                _ = try TAKChatMessage.outgoing(senderUID: "watch", senderCallSign: "Watch",
                    recipientUID: "atak", recipientCallSign: "ATAK", text: text)
                fatalError("Invalid message accepted")
            } catch TAKChatMessage.ChatError.invalidMessage {}
        }
        print("PASS: GeoChat recipient routing, XML escaping, sender identity, timestamp, unrelated recipient and invalid text checks")
    }
}
