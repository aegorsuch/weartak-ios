import Foundation
import CoreFoundation

/// Native Ditto ATAK Edge Sync 1.1.1 chat fields, plus optional lossless WearTAK CoT extensions.
enum DittoChatDocument {
    static let upsertQuery = "INSERT INTO chat DOCUMENTS (:doc) ON ID CONFLICT DO UPDATE"
    static let counterQuery = "UPDATE chat APPLY _c PN_INCREMENT BY :increment WHERE _id = :id"

    static func decode(_ raw: [String: Any], ownUID: String?, verifiedMembers: [String] = [],
                       now: Date = Date()) throws -> DittoCoTDocument {
        func text(_ key: String, maximum: Int = 512) throws -> String {
            guard let value = raw[key] as? String, !value.isEmpty, value.utf8.count <= maximum,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw DittoCoTDocument.Failure.invalid
            }
            return value
        }
        let sender = try text("d"), id = try text("_id"), room = try text("roomId")
        let name = try text("e"), title = try text("room"), parent = try text("parent")
        guard let body = raw["msg"] as? String,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              body.utf8.count <= TAKChatMessage.maximumTextBytes,
              !body.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t"
              }),
              raw["AuthorId"] == nil || raw["AuthorId"] as? String == sender else {
            throw DittoCoTDocument.Failure.invalid
        }
        let type = try text("authorType")
        guard type.hasPrefix("a-"), let time = raw["b"] as? NSNumber,
              CFGetTypeID(time) != CFBooleanGetTypeID(), time.doubleValue.isFinite,
              time.doubleValue > 0, time.doubleValue.rounded(.towardZero) == time.doubleValue else {
            throw DittoCoTDocument.Failure.invalid
        }
        let nativeStale = time.doubleValue + 86_400_000
        var doc = raw
        let eventUID = raw["eventUid"] as? String ?? "GeoChat.\(sender).\(room).\(id)"
        doc["_id"] = eventUID
        doc["d"] = eventUID
        doc["AuthorId"] = sender
        doc["w"] = "b-t-f"
        doc["g"] = raw["g"] ?? "2.0"
        doc["n"] = raw["n"] ?? time
        doc["o"] = raw["o"] ?? nativeStale
        doc["p"] = raw["p"] ?? "h-g-i-g-o"
        doc["q"] = raw["q"] ?? "Undefined"
        let components = try text("authorLoc").split(separator: ",", omittingEmptySubsequences: false)
        var location = components.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard (2...3).contains(components.count), location.count == components.count,
              location.allSatisfy(\.isFinite),
              (-90...90).contains(location[0]), (-180...180).contains(location[1]) else {
            throw DittoCoTDocument.Failure.invalid
        }
        if location.count == 2 { location.append(0) }
        doc["j"] = raw["j"] ?? location[0]
        doc["l"] = raw["l"] ?? location[1]
        doc["i"] = raw["i"] ?? location[2]
        doc["h"] = raw["h"] ?? 9_999_999
        doc["k"] = raw["k"] ?? 9_999_999
        if raw["r"] == nil {
            // Native documents have no roster: only direct-to-self and broadcast are safe to reconstruct.
            let knownGroup = ownUID.map { verifiedMembers.contains($0) && verifiedMembers.contains(sender) } ?? false
            guard ownUID == nil || room == ownUID || room == TAKChatMessage.allChatRoomsUID || knownGroup else {
                throw DittoCoTDocument.Failure.invalid
            }
            let e = DittoCoTDocument.escape
            let recipients = knownGroup ? verifiedMembers.filter { $0 != sender && $0 != room } : [room]
            let attributes = recipients.enumerated().map { "uid\($0.offset + 1)=\"\(e($0.element))\"" }.joined(separator: " ")
            doc["r"] = """
            <detail><__chat id="\(e(room))" chatroom="\(e(title))" senderCallsign="\(e(name))" messageId="\(e(id))" parent="\(e(parent))"><chatgrp uid0="\(e(sender))" \(attributes) id="\(e(room))"/></__chat><remarks to="\(e(room))">\(e(body))</remarks></detail>
            """
        }
        guard let detail = doc["r"] as? String,
              DittoCoTDocument.validChatDetail(detail, title: title, parent: parent) else {
            throw DittoCoTDocument.Failure.invalid
        }
        let decoded = try DittoCoTDocument.decodeAliases(doc, collection: "chat", now: now)
        guard let parsed = TAKChatMessage.parse(decoded.xml, ownUID: ownUID ?? sender),
              parsed.senderUID == sender, parsed.id == id, parsed.text == body,
              (parsed.conversationUid ?? parsed.recipientUID) == room,
              parsed.senderCallSign == name else { throw DittoCoTDocument.Failure.invalid }
        guard decoded.stale.timeIntervalSince1970 * 1_000 <= nativeStale else { throw DittoCoTDocument.Failure.invalid }
        return decoded
    }
}
