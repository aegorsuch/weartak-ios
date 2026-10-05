import Foundation

@main
struct TAKChatChecks {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        precondition(TAKChatMessage.quickMessages == ["Roger", "Negative", "Objective Sighted", "In Position"])
        for text in TAKChatMessage.quickMessages {
            let quick = try TAKChatMessage.outgoing(senderUID: "watch", senderCallSign: "Watch",
                recipientUID: "atak", recipientCallSign: "ATAK", text: text, now: now)
            precondition(TAKChatMessage.parse(quick, ownUID: "atak")?.text == text)
        }
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
        let first = try TAKChatMessage.outgoing(senderUID: "watch", senderCallSign: "Watch", recipientUID: "atak",
            recipientCallSign: "ATAK", text: "Roger", now: now, messageID: "reply-1")
        let resend = try TAKChatMessage.outgoing(senderUID: "watch", senderCallSign: "Watch", recipientUID: "atak",
            recipientCallSign: "ATAK", text: "Roger", now: now.addingTimeInterval(600), messageID: "reply-1")
        precondition(first.contains("uid=\"GeoChat.watch.atak.reply-1\"") && resend.contains("uid=\"GeoChat.watch.atak.reply-1\""))
        precondition(TAKChatMessage.parse(resend, ownUID: "atak")?.id == TAKChatMessage.parse(first, ownUID: "atak")?.id)
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
        checkInbox(now: now)
        let atak = """
        <event version="2.0" uid="GeoChat.atak.watch.message-1" type="b-t-f" time="2027-01-15T08:00:00.123Z" start="2027-01-15T08:00:00Z" stale="2027-01-15T08:05:00Z" how="h-g-i-g-o"><point lat="0" lon="0" hae="9999999" ce="9999999" le="9999999"/><detail><__chat parent="RootContactGroup" groupOwner="false" messageId="message-1" chatroom="Watch" id="watch" senderCallsign="ATAK"><chatgrp uid0="atak" uid1="watch" id="watch"/></__chat><link uid="atak" type="a-f-G-U-C" relation="p-p"/><remarks source="BAO.F.ATAK.atak" to="watch" time="2027-01-15T08:00:00.123Z">Roger</remarks></detail></event>
        """
        precondition(TAKChatMessage.parse(atak, ownUID: "watch")?.text == "Roger")
        precondition(TAKChatMessage.parse(atak, ownUID: "watch")?.senderCallSign == "ATAK")
        try checkRelayBuffer(xml: atak, now: now)
        print("PASS: GeoChat routing, quick messages, ATAK-shaped XML, inbox unread/read, deduplication, source isolation, buffered handshake delivery and eviction checks")
    }

    static func checkRelayBuffer(xml: String, now: Date) throws {
        let server = UUID()
        let event = CompanionMapEvent(xml: xml, sourceServerID: server, sourceGeneration: 0, receivedAt: now)
        var buffer = CompanionChatBuffer()
        precondition(!buffer.receive(event, now: now))
        precondition(!buffer.receive(event, now: now) && buffer.events.count == 1)
        let reply = try buffer.filling(BridgeWire.Message(kind: .status, ready: true))
        let decoded = try BridgeWire.Message.decode(reply.encoded())
        precondition(decoded.chatEvents?.first?.sourceServerID == server)
        precondition(decoded.chatEvents?.first?.xml == xml)
        precondition(buffer.events.count == 1) // A lost handshake reply must remain retryable.
        let wrongKind = BridgeWire.Message(kind: .hello, chatEvents: reply.chatEvents)
        do {
            _ = try BridgeWire.Message.decode(wrongKind.encoded())
            fatalError("Chat events accepted outside status reply")
        } catch BridgeWire.Failure.invalidCoT {}
        buffer.prune(now: now, enabledServerIDs: [])
        precondition(buffer.events.isEmpty)
        _ = buffer.receive(event, now: now)
        buffer.prune(now: now.addingTimeInterval(301))
        precondition(buffer.events.isEmpty)
        for index in 0..<40 {
            let uniqueXML = xml.replacingOccurrences(of: "message-1", with: "message-\(index)")
            _ = buffer.receive(CompanionMapEvent(xml: uniqueXML, sourceServerID: server,
                sourceGeneration: 0, receivedAt: now), now: now)
        }
        precondition(buffer.events.count == 32)
        precondition(buffer.events.reduce(0, { $0 + $1.xml.utf8.count }) <= 40_000)
        let bounded = try buffer.filling(BridgeWire.Message(kind: .status))
        let boundedData = try bounded.encoded()
        precondition(boundedData.count <= BridgeWire.maximumMessageBytes)
        let boundedReply = try BridgeWire.Message.decode(boundedData)
        precondition(boundedReply.chatEvents?.count == 32)
        var byteLimited = CompanionChatBuffer()
        for index in 0..<30 {
            let largeXML = xml.replacingOccurrences(of: "message-1", with: "large-\(index)")
                .replacingOccurrences(of: ">Roger<", with: ">\(String(repeating: "&amp;", count: 2_000))<")
            _ = byteLimited.receive(CompanionMapEvent(xml: largeXML, sourceServerID: server,
                sourceGeneration: 0, receivedAt: now), now: now)
        }
        precondition(byteLimited.events.count < 32 && !byteLimited.events.isEmpty)
        precondition(byteLimited.events.reduce(0, { $0 + $1.xml.utf8.count }) <= 40_000)
        let byteLimitedReply = try byteLimited.filling(BridgeWire.Message(kind: .status))
        let byteLimitedData = try byteLimitedReply.encoded()
        precondition(byteLimitedData.count <= BridgeWire.maximumMessageBytes)
    }

    static func checkInbox(now: Date) {
        struct Conversation: Hashable {
            let uid: String
            let source: Int
        }
        let first = Conversation(uid: "atak", source: 1)
        let second = Conversation(uid: "atak", source: 2)
        var inbox = TAKChatInbox<Conversation>()
        func incoming(_ id: Int, sender: String = "atak") -> TAKChatMessage {
            TAKChatMessage(id: "\(id)", senderUID: sender, recipientUID: "watch",
                           senderCallSign: sender, text: "Roger", sentAt: now.addingTimeInterval(Double(id)))
        }
        precondition(inbox.record(incoming(1), conversation: first, ownUID: "watch"))
        precondition(inbox.unreadCount == 1 && inbox.conversations == [first])
        precondition(!inbox.record(incoming(1), conversation: first, ownUID: "watch"))
        precondition(inbox.unreadCount == 1)
        precondition(inbox.record(incoming(1), conversation: second, ownUID: "watch"))
        precondition(inbox.unreadCount == 2 && inbox.messages.count == 2)
        inbox.setVisible(first, visible: true)
        precondition(inbox.unreadCount == 1 && inbox.unreadCounts[first] == nil)
        precondition(!inbox.record(incoming(2), conversation: first, ownUID: "watch"))
        // A disappearing older screen must not clear the currently visible conversation.
        inbox.setVisible(second, visible: false)
        precondition(!inbox.record(incoming(3), conversation: first, ownUID: "watch"))
        inbox.setVisible(first, visible: false)
        precondition(inbox.record(incoming(4), conversation: first, ownUID: "watch"))
        let outgoing = TAKChatMessage(id: "out", senderUID: "watch", recipientUID: "atak",
                                      senderCallSign: "Watch", text: "Roger", sentAt: now)
        precondition(!inbox.record(outgoing, conversation: first, ownUID: "watch"))
        precondition(inbox.unreadCounts[first] == 1)
        for id in 5...60 { _ = inbox.record(incoming(id), conversation: first, ownUID: "watch") }
        precondition(inbox.messages[first]?.count == 50 && inbox.unreadCounts[first] == 50)
        precondition(inbox.messages[first]?.first?.id == "11" && inbox.conversations.first == first)
        for id in 61...110 {
            let conversation = Conversation(uid: "contact-\(id)", source: 1)
            _ = inbox.record(incoming(id, sender: conversation.uid), conversation: conversation, ownUID: "watch")
        }
        precondition(inbox.messages.count == 50 && inbox.messages[first] == nil && inbox.messages[second] == nil)
        precondition(inbox.unreadCounts[first] == nil && inbox.unreadCount == 50)
    }
}
