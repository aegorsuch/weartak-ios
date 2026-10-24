import Foundation

@main
struct GarminRelayProtocolTests {
    static func main() throws {
        try SavedChatMessageChecks.run()
        try DittoDocumentChecks.run()
        func envelope(_ type: String, _ payload: [String: Any]) throws -> GarminEnvelope {
            let data = try JSONSerialization.data(withJSONObject: GarminEnvelope(type, payload).object)
            return try GarminEnvelope(object: JSONSerialization.jsonObject(with: data))
        }
        let booleans = try envelope("test", ["yes": true, "no": false, "one": 1, "zero": 0])
        let yes = try booleans.boolean("yes")
        let no = try booleans.boolean("no")
        precondition(yes && !no)
        for key in ["one", "zero"] {
            do { _ = try booleans.boolean(key); fatalError("Numbers cannot substitute for booleans.") }
            catch GarminRelayProtocol.Failure.invalid {}
        }
        do { _ = try booleans.integer("yes", range: 0...1); fatalError("Booleans cannot substitute for numbers.") }
        catch GarminRelayProtocol.Failure.invalid {}
        let now = Date()
        let device = UUID()
        let identity = try GarminRelayProtocol.identity(envelope("watch_settings", [
            "callsign": "TEST", "team": "Cyan", "role": "Team Member", "reportIntSecs": 10
        ]), uid: device, now: now)
        let hello = try GarminRelayProtocol.request(envelope("relay_hello", ["protocolVersion": 1]),
            identity: nil, fix: nil, channelServers: [])
        precondition(hello.kind == .hello)
        for limit in [50, 999] {
            let snapshot = try GarminRelayProtocol.request(envelope("entity_sync_request", [
                "limit": limit, "protocolVersion": 1, "routeVersion": 1
            ]), identity: nil, fix: nil, channelServers: [])
            precondition(snapshot.kind == .mapSnapshot)
        }
        for limit in [0, 1000] {
            do {
                _ = try GarminRelayProtocol.request(envelope("entity_sync_request", ["limit": limit]),
                    identity: nil, fix: nil, channelServers: [])
                fatalError("Invalid snapshot limit accepted")
            } catch GarminRelayProtocol.Failure.invalid {}
        }
        let events = [
            try envelope("marker", ["messageId": "marker-1", "uid": "garmin-marker-1", "type": "a-f-G-T",
                                    "lat": 38.0, "lon": -77.0, "title": "A & B"]),
            try envelope("marker_delete", ["messageId": "delete-1", "uid": "garmin-marker-1"]),
            try envelope("emergency", ["messageId": "cancel-1", "uid": "garmin-sos", "state": "CANCEL"]),
            try envelope("chat", ["messageId": "chat-1", "replyTo": "recipient", "text": "Rgr"])
        ]
        var ledger = GarminDeliveryLedger()
        for event in events {
            let fingerprint = try JSONSerialization.data(withJSONObject: event.object, options: .sortedKeys)
            let original = try ledger.reserve(deviceID: device, messageID: event.string("messageId"),
                fingerprint: fingerprint, now: now) {
                try GarminRelayProtocol.outgoingCoT(event, identity: identity, fix: nil, now: now)
            }
            precondition(CoTStreamFramer.isEvent(Data(original.xml.utf8)))
            try ledger.accept(original.requestID)
            let retry = try ledger.reserve(deviceID: device, messageID: event.string("messageId"),
                fingerprint: fingerprint, now: now.addingTimeInterval(30)) {
                fatalError("Accepted event must not regenerate its CoT on retry.")
            }
            precondition(retry.accepted && retry.requestID == original.requestID && retry.xml == original.xml)
        }
        let invalidMarker = try envelope("marker", ["messageId": "invalid", "uid": "garmin-marker-invalid",
            "type": "a-f-G-T", "lat": true, "lon": -77.0])
        do {
            _ = try GarminRelayProtocol.outgoingCoT(invalidMarker, identity: identity, fix: nil, now: now)
            fatalError("Boolean coordinates must be rejected.")
        } catch GarminRelayProtocol.Failure.invalid {}
        let fix = PhoneLocationFix(latitude: 38, longitude: -77, horizontalAccuracy: 9, altitude: 0,
            verticalAccuracy: -1, speed: 0, course: 0, timestamp: now)
        let emergency = try envelope("emergency", ["messageId": "alert-1", "uid": "garmin-sos", "state": "ALERT"])
        do {
            _ = try GarminRelayProtocol.outgoingCoT(emergency, identity: identity, fix: nil, now: now)
            fatalError("No-fix emergency must not invent coordinates.")
        } catch GarminRelayProtocol.Failure.noLocation {}
        let alertXML = try GarminRelayProtocol.outgoingCoT(emergency, identity: identity, fix: fix, now: now)
        precondition(alertXML.contains("lat=\"38.0\"") && alertXML.contains("ce=\"9.0\""))
        let oldAlert = try GarminRelayProtocol.outgoingCoT(emergency, identity: identity, fix: fix,
                                                         now: now.addingTimeInterval(600))
        precondition(oldAlert.contains("lat=\"38.0\"") && oldAlert.contains("ce=\"9999999.0\""))
        precondition(oldAlert.contains("Last-known GPS fix:"))
        let phoneMarker = try envelope("marker", ["messageId": "self-marker", "uid": "garmin-marker-self",
            "type": "a-f-G-T", "locationSource": "phone", "lat": 50.0, "lon": 20.0])
        let markerXML = try GarminRelayProtocol.outgoingCoT(phoneMarker, identity: identity, fix: fix, now: now)
        precondition(markerXML.contains("lat=\"38.0\"") && !markerXML.contains("lat=\"50.0\""))
        for action in ["map", "navigation", "identity", "self_marker", "pli"] {
            let request = try GarminRelayProtocol.request(envelope("location_request", [
                "action": action, "requestId": UUID().uuidString, "messageId": UUID().uuidString,
                "relaySession": "current", "createdAt": now.timeIntervalSince1970 * 1000
            ]), identity: identity, fix: nil, channelServers: [])
            precondition(request.kind == .hello && request.locationRefresh == true)
        }
        do {
            _ = try GarminRelayProtocol.request(envelope("location_request", ["action": "invalid", "requestId": "x"]),
                identity: identity, fix: nil, channelServers: [])
            fatalError("Unknown GPS action accepted.")
        } catch GarminRelayProtocol.Failure.invalid {}
        for type in ["a-n-A-C-F", "a-n-A-C-H", "a-f-A-M-F-Q", "a-f-S", "a-f-G-U-C-I-I",
                     "a-f-Z", "b-m-p-s-m", "b-m-p-s-p-i", "u-d-c-c"] {
            let xml = "<event uid=\"generic\" type=\"\(type)\" time=\"2026-10-23T00:00:00Z\" stale=\"2026-10-23T00:05:00Z\"><point lat=\"38\" lon=\"-77\" ce=\"10\"/><detail><contact callsign=\"Generic\"/><takv device=\"ADS-B\"/><link uid=\"sender\" relation=\"p-p\"/><shape><ellipse major=\"500\" minor=\"500\"/></shape></detail></event>"
            let incoming = try GarminRelayProtocol.incoming(xml, ownUID: "watch")!
            precondition(incoming.payload["isUser"] as? Bool == false && incoming.payload["isPoint"] as? Bool == true)
            precondition(incoming.payload["radius"] as? Double == 500)
            precondition((incoming.payload["link"] as? [String: String])?["uid"] == "sender")
            precondition((incoming.payload["shape"] as? [String: [String: Double]])?["ellipse"]?["minor"] == 500)
            precondition(incoming.payload["stale"] as? String == "2026-10-23T00:05:00Z")
        }
        for type in ["b-i-v", "a-f-G"] {
            let xml = "<event uid=\"camera\" type=\"\(type)\"><point lat=\"38\" lon=\"-77\"/><detail><__video url=\"srt://private.invalid/secret\"><ConnectionEntry password=\"secret\"/></__video></detail></event>"
            let camera = try GarminRelayProtocol.incoming(xml, ownUID: "watch")!
            precondition((camera.payload["__video"] as? [String: String])?.isEmpty == true)
            precondition(camera.payload["type"] as? String == type)
            let encoded = try JSONSerialization.data(withJSONObject: camera.object)
            precondition(!String(decoding: encoded, as: UTF8.self).contains("secret"))
        }
        let exactCamera = try GarminRelayProtocol.incoming(
            "<event uid=\"camera\" type=\"b-i-v\"><point lat=\"38\" lon=\"-77\"/><detail/></event>", ownUID: "watch")
        precondition(exactCamera != nil)
        for detail in ["<contact callsign=\"CAMERA VIDEO\"/>", "<wrapper><__video/></wrapper>", "<sensor/>"] {
            let ordinary = try GarminRelayProtocol.incoming(
                "<event uid=\"ordinary\" type=\"a-f-G\"><point lat=\"38\" lon=\"-77\"/><detail>\(detail)</detail></event>",
                ownUID: "watch")!
            precondition(ordinary.payload["__video"] == nil)
        }
        let unsupportedSubtype = try GarminRelayProtocol.incoming(
            "<event uid=\"other\" type=\"b-i-v-extra\"><point lat=\"38\" lon=\"-77\"/></event>", ownUID: "watch")
        precondition(unsupportedSubtype == nil)
        let wrongVideoParent = try GarminRelayProtocol.incoming(
            "<event uid=\"other\" type=\"a-f-G\"><point lat=\"38\" lon=\"-77\"/><other><__video/></other></event>", ownUID: "watch")!
        precondition(wrongVideoParent.payload["__video"] == nil)
        let deletion = try GarminRelayProtocol.incoming(
            "<event uid=\"deletion\" type=\"t-x-d-d\"><detail><link uid=\"target\" relation=\"p-p\"/></detail></event>", ownUID: "watch")!
        precondition(deletion.payload["lat"] == nil && (deletion.payload["link"] as? [String: String])?["uid"] == "target")
        let unlinkedDelete = try GarminRelayProtocol.incoming("<event uid=\"target\" type=\"t-x-d-d\"><detail/></event>", ownUID: "watch")!
        precondition(unlinkedDelete.payload["uid"] as? String == "target")
        let metrics = UserMetrics(birthYear: 1990, source: "Test", measuredAt: now)
        let restoredMetrics = try JSONDecoder().decode(UserMetrics.self, from: JSONEncoder().encode(metrics))
        precondition(restoredMetrics == metrics)
        let groupEnvelope = try envelope("chat", ["messageId": "group-1", "roomUid": "team-room",
            "roomTitle": "Team & Friends", "isGroup": true, "text": "Group reply",
            "conversationUid": "team-room", "title": "Team & Friends"])
        do {
            _ = try GarminRelayProtocol.outgoingCoT(groupEnvelope, identity: identity, fix: nil, now: now)
            fatalError("Unsupported group routing must not become a server broadcast")
        } catch GarminRelayProtocol.Failure.unsupported {}
        let groupXML = try TAKChatMessage.outgoing(senderUID: identity.uid, senderCallSign: identity.resolvedCallSign,
            recipientUID: "team-room", recipientCallSign: "Team & Friends", text: "Group reply",
            now: now, messageID: "group-1", isGroup: true, participantUids: ["other"])
        let receivedGroup = try GarminRelayProtocol.incoming(groupXML, ownUID: "other", receivedAt: now)!
        let groupSentAt = TAKChatMessage.parse(groupXML, ownUID: "other")!.sentAt
        precondition(receivedGroup.type == "chat_received")
        precondition(receivedGroup.payload["uid"] as? String == "group-1")
        precondition(receivedGroup.payload["conversationUid"] as? String == "team-room")
        precondition(receivedGroup.payload["conversationTitle"] as? String == "Team & Friends")
        precondition(receivedGroup.payload["title"] == nil)
        precondition(receivedGroup.payload["senderUid"] as? String == identity.uid)
        precondition(Set(receivedGroup.payload["participantUids"] as! [String]) == [identity.uid, "other"])
        precondition(receivedGroup.payload["senderCallsign"] as? String == identity.resolvedCallSign)
        precondition(receivedGroup.payload["msg"] as? String == "Group reply")
        precondition(receivedGroup.payload["receivedAt"] as? Int64 == Int64(now.timeIntervalSince1970 * 1_000))
        precondition(receivedGroup.payload["sentAt"] as? Int64 == Int64(groupSentAt.timeIntervalSince1970 * 1_000))
        precondition(receivedGroup.payload["messageId"] as? String == "group-1")
        precondition(receivedGroup.payload["eventUid"] as? String == "GeoChat.\(identity.uid).team-room.group-1")
        precondition(receivedGroup.payload["isGroup"] as? Bool == true)
        do {
            _ = try GarminRelayProtocol.outgoingCoT(envelope("chat", [
                "messageId": "published-reply", "roomUid": "team-room", "roomTitle": "Team & Friends",
                "isGroup": true, "msg": "Published reply", "text": "Published reply", "cs": "WATCH"
            ]), identity: identity, fix: nil, now: now)
            fatalError("Published custom-group payload must remain gated")
        } catch GarminRelayProtocol.Failure.unsupported {}
        let msgOnlyReply = try GarminRelayProtocol.outgoingCoT(envelope("chat", [
            "messageId": "msg-only", "roomUid": "other", "roomTitle": "Other",
            "isGroup": false, "msg": "Private msg", "cs": "WATCH",
            "recipientUid": "other", "replyTo": "other"
        ]), identity: identity, fix: nil, now: now)
        precondition(TAKChatMessage.parse(msgOnlyReply, ownUID: "other")?.text == "Private msg")
        precondition(msgOnlyReply.contains("destinations=\"other\""))
        let directXML = try TAKChatMessage.outgoing(senderUID: "other", senderCallSign: "Other",
            recipientUID: identity.uid, recipientCallSign: "Garmin", text: "Private", now: now)
        let receivedDirect = try GarminRelayProtocol.incoming(directXML, ownUID: identity.uid)!
        let directSentAt = TAKChatMessage.parse(directXML, ownUID: identity.uid)!.sentAt
        let delayed = try GarminRelayProtocol.incoming(directXML, ownUID: identity.uid,
            receivedAt: now.addingTimeInterval(600))!
        precondition(delayed.payload["sentAt"] as? Int64 == Int64(directSentAt.timeIntervalSince1970 * 1_000))
        precondition(delayed.payload["receivedAt"] as? Int64 == Int64(now.addingTimeInterval(600).timeIntervalSince1970 * 1_000))
        precondition(delayed.payload["messageId"] as? String == receivedDirect.payload["messageId"] as? String)
        for text in [
            "#weartakcommandusep12 00 server=\(UUID().uuidString)",
            "#weartakcommandsetpdl fixture==",
            "#weartakcommandsetprofile " + String(repeating: "x", count: 513)
        ] {
            let command = try TAKChatMessage.outgoing(senderUID: "other", senderCallSign: "Other",
                recipientUID: identity.uid, recipientCallSign: "Garmin", text: text, now: now)
            do {
                _ = try GarminRelayProtocol.incoming(command, ownUID: identity.uid, receivedAt: now)
                fatalError("Credential or truncated command entered legacy relay")
            } catch GarminRelayProtocol.Failure.unsupported {}
        }
        let longOrdinaryChat = try TAKChatMessage.outgoing(senderUID: "other", senderCallSign: "Other",
            recipientUID: identity.uid, recipientCallSign: "Garmin", text: String(repeating: "x", count: 600), now: now)
        let shortenedOrdinaryChat = try GarminRelayProtocol.incoming(longOrdinaryChat, ownUID: identity.uid)!
        precondition((shortenedOrdinaryChat.payload["msg"] as? String)?.count == 512)
        precondition(receivedDirect.payload["conversationUid"] as? String == "other")
        precondition(receivedDirect.type == "chat_received")
        precondition(receivedDirect.payload["uid"] as? String ==
                     TAKChatMessage.parse(directXML, ownUID: identity.uid)?.id)
        precondition(receivedDirect.payload["isGroup"] as? Bool == false)
        precondition(receivedDirect.payload["conversationTitle"] as? String == "Other")
        precondition(receivedDirect.payload["title"] == nil)
        let directReply = try GarminRelayProtocol.outgoingCoT(envelope("chat", ["messageId": "direct-reply",
            "roomUid": "other", "roomTitle": "Other", "isGroup": false, "text": "Private reply"]),
            identity: identity, fix: nil, now: now)
        precondition(directReply.contains("destinations=\"other\""))
        precondition(TAKChatMessage.parse(directReply, ownUID: "other")?.isGroup == false)
        for titleKey in ["title", "conversationTitle"] {
            let aliasXML = try GarminRelayProtocol.outgoingCoT(envelope("chat", ["messageId": "alias-\(titleKey)",
                "conversationUid": "other", titleKey: "Alias Room", "isGroup": false, "text": "Compatibility"]),
                identity: identity, fix: nil, now: now)
            precondition(aliasXML.contains("chatroom=\"Alias Room\""))
        }
        let unrelated = try GarminRelayProtocol.incoming(directXML, ownUID: "unrelated")
        precondition(unrelated == nil)
        let broadcast = try GarminRelayProtocol.outgoingCoT(envelope("chat", ["messageId": "all-1",
            "roomUid": TAKChatMessage.allChatRoomsUID, "roomTitle": TAKChatMessage.allChatRoomsUID,
            "isGroup": true, "text": "All"]), identity: identity, fix: nil, now: now)
        precondition(!broadcast.contains("__serverdestination"))
        for invalid in [
            ["messageId": "bad-1", "conversationUid": "room", "text": "Missing group flag"],
            ["messageId": "bad-2", "conversationUid": "", "isGroup": false, "text": "No generic fallback"],
            ["messageId": "bad-3", "conversationUid": TAKChatMessage.allChatRoomsUID, "isGroup": false, "text": "Not direct"],
            ["messageId": "bad-4", "recipientUid": 123, "text": "Invalid legacy direct UID"],
            ["messageId": "bad-5", "roomUid": "", "conversationUid": "ignored", "isGroup": false, "text": "Invalid canonical UID"],
            ["messageId": "bad-6", "roomUid": "room", "roomTitle": "", "title": "ignored", "isGroup": true, "text": "Invalid canonical title"],
            ["messageId": "bad-7", "roomUid": "room", "text": "Missing canonical group flag"],
            ["messageId": "bad-8", "roomUid": "other", "conversationUid": "conflict", "isGroup": false, "text": "Private"],
            ["messageId": "bad-9", "roomUid": "other", "recipientUid": "conflict", "isGroup": false, "text": "Private"],
            ["messageId": "bad-10", "roomUid": "other", "roomTitle": "Other", "title": "Conflict", "isGroup": false, "text": "Private"],
            ["messageId": "bad-11", "roomUid": "other", "isGroup": false, "msg": "One", "text": "Two"],
            ["messageId": "bad-12", "roomUid": TAKChatMessage.allChatRoomsUID, "recipientUid": TAKChatMessage.allChatRoomsUID, "isGroup": true, "text": "All"],
            ["messageId": "bad-13", "roomUid": "other", "isGroup": false, "msg": 123, "text": "Valid alias"]
        ] as [[String: Any]] {
            do {
                _ = try GarminRelayProtocol.outgoingCoT(envelope("chat", invalid), identity: identity, fix: nil, now: now)
                fatalError("Invalid conversation must not become a broadcast")
            } catch GarminRelayProtocol.Failure.invalid {}
        }
        print("PASS: JSON types, relay retries, coordinates, metrics, canonical conversationTitle/roomUid/roomTitle, aliases, direct privacy and All Chat Rooms")
    }
}
