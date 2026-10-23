import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

struct GarminEnvelope {
    static let maximumBytes = 6_000
    let type: String
    let payload: [String: Any]

    var object: [String: Any] { ["msgType": type, "payload": payload] }

    init(_ type: String, _ payload: [String: Any] = [:]) {
        self.type = type
        self.payload = payload
    }

    init(object: Any) throws {
        guard let root = object as? [String: Any], let type = root["msgType"] as? String,
              !type.isEmpty, type.count <= 64, let payload = root["payload"] as? [String: Any],
              JSONSerialization.isValidJSONObject(root),
              try JSONSerialization.data(withJSONObject: root).count <= Self.maximumBytes else {
            throw GarminRelayProtocol.Failure.invalid("message envelope")
        }
        self.init(type, payload)
    }

    func string(_ key: String, maximum: Int = 256) throws -> String {
        guard let value = payload[key] as? String, !value.isEmpty, value.count <= maximum,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw GarminRelayProtocol.Failure.invalid(key)
        }
        return value
    }

    func integer(_ key: String, range: ClosedRange<Int>) throws -> Int {
        guard let value = payload[key] as? NSNumber, !Self.isBoolean(value),
              value.doubleValue.isFinite, value.doubleValue == Double(value.intValue),
              range.contains(value.intValue) else { throw GarminRelayProtocol.Failure.invalid(key) }
        return value.intValue
    }

    func boolean(_ key: String) throws -> Bool {
        guard let value = payload[key] as? NSNumber, Self.isBoolean(value) else {
            throw GarminRelayProtocol.Failure.invalid(key)
        }
        return value.boolValue
    }

    static func isBoolean(_ value: NSNumber) -> Bool {
        #if canImport(CoreFoundation)
        return CFGetTypeID(value) == CFBooleanGetTypeID()
        #else
        return value === NSNumber(value: true) || value === NSNumber(value: false)
        #endif
    }
}

enum GarminRelayProtocol {
    static let applicationID = UUID(uuidString: "5721f67e-bcc4-47e8-b337-2ad96ee77c0a")!
    static let maximumEntities = 50

    enum Failure: LocalizedError {
        case invalid(String), unsupported(String), noIdentity, noLocation
        var errorDescription: String? {
            switch self {
            case .invalid(let field): return "Invalid Garmin \(field)."
            case .unsupported(let type): return "This Companion does not support Garmin \(type)."
            case .noIdentity: return "Open WearTAK on Garmin and enable its phone relay to share watch settings."
            case .noLocation: return "A recent, precise iPhone GPS fix is required."
            }
        }
    }

    static func identity(_ envelope: GarminEnvelope, uid: UUID, now: Date = Date()) throws -> WatchReportingIdentity {
        guard let callsign = envelope.payload["callsign"] as? String else { throw Failure.invalid("callsign") }
        let interval = try envelope.integer("reportIntSecs", range: 1...3600)
        let dynamic = envelope.payload["dynamicReporting"] == nil ? false : try envelope.boolean("dynamicReporting")
        func reporting(_ key: String) throws -> Int {
            envelope.payload[key] == nil ? interval : try envelope.integer(key, range: 1...86_400)
        }
        return try WatchReportingIdentity(uid: uid.uuidString.lowercased(), callSign: callsign,
            team: envelope.string("team", maximum: 32), role: envelope.string("role", maximum: 64),
            companionSelected: true, constantStrategy: !dynamic, constantInterval: interval,
            stationaryInterval: reporting("stationaryIntSecs"), onFootInterval: reporting("onFootIntSecs"),
            vehicleInterval: reporting("vehicleIntSecs"), issuedAt: now,
            alertingInterval: reporting("alertIntSecs"),
            alertActive: envelope.payload["alertActive"] == nil ? false : envelope.boolean("alertActive")).validated(now: now)
    }

    static func metrics(_ envelope: GarminEnvelope) throws -> UserMetrics {
        var result = UserMetrics(source: "Garmin watch profile", measuredAt: Date())
        if envelope.payload["birthYear"] != nil { result.birthYear = try envelope.integer("birthYear", range: 1900...2100) }
        func number(_ key: String) throws -> Double? {
            guard let value = envelope.payload[key] else { return nil }
            guard let number = value as? NSNumber, !GarminEnvelope.isBoolean(number),
                  number.doubleValue.isFinite else { throw Failure.invalid(key) }
            return number.doubleValue
        }
        result.heightCM = try number("heightCM")
        result.weightKG = try number("weightKG")
        result.sex = envelope.payload["sex"] as? String
        return try result.validated()
    }

