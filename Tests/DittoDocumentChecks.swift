import Foundation

enum DittoDocumentChecks {
    static func run() throws {
        let now = Date()
        let f = ISO8601DateFormatter()
        let stamp = f.string(from: now), stale = f.string(from: now.addingTimeInterval(86_400))
        func event(_ type: String, _ detail: String, uid: String = "marker") -> String {
            "<event version=\"2.0\" uid=\"\(uid)\" type=\"\(type)\" time=\"\(stamp)\" start=\"\(stamp)\" stale=\"\(stale)\" how=\"h-g-i-g-o\"><point lat=\"38.1\" lon=\"-77.2\" hae=\"100\" ce=\"5\" le=\"9\"/><detail>\(detail)</detail></event>"
        }
        let detail = "<contact callsign=\"A&amp;B\"/><link uid=\"remote\" type=\"a-f-G-U-C\" relation=\"p-p\"/>"
        let xml = event("a-f-G", detail)
        let (collection, document) = try DittoCoTDocument.make(xml: xml, peer: "peer", author: "remote", callsign: "Remote")
        precondition(collection == "mapitem" && document["_id"] as? String == "marker")
        precondition(document["a"] as? String == "peer" && document["AuthorId"] as? String == "remote")
        precondition(document["c"] as? String == "A&B" && document["r"] as? String == "<detail>\(detail)</detail>")
        let decoded = try DittoCoTDocument.decode(document, collection: collection, now: now)
        let header = CoTMapHeader.parse(decoded.xml)!
        precondition(header.uid == "marker" && header.type == "a-f-G")
        var ingress = DittoIngress()
        precondition(!ingress.accept(decoded, ownUID: "remote", localPeer: "local"))
        precondition(!ingress.accept(decoded, ownUID: "other", localPeer: "peer"))
        precondition(ingress.accept(decoded, ownUID: "other", localPeer: "local"))
        precondition(!ingress.accept(decoded, ownUID: "other", localPeer: "local"), "Observer repeats must not re-notify")
        var newer = document
        newer["b"] = (document["b"] as! Double) + 1
        let updated = try DittoCoTDocument.decode(newer, collection: collection, now: now)
        precondition(ingress.accept(updated, ownUID: "other", localPeer: "local"))
        precondition(!ingress.accept(decoded, ownUID: "other", localPeer: "local"))

        for (key, bad) in [("_v", true as Any), ("j", true), ("j", Double.nan), ("l", 181),
                           ("_id", "wrong"), ("b", -1), ("b", 1.5), ("b", (now.timeIntervalSince1970 + 301) * 1_000),
                           ("_r", true), ("_r", 0), ("r", "<detail><event/></detail>"),
                           ("r", "<detail><detail/></detail>"), ("r", "<!DOCTYPE x><detail/>"),
                           ("r", "<detail><!ENTITY x 'evil'></detail>"), ("r", String(repeating: "x", count: 50_001))] {
            var invalid = document
            invalid[key] = bad
            do {
                _ = try DittoCoTDocument.decode(invalid, collection: collection, now: now)
                preconditionFailure("Invalid Ditto field accepted: \(key)")
            } catch DittoCoTDocument.Failure.invalid {}
        }
        do {
            _ = try DittoCoTDocument.decode(document, collection: "track", now: now)
            preconditionFailure("Marker accepted into track")
        } catch DittoCoTDocument.Failure.invalid {}
        do {
            _ = try DittoCoTDocument.make(xml: xml, peer: "local", author: "not-owner", callsign: "X")
            preconditionFailure("Foreign marker was republished")
        } catch DittoCoTDocument.Failure.invalid {}

        for type in ["b-a-o-tbl", "b-a-o-pan", "b-a-g", "b-a-o-opn", "b-a-o", "b-a-o-can"] {
            let emergency = type == "b-a-o-can" ? "<emergency cancel=\"true\">Remote</emergency>" :
                "<emergency type=\"Test\">Remote</emergency>"
            let (c, doc) = try DittoCoTDocument.make(xml: event(type, detail + emergency, uid: "remote-alert-Test"),
                                                   peer: "peer", author: "remote", callsign: "Remote")
            precondition(c == "alert" && doc["c"] == nil && doc["f"] == nil)
            let received = try DittoCoTDocument.decode(doc, collection: c, now: now)
            precondition(CoTMapHeader.parse(received.xml)?.isEmergency == true)
        }
        let pli = event("a-f-G-U-C", detail, uid: "remote")
        let (track, trackDoc) = try DittoCoTDocument.make(xml: pli, peer: "peer", author: "remote", callsign: "Remote")
        precondition(track == "track")
        _ = try DittoCoTDocument.decode(trackDoc, collection: track, now: now)

        for (recipient, group, members) in [("other", false, [String]()),
            (TAKChatMessage.allChatRoomsUID, true, []), ("group-1", true, ["other", "third"])] {
            let chat = try TAKChatMessage.outgoing(senderUID: "remote", senderCallSign: "Remote",
                recipientUID: recipient, recipientCallSign: group ? "Team" : "Other", text: "A&B <ready>",
                now: now, messageID: "message-\(recipient)", isGroup: group, participantUids: members)
            let (c, doc) = try DittoCoTDocument.make(xml: chat, peer: "peer", author: "remote", callsign: "Remote")
            precondition(c == "chat" && doc["w"] as? String == "b-t-f")
            precondition((doc["o"] as! Double) - (doc["b"] as! Double) == 86_400_000)
            let received = try DittoCoTDocument.decode(doc, collection: c, now: now)
            let parsed = TAKChatMessage.parse(received.xml, ownUID: "other")!
            precondition(parsed.text == "A&B <ready>" && parsed.isGroup == group)
            if recipient == "group-1" {
                precondition(parsed.participantUids.contains("third") && parsed.conversationUid == "group-1")
                precondition(TAKChatMessage.parse(received.xml, ownUID: "unrelated") == nil)
            } else if !group { precondition(TAKChatMessage.parse(received.xml, ownUID: "unrelated") == nil) }
            var inbox = TAKChatInbox<String>()
            precondition(inbox.record(parsed, conversation: "Ditto", ownUID: "other"))
            precondition(!inbox.record(parsed, conversation: "TAK", ownUID: "other"),
                         "Message UID must deduplicate across transports")
            precondition(inbox.messages["TAK"] == nil)
        }
        let wire = try BridgeWire.Message(kind: .dittoEvent, xml: xml).encoded()
        let decodedWire = try BridgeWire.Message.decode(wire)
        precondition(decodedWire.kind == .dittoEvent)
        print("PASS: WearOS/Tracker Ditto schemas, strict fields, collection/owner checks, peer replay/echo suppression, alert/cancel kinds, direct/group/broadcast chat and cross-transport UID dedup")
    }
}
