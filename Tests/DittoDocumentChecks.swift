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
            precondition(doc["_id"] as? String == "message-\(recipient)" && doc["d"] as? String == "remote")
            precondition(doc["_c"] == nil, "The legacy PN counter must be created by APPLY, never a numeric register")
            precondition(doc["msg"] as? String == "A&B <ready>" && doc["roomId"] as? String == recipient)
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
            var native = doc
            for key in ["eventUid", "r", "n", "o", "w", "g", "h", "i", "j", "k", "l", "p", "q"] {
                native.removeValue(forKey: key)
            }
            if recipient != "group-1" {
                let nativeDecoded = try DittoChatDocument.decode(native, ownUID: "other", now: now)
                precondition(TAKChatMessage.parse(nativeDecoded.xml, ownUID: "other")?.text == parsed.text)
                var twoCoordinates = native
                twoCoordinates["authorLoc"] = "38,-77"
                _ = try DittoChatDocument.decode(twoCoordinates, ownUID: "other", now: now)
                for (location, altitude, ce, le) in [
                    ("41.879815,-87.642469,156.933,HAE,19.4,9999999.0", 156.933, 19.4, 9_999_999.0),
                    (" 41.879815 , -87.642469 , NaN , HAE , NaN , NaN ", 9_999_999.0, 9_999_999.0, 9_999_999.0),
                    ("41.879815,-87.642469", 9_999_999.0, 9_999_999.0, 9_999_999.0),
                    ("41.879815,-87.642469,Infinity,HAE,-1,Infinity,extra", 9_999_999.0, 9_999_999.0, 9_999_999.0),
                    ("41.879815,-87.642469,156.933,AGL,19.4,20", 9_999_999.0, 19.4, 20.0)
                ] {
                    var official = native
                    official["authorLoc"] = location
                    let decoded = try DittoChatDocument.decode(official, ownUID: "other", now: now)
                    precondition(decoded.xml.contains("lat=\"41.879815\" lon=\"-87.642469\""))
                    precondition(decoded.xml.contains("hae=\"\(altitude)\" ce=\"\(ce)\" le=\"\(le)\""))
                    precondition(TAKChatMessage.parse(decoded.xml, ownUID: "other")?.text == parsed.text)
                    official["i"] = 123.0
                    official["h"] = 4.0
                    official["k"] = 5.0
                    let extended = try DittoChatDocument.decode(official, ownUID: "other", now: now)
                    precondition(extended.xml.contains("hae=\"123.0\" ce=\"4.0\" le=\"5.0\""))
                }
                for location in ["NaN,-87", "41,Infinity", "91,-87", "41,-181", "41", ",-87"] {
                    var invalid = native
                    invalid["authorLoc"] = location
                    do {
                        _ = try DittoChatDocument.decode(invalid, ownUID: "other", now: now)
                        preconditionFailure("Invalid native chat latitude/longitude accepted")
                    } catch DittoCoTDocument.Failure.invalid {}
                }
                var multiline = native
                multiline["msg"] = "First line\nSecond\tline"
                let multilineReceived = try DittoChatDocument.decode(multiline, ownUID: "other", now: now)
                precondition(TAKChatMessage.parse(multilineReceived.xml, ownUID: "other")?.text == "First line\nSecond\tline")
                multiline["msg"] = "Invalid\u{7f}control"
                do {
                    _ = try DittoChatDocument.decode(multiline, ownUID: "other", now: now)
                    preconditionFailure("Native chat control character accepted")
                } catch DittoCoTDocument.Failure.invalid {}
            } else {
                do {
                    _ = try DittoChatDocument.decode(native, ownUID: "other", now: now)
                    preconditionFailure("Unknown native group without roster was treated as broadcast")
                } catch DittoCoTDocument.Failure.invalid {}
                let known = try DittoChatDocument.decode(native, ownUID: "other",
                    verifiedMembers: ["remote", "other", "third"], now: now)
                precondition(TAKChatMessage.parse(known.xml, ownUID: "other")?.isGroup == true)
            }
            var conflict = doc
            conflict["msg"] = "Different message"
            do {
                _ = try DittoChatDocument.decode(conflict, ownUID: "other", now: now)
                preconditionFailure("Conflicting extension detail accepted")
            } catch DittoCoTDocument.Failure.invalid {}
            var wrongTitle = doc
            wrongTitle["room"] = "Different title"
            do {
                _ = try DittoChatDocument.decode(wrongTitle, ownUID: "other", now: now)
                preconditionFailure("Conflicting extension room title accepted")
            } catch DittoCoTDocument.Failure.invalid {}
            var repeatedDetail = doc
            repeatedDetail["r"] = (doc["r"] as! String).replacingOccurrences(
                of: "</detail>", with: "<remarks>A&amp;B &lt;ready&gt;</remarks></detail>")
            do {
                _ = try DittoChatDocument.decode(repeatedDetail, ownUID: "other", now: now)
                preconditionFailure("Duplicate chat remarks accepted")
            } catch DittoCoTDocument.Failure.invalid {}
            var wrongAuthor = doc
            wrongAuthor["AuthorId"] = "different-author"
            do {
                _ = try DittoChatDocument.decode(wrongAuthor, ownUID: "other", now: now)
                preconditionFailure("Chat sender/author mismatch accepted")
            } catch DittoCoTDocument.Failure.invalid {}
        }
        let wire = try BridgeWire.Message(kind: .dittoEvent, xml: xml).encoded()
        let decodedWire = try BridgeWire.Message.decode(wire)
        precondition(decodedWire.kind == .dittoEvent)
        print("PASS: WearOS/Tracker Ditto schemas, strict fields, collection/owner checks, peer replay/echo suppression, alert/cancel kinds, direct/group/broadcast chat and cross-transport UID dedup")
    }
}