    static func request(_ envelope: GarminEnvelope, identity: WatchReportingIdentity?,
                        fix: PhoneLocationFix?, channelServers: [UUID], now: Date = Date()) throws -> BridgeWire.Message {
        switch envelope.type {
        case "relay_hello":
            guard try envelope.integer("protocolVersion", range: 1...1) == 1 else { throw Failure.invalid("version") }
            return BridgeWire.Message(kind: .hello)
        case "entity_sync_request":
            // Watches may request their larger local retention limit; replies remain capped below.
            _ = try envelope.integer("limit", range: 1...999)
            return BridgeWire.Message(kind: .mapSnapshot)
        case "location_request":
            let action = try envelope.string("action", maximum: 32)
            guard ["map", "navigation", "identity", "self_marker", "pli"].contains(action) else {
                throw Failure.invalid("location action")
            }
            _ = try envelope.string("requestId", maximum: 128)
            return BridgeWire.Message(kind: .hello, locationRefresh: true)
        case "channels_servers_request": return BridgeWire.Message(kind: .channels)
        case "channels_request", "channels_update":
            let index = try envelope.integer("serverIndex", range: 0...max(0, channelServers.count - 1))
            guard channelServers.indices.contains(index), let identity else { throw Failure.invalid("server selection") }
            return try BridgeWire.Message(kind: envelope.type == "channels_update" ? .channelUpdate : .channels,
                serverID: channelServers[index],
                channelBitPosition: envelope.type == "channels_update" ? envelope.integer("bitpos", range: 0...65535) : nil,
                channelActive: envelope.type == "channels_update" ? envelope.boolean("active") : nil,
                clientUID: identity.uid)
        case "missions_servers_request", "missions_request", "mission_update":
            guard try envelope.integer("dataSyncVersion", range: 1...1) == 1 else { throw Failure.invalid("Data Sync version") }
            _ = try envelope.string("requestId", maximum: 128)
            let discovery = envelope.type == "missions_servers_request"
            let id = discovery ? nil : UUID(uuidString: try envelope.string("serverID", maximum: 128))
            guard discovery || id != nil else { throw Failure.invalid("server ID") }
            if envelope.type == "mission_update", identity == nil { throw Failure.noIdentity }
            return try BridgeWire.Message(kind: envelope.type == "mission_update" ? .missionUpdate : .missions,
                serverID: id, clientUID: identity?.uid,
                missionName: envelope.type == "mission_update" ? envelope.string("missionName", maximum: 128) : nil,
                missionSubscribe: envelope.type == "mission_update" ? envelope.boolean("missionSubscribe") : nil,
                latitude: fix?.latitude, longitude: fix?.longitude)
        case "marker", "marker_delete", "emergency", "chat":
            guard let identity else { throw Failure.noIdentity }
            let xml = try outgoingCoT(envelope, identity: identity, fix: fix, now: now)
            // The Companion delivery ledger assigns stable IDs to queued event requests.
            return BridgeWire.Message(kind: .cot, xml: xml)
        default: throw Failure.unsupported(envelope.type)
        }
    }

