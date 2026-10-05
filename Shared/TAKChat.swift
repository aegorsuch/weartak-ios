import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct TAKChatMessage: Identifiable, Equatable {
    let id: String
    let senderUID: String
    let recipientUID: String
    let senderCallSign: String
    let text: String
    let sentAt: Date

    static let maximumTextBytes = 2_000
    static let quickMessages = ["Roger", "Negative", "Objective Sighted", "In Position"]

    static func outgoing(senderUID: String, senderCallSign: String, recipientUID: String,
                         recipientCallSign: String, text: String, now: Date = Date(),
                         messageID: String = UUID().uuidString) throws -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !senderUID.isEmpty, !recipientUID.isEmpty, senderUID != recipientUID,
              !body.isEmpty, body.utf8.count <= maximumTextBytes, !messageID.isEmpty,
              !body.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\n" && $0 != "\t" }) else {
            throw ChatError.invalidMessage
        }
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&apos;")
        }
        let id = escape(messageID)
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: now)
        let stale = formatter.string(from: now.addingTimeInterval(300))
        let sender = escape(senderUID)
        let recipient = escape(recipientUID)
        return """
        <event version="2.0" uid="GeoChat.\(sender).\(recipient).\(id)" type="b-t-f" time="\(timestamp)" start="\(timestamp)" stale="\(stale)" how="h-g-i-g-o"><point lat="0" lon="0" hae="9999999" ce="9999999" le="9999999"/><detail><__chat id="\(recipient)" chatroom="\(escape(recipientCallSign))" senderCallsign="\(escape(senderCallSign))" messageId="\(id)" groupOwner="false"><chatgrp uid0="\(sender)" uid1="\(recipient)" id="\(recipient)"/></__chat><link uid="\(sender)" type="a-f-G-U-C" relation="p-p"/><remarks source="BAO.F.ATAK.\(sender)" to="\(recipient)" time="\(timestamp)">\(escape(body))</remarks><__serverdestination destinations="\(recipient)"/></detail></event>
        """
    }

    static func parse(_ xml: String, ownUID: String) -> Self? {
        guard CoTStreamFramer.isEvent(Data(xml.utf8)) else { return nil }
        let delegate = TAKChatParser()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.type == "b-t-f", let chat = delegate.chat,
              let group = delegate.group, let sender = group["uid0"], let recipient = group["uid1"],
              sender != recipient, recipient == ownUID || sender == ownUID,
              let id = chat["messageId"], !id.isEmpty, !sender.isEmpty, !recipient.isEmpty,
              !delegate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              delegate.text.utf8.count <= maximumTextBytes,
              let stamp = delegate.timestamp else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: stamp)
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = fractional ?? formatter.date(from: stamp) else { return nil }
        return Self(id: id, senderUID: sender, recipientUID: recipient,
                    senderCallSign: chat["senderCallsign"] ?? sender, text: delegate.text, sentAt: date)
    }

    enum ChatError: LocalizedError {
        case invalidMessage
        var errorDescription: String? { "Enter a message of 1 to 2,000 UTF-8 bytes for a different contact." }
    }
}

struct TAKChatInbox<Conversation: Hashable> {
    private(set) var messages: [Conversation: [TAKChatMessage]] = [:]
    private(set) var unreadCounts: [Conversation: Int] = [:]
    private var visibleConversation: Conversation?

    var unreadCount: Int { unreadCounts.values.reduce(0, +) }

    var conversations: [Conversation] {
        messages.keys.sorted {
            (messages[$0]?.last?.sentAt ?? .distantPast) > (messages[$1]?.last?.sentAt ?? .distantPast)
        }
    }

    mutating func setVisible(_ conversation: Conversation, visible: Bool) {
        if visible {
            visibleConversation = conversation
            unreadCounts.removeValue(forKey: conversation)
        } else if visibleConversation == conversation {
            visibleConversation = nil
        }
    }

    // Returns true only when a new incoming message should notify the user.
    mutating func record(_ message: TAKChatMessage, conversation: Conversation, ownUID: String) -> Bool {
        guard message.senderUID == ownUID || message.recipientUID == ownUID else { return false }
        var history = messages[conversation] ?? []
        guard !history.contains(where: { $0.id == message.id }) else { return false }
        history.append(message)
        history.sort { $0.sentAt < $1.sentAt }
        messages[conversation] = Array(history.suffix(50))
        let notify = message.senderUID != ownUID && visibleConversation != conversation
        if notify {
            unreadCounts[conversation] = min((unreadCounts[conversation] ?? 0) + 1, 50)
        }
        if messages.count > 50,
           let oldest = messages.min(by: { ($0.value.last?.sentAt ?? .distantPast) < ($1.value.last?.sentAt ?? .distantPast) })?.key {
            messages.removeValue(forKey: oldest)
            unreadCounts.removeValue(forKey: oldest)
        }
        return notify && messages[conversation] != nil
    }
}

private final class TAKChatParser: NSObject, XMLParserDelegate {
    var type: String?
    var chat: [String: String]?
    var group: [String: String]?
    var timestamp: String?
    var text = ""
    private var elements: [String] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        elements.append(elementName)
        switch elements.joined(separator: "/") {
        case "event":
            type = attributes["type"]
            timestamp = attributes["time"]
        case "event/detail/__chat": chat = attributes
        case "event/detail/__chat/chatgrp": group = attributes
        case "event/detail/remarks": text = ""
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if elements == ["event", "detail", "remarks"] { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if elements == ["event", "detail", "remarks"], let value = String(data: CDATABlock, encoding: .utf8) {
            text += value
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if !elements.isEmpty { elements.removeLast() }
    }
}