    static func outgoingCoT(_ envelope: GarminEnvelope, identity: WatchReportingIdentity,
                            fix: PhoneLocationFix?, now: Date) throws -> String {
        let p = envelope.payload
        let stamp = ISO8601DateFormatter()
        let time = stamp.string(from: now)
        let stale = stamp.string(from: now.addingTimeInterval(envelope.type == "marker" ? 86_400 : 300))
        let escape = PhonePLI.escape
        let messageID = try envelope.string("messageId", maximum: 128)
        if envelope.type == "chat" {
            func consistent(_ keys: [String]) throws -> String? {
                let values = try keys.filter { p[$0] != nil }.map { try envelope.string($0) }
                guard Set(values).count <= 1 else { throw Failure.invalid("conflicting \(keys[0]) aliases") }
                return values.first
            }
            let hasConversation = p["roomUid"] != nil || p["conversationUid"] != nil
            let recipient = try consistent(["roomUid", "conversationUid", "recipientUid", "replyTo"]) ??
                TAKChatMessage.allChatRoomsUID
            let isGroup = p["isGroup"] == nil ? recipient == TAKChatMessage.allChatRoomsUID : try envelope.boolean("isGroup")
            guard !hasConversation || p["isGroup"] != nil else { throw Failure.invalid("isGroup") }
            guard recipient != TAKChatMessage.allChatRoomsUID || isGroup else { throw Failure.invalid("conversationUid") }
            guard !isGroup || p["recipientUid"] == nil && p["replyTo"] == nil else {
                throw Failure.invalid("group with direct recipient aliases")
            }
            let title = try consistent(["roomTitle", "conversationTitle", "title"]) ?? recipient
            let texts = try ["msg", "text"].filter { p[$0] != nil }.map { key -> String in
                guard let value = p[key] as? String else { throw Failure.invalid(key) }
                return value
            }
            guard Set(texts).count <= 1 else { throw Failure.invalid("conflicting text aliases") }
            if isGroup, recipient != TAKChatMessage.allChatRoomsUID {
                throw Failure.unsupported("custom-group recipient routing")
            }
            let text = texts.first ?? ""
            return try TAKChatMessage.outgoing(senderUID: identity.uid, senderCallSign: identity.resolvedCallSign,
                recipientUID: recipient, recipientCallSign: title, text: text, now: now,
                messageID: messageID, isGroup: isGroup)
        }
        let uid = try envelope.string("uid")
        guard uid.hasPrefix("garmin-") else { throw Failure.invalid("event UID") }
        let scopedUID = identity.uid + "." + uid
        if envelope.type == "marker_delete" {
            return "<event version=\"2.0\" uid=\"\(escape(scopedUID))\" type=\"t-x-d-d\" time=\"\(time)\" start=\"\(time)\" stale=\"\(stale)\" how=\"h-g-i-g-o\"><point lat=\"0\" lon=\"0\" hae=\"9999999\" ce=\"9999999\" le=\"9999999\"/><detail><link uid=\"\(escape(scopedUID))\" relation=\"p-p\" type=\"a-u-G-T\"/></detail></event>"
        }
        if envelope.type == "emergency", p["state"] as? String == "CANCEL", fix == nil {
            return "<event version=\"2.0\" uid=\"\(escape(scopedUID))\" type=\"b-a-o-can\" time=\"\(time)\" start=\"\(time)\" stale=\"\(stale)\"><detail><emergency cancel=\"true\"/><link uid=\"\(escape(identity.uid))\" relation=\"p-p\"/></detail></event>"
        }
        let latitude: Double
        let longitude: Double
        let locationFix: PhoneLocationFix?
        if envelope.type == "marker", p["locationSource"] as? String != "phone" {
            guard let lat = p["lat"] as? NSNumber, let lon = p["lon"] as? NSNumber,
                  !GarminEnvelope.isBoolean(lat), !GarminEnvelope.isBoolean(lon),
                  (-90...90).contains(lat.doubleValue), (-180...180).contains(lon.doubleValue) else {
                throw Failure.invalid("marker location")
            }
            latitude = lat.doubleValue
            longitude = lon.doubleValue
            locationFix = nil
        } else if let fix, AlertLocationHistory.isUsable(fix, now: fix.timestamp),
                  fix.timestamp <= now.addingTimeInterval(5) {
            latitude = fix.latitude
            longitude = fix.longitude
            locationFix = fix
        } else { throw Failure.noLocation }
        let type: String
        let detail: String
        if envelope.type == "marker" {
            type = try envelope.string("type", maximum: 32)
            guard ["a-h-G-T", "a-f-G-T", "a-n-G-T", "a-u-G-T"].contains(type) else { throw Failure.invalid("marker type") }
            let title = (p["title"] as? String) ?? uid
            let remark = (p["remark"] as? String) ?? ""
            guard title.count <= 128, remark.count <= 512 else { throw Failure.invalid("marker text") }
            detail = "<contact callsign=\"\(escape(title))\"/><remarks>\(escape(remark))</remarks><link uid=\"\(escape(identity.uid))\" relation=\"p-p\" type=\"a-f-G-U-C\"/><takv device=\"Map Marker\"/>"
        } else {
            let state = try envelope.string("state", maximum: 16)
            guard ["ALERT", "CANCEL"].contains(state) else { throw Failure.invalid("emergency state") }
            type = state == "CANCEL" ? "b-a-o-can" : "b-a-o"
            let category = (p["alertType"] as? String) ?? (p["catg"] as? String) ?? "Manual Alert"
            let description = (p["desc"] as? String) ?? category
            guard category.count <= 128, description.count <= 512 else { throw Failure.invalid("alert text") }
            detail = "<contact callsign=\"\(escape(identity.resolvedCallSign))\"/><emergency type=\"\(escape(category))\" cancel=\"\(state == "CANCEL")\">\(escape(description))</emergency><link uid=\"\(escape(identity.uid))\" relation=\"p-p\" type=\"a-f-G-U-C\"/>"
        }
        let ce = locationFix.map { AlertLocationHistory.circularError($0, now: now) } ?? 9_999_999
        let locationDetail = locationFix.map { AlertLocationHistory.detail($0, now: now) } ?? ""
        return "<event version=\"2.0\" uid=\"\(escape(scopedUID))\" type=\"\(type)\" time=\"\(time)\" start=\"\(time)\" stale=\"\(stale)\" how=\"h-g-i-g-o\"><point lat=\"\(latitude)\" lon=\"\(longitude)\" hae=\"9999999\" ce=\"\(ce)\" le=\"9999999\"/><detail>\(detail)\(locationDetail)</detail></event>"
    }

    static func incoming(_ xml: String, ownUID: String, receivedAt: Date = Date()) throws -> GarminEnvelope? {
        guard CoTStreamFramer.isEvent(Data(xml.utf8)) else { throw Failure.invalid("CoT") }
        let delegate = GarminCoTParser()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let uid = delegate.event["uid"], let type = delegate.event["type"] else {
            throw Failure.invalid("CoT event")
        }
        if uid == ownUID || delegate.senderUID == ownUID { return nil }
        if type == "b-t-f" {
            guard let message = TAKChatMessage.parse(xml, ownUID: ownUID) else { return nil }
            var payload: [String: Any] = ["uid": message.id, "sender": message.senderCallSign,
                "text": String(message.text.prefix(512)), "messageId": message.id,
                "senderUid": message.senderUID, "senderCallsign": message.senderCallSign,
                "msg": String(message.text.prefix(512)), "eventUid": uid,
                "receivedAt": Int64(receivedAt.timeIntervalSince1970 * 1_000),
                "conversationUid": message.conversationUID(ownUID: ownUID),
                "conversationTitle": message.title ?? message.senderCallSign, "isGroup": message.isGroup]
            if message.isGroup { payload["participantUids"] = message.participantUids }
            return GarminEnvelope("chat_received", payload)
        }
        guard type.hasPrefix("a-") || type.hasPrefix("b-a-o") || type == "b-a-g" ||
                type == "b-m-p-s-m" || type.hasPrefix("u-d-") || type == "t-x-d-d" ||
                delegate.emergency != nil else { return nil }
        var payload: [String: Any] = ["uid": uid, "type": type]
        for key in ["time", "start", "stale", "how"] { if let value = delegate.event[key] { payload[key] = value } }
        if let point = delegate.point, let lat = Double(point["lat"] ?? ""), let lon = Double(point["lon"] ?? ""),
           lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon),
           !(lat == 0 && lon == 0) {
            payload["lat"] = lat
            payload["lon"] = lon
            if let ce = point["ce"].flatMap(Double.init), ce.isFinite, ce >= 0 { payload["ce"] = ce }
        }
        if let link = delegate.link { payload["link"] = link }
        if let ellipse = delegate.ellipse {
            payload["shape"] = ["ellipse": ellipse]
            if let major = ellipse["major"], let minor = ellipse["minor"],
               major == minor, major <= 100_000 { payload["radius"] = major }
        }
        if payload["lat"] == nil, type != "t-x-d-d", !type.hasPrefix("b-a-o"), delegate.emergency == nil { return nil }
        let isUser = type.hasPrefix("a-") &&
            (delegate.hasUserMetadata || type.split(separator: "-").dropFirst(2).starts(with: ["G", "U", "C"]))
        payload["isUser"] = isUser
        payload["isPoint"] = !isUser
        if let value = delegate.callsign { payload["callSign"] = String(value.prefix(128)) }
        if let value = delegate.team { payload["team"] = String(value.prefix(32)) }
        if let value = delegate.role { payload["role"] = String(value.prefix(64)) }
        if let value = delegate.senderUID { payload["senderUID"] = value }
        if let emergency = delegate.emergency {
            payload["emergency"] = emergency
            payload["isAlert"] = true
        }
        return GarminEnvelope("entity", payload)
    }
}

private final class GarminCoTParser: NSObject, XMLParserDelegate {
    var event: [String: String] = [:]
    var point: [String: String]?
    var callsign: String?
    var team: String?
    var role: String?
    var senderUID: String?
    var emergency: [String: String]?
    var link: [String: String]?
    var ellipse: [String: Double]?
    var hasUserMetadata = false
    private var depth = 0
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        depth += 1
        switch (depth, elementName) {
        case (1, "event"): event = attributes
        case (2, "point"): point = attributes
        case (3, "contact"):
            callsign = attributes["callsign"]
            if !(attributes["endpoint"]?.isEmpty ?? true) { hasUserMetadata = true }
        case (3, "__group"):
            team = attributes["name"]; role = attributes["role"]; hasUserMetadata = true
        case (3, "takv"): break
        case (3, "uid"):
            if !(attributes["Droid"]?.isEmpty ?? true) { hasUserMetadata = true }
        case (3, "link"):
            if let uid = attributes["uid"], !uid.isEmpty, let relation = attributes["relation"] {
                link = ["uid": uid, "relation": relation]
                if relation == "p-p" { senderUID = uid }
            }
        case (3, "emergency"): emergency = attributes
        case (4, "ellipse"):
            if let major = attributes["major"].flatMap(Double.init),
               let minor = attributes["minor"].flatMap(Double.init),
               major.isFinite, minor.isFinite, major > 0, minor > 0,
               major <= 100_000, minor <= 100_000 {
                ellipse = ["major": major, "minor": minor]
                if let angle = attributes["angle"].flatMap(Double.init), angle.isFinite {
                    ellipse?["angle"] = angle
                }
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        depth -= 1
    }
}
