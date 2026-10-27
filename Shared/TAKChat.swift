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
    let conversationUid: String?
    let title: String?
    let isGroup: Bool
    let participantUids: [String]
    var deduplicationID: String { "\(senderUID).\(id)" }

    init(id: String, senderUID: String, recipientUID: String, senderCallSign: String,
         text: String, sentAt: Date, conversationUid: String? = nil, title: String? = nil,
         isGroup: Bool = false, participantUids: [String] = []) {
        self.id = id
        self.senderUID = senderUID
        self.recipientUID = recipientUID
        self.senderCallSign = senderCallSign
        self.text = text
        self.sentAt = sentAt
        self.conversationUid = conversationUid
        self.title = title
        self.isGroup = isGroup
        self.participantUids = participantUids
    }

    func conversationUID(ownUID: String) -> String {
        isGroup ? (conversationUid ?? recipientUID) : (senderUID == ownUID ? recipientUID : senderUID)
    }

    static let allChatRoomsUID = "All Chat Rooms"
    static let maximumTextBytes = 2_000
    static func isProvisioningCommand(_ text: String) -> Bool {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace).first?.lowercased()
        return name == "#weartakcommandusep12" || name == "#weartakcommandsetpdl" ||
            name == "#weartakcommandenrollserver"
    }

    static func isEnrollServerCommand(_ text: String) -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefix = "#weartakcommand"
        guard body.hasPrefix(prefix) else { return false }
        return body.dropFirst(prefix.count).split(whereSeparator: \.isWhitespace).first == "enrollserver"
    }

    static func isCommandOnly(_ text: String) -> Bool {
        guard !isProvisioningCommand(text) else { return true }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefix = "#weartakcommand"
        guard body.hasPrefix(prefix) else { return false }
        return body.dropFirst(prefix.count)
            .split(whereSeparator: \.isWhitespace).first == "enrollserver"
    }

    // Only provisioning commands may exceed the ordinary chat budget.
    static func acceptsTextLength(_ text: String) -> Bool {
        text.utf8.count <= (isProvisioningCommand(text) ? 24_000 : maximumTextBytes)
    }
    static let quickMessages = ["In Position", "Negative", "Objective Sighted", "Roger"]

    static func quickMessages(including custom: [String]) -> [String] {
        (quickMessages + custom).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func outgoing(senderUID: String, senderCallSign: String, recipientUID: String,
                         recipientCallSign: String, text: String, now: Date = Date(),
                         messageID: String = UUID().uuidString, isGroup: Bool = false,
                         participantUids: [String] = []) throws -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !senderUID.isEmpty, !recipientUID.isEmpty, senderUID != recipientUID,
              !body.isEmpty, acceptsTextLength(body), !messageID.isEmpty,
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
        let group = isGroup || recipientUID == allChatRoomsUID
        let members = Array(Set(participantUids.filter { $0 != senderUID && $0 != recipientUID })).sorted()
        let namedGroup = group && recipientUID != allChatRoomsUID
        if namedGroup {
            guard !members.isEmpty, members.allSatisfy({
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            }) else { throw ChatError.invalidMessage }
        }
        let recipientAttributes = namedGroup
            ? members.enumerated().map { "uid\($0.offset + 1)=\"\(escape($0.element))\"" }.joined(separator: " ")
            : "uid1=\"\(recipient)\""
        let destination: String
        if namedGroup {
            destination = "<marti>" + members.map { "<dest uid=\"\(escape($0))\"/>" }.joined() + "</marti>"
        } else {
            destination = group ? "" : "<__serverdestination destinations=\"\(recipient)\"/>"
        }
        return """
        <event version="2.0" uid="GeoChat.\(sender).\(recipient).\(id)" type="b-t-f" time="\(timestamp)" start="\(timestamp)" stale="\(stale)" how="h-g-i-g-o"><point lat="0" lon="0" hae="9999999" ce="9999999" le="9999999"/><detail><__chat id="\(recipient)" chatroom="\(escape(recipientCallSign))" senderCallsign="\(escape(senderCallSign))" messageId="\(id)" groupOwner="false"><chatgrp uid0="\(sender)" \(recipientAttributes) id="\(recipient)"/></__chat><link uid="\(sender)" type="a-f-G-U-C" relation="p-p"/><remarks source="BAO.F.ATAK.\(sender)" to="\(recipient)" time="\(timestamp)">\(escape(body))</remarks>\(destination)</detail></event>
        """
    }

    private static func parsedXML(_ xml: String) -> TAKChatParser? {
        guard CoTStreamFramer.isEvent(Data(xml.utf8)) else { return nil }
        let delegate = TAKChatParser()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        return parser.parse() ? delegate : nil
    }

    static func containsProvisioningCommand(in xml: String) -> Bool {
        guard let delegate = parsedXML(xml), delegate.type == "b-t-f" else { return false }
        return isProvisioningCommand(delegate.text)
    }

    static func containsCommandOnly(in xml: String) -> Bool {
        guard let delegate = parsedXML(xml), delegate.type == "b-t-f" else { return false }
        return isCommandOnly(delegate.text)
    }

    /// How the iPhone handles an incoming TAK server or Ditto chat event. Every event is forwarded unchanged
    /// to the watch while it is reachable, so the original sender UID reaches the watch's authorization.
    /// Provisioning commands (including enrollserver) are never retained in the phone's chat buffer,
    /// so a password is never held for later handshake replies.
    enum PhoneRelay: Equatable { case buffered, liveOnly }

    static func phoneRelay(forXML xml: String) -> PhoneRelay {
        containsCommandOnly(in: xml) ? .liveOnly : .buffered
    }

    static func parse(_ xml: String, ownUID: String) -> Self? {
        guard let delegate = parsedXML(xml), delegate.type == "b-t-f", let chat = delegate.chat,
              let group = delegate.group, let sender = group["uid0"], let recipient = group["uid1"],
              sender != recipient,
              let id = chat["messageId"], !id.isEmpty, !sender.isEmpty, !recipient.isEmpty,
              !delegate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              acceptsTextLength(delegate.text),
              let stamp = delegate.timestamp else { return nil }
        let room = chat["id"] ?? group["id"] ?? recipient
        guard !room.isEmpty else { return nil }
        if let chatID = chat["id"], let groupID = group["id"], chatID != groupID { return nil }
        let recipients = group.filter {
            $0.key.hasPrefix("uid") && (Int($0.key.dropFirst(3)) ?? 0) > 0
        }.map(\.value)
        let isBroadcast = room == allChatRoomsUID
        let isDirect = room == ownUID || room == sender || delegate.remarksTo == ownUID
        let isGroup = isBroadcast || !isDirect && room != recipient
        if isGroup, !isBroadcast {
            guard let title = chat["chatroom"], !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  recipients.contains(ownUID) || sender == ownUID else { return nil }
        } else if !isBroadcast {
            guard recipient == ownUID || sender == ownUID else { return nil }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: stamp)
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = fractional ?? formatter.date(from: stamp) else { return nil }
        return Self(id: id, senderUID: sender, recipientUID: recipient,
                    senderCallSign: chat["senderCallsign"] ?? sender, text: delegate.text, sentAt: date,
                    conversationUid: isGroup ? room : nil, title: isGroup ? (chat["chatroom"] ?? room) : nil,
                    isGroup: isGroup, participantUids: isGroup ? Array(Set([sender] + recipients)).sorted() : [])
    }

    enum ChatError: LocalizedError {
        case invalidMessage
        var errorDescription: String? { "Enter a message of 1 to 2,000 UTF-8 bytes for a different contact." }
    }
}

struct SavedChatMessages {
    static let storageKey = "WearTAK.savedChatMessages"
    private(set) var messages: [String]

    enum Failure: LocalizedError {
        case invalidText, unreadable
        var errorDescription: String? {
            switch self {
            case .invalidText: return String(localized: "Enter a single-line message of 1 to 128 characters (up to 2,000 UTF-8 bytes).")
            case .unreadable: return String(localized: "Saved messages could not be loaded. Existing data has not been overwritten.")
            }
        }
    }

    init(defaults: UserDefaults) throws {
        guard let stored = defaults.object(forKey: Self.storageKey) else { messages = []; return }
        guard let values = stored as? [String] else { throw Failure.unreadable }
        messages = []
        for value in values {
            guard let text = Self.validated(value) else { throw Failure.unreadable }
            if existing(text) == nil { messages.append(text) }
        }
    }

    @discardableResult
    mutating func add(_ value: String, defaults: UserDefaults) throws -> String {
        guard let text = Self.validated(value) else { throw Failure.invalidText }
        if let duplicate = existing(text) { return duplicate }
        messages.append(text)
        defaults.set(messages, forKey: Self.storageKey)
        return text
    }

    mutating func remove(_ text: String, defaults: UserDefaults) {
        messages.removeAll { $0 == text }
        defaults.set(messages, forKey: Self.storageKey)
    }

    private func existing(_ text: String) -> String? {
        (TAKChatMessage.quickMessages + messages).first {
            $0.caseInsensitiveCompare(text) == .orderedSame
        }
    }

    private static func validated(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 128, text.utf8.count <= TAKChatMessage.maximumTextBytes,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) ||
                  CharacterSet.newlines.contains($0) }) else { return nil }
        return text
    }
}

enum TAKChatPickerEntry<Conversation: Hashable>: Hashable {
    case allChatRooms, selectUser, conversation(Conversation)
}

struct TAKChatInbox<Conversation: Hashable> {
    private(set) var messages: [Conversation: [TAKChatMessage]] = [:]
    private(set) var unreadCounts: [Conversation: Int] = [:]
    private var visibleConversation: Conversation?
    private(set) var lastReceived: [Conversation: Date] = [:]
    private(set) var latestMetadata: [Conversation: TAKChatMessage] = [:]
    private var insertionOrder: [Conversation: Int] = [:]
    private var nextOrder = 0

    var unreadCount: Int { unreadCounts.values.reduce(0, +) }

    var conversations: [Conversation] {
        messages.keys.sorted {
            let left = lastReceived[$0] ?? .distantPast
            let right = lastReceived[$1] ?? .distantPast
            return left == right ? (insertionOrder[$0] ?? 0) > (insertionOrder[$1] ?? 0) : left > right
        }
    }

    func pickerEntries(excluding excluded: Set<Conversation> = []) -> [TAKChatPickerEntry<Conversation>] {
        [.allChatRooms, .selectUser] + conversations.filter { !excluded.contains($0) }.map { .conversation($0) }
    }

    mutating func open(_ conversation: Conversation) {
        guard messages[conversation] == nil else { return }
        messages[conversation] = []
        insertionOrder[conversation] = nextOrder
        nextOrder += 1
        evictOldestIfNeeded(excluding: conversation)
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
    mutating func record(_ message: TAKChatMessage, conversation: Conversation, ownUID: String,
                         receivedAt: Date = Date()) -> Bool {
        guard message.isGroup || message.senderUID == ownUID || message.recipientUID == ownUID else { return false }
        guard !messages.values.contains(where: {
            $0.contains(where: { $0.deduplicationID == message.deduplicationID })
        }) else { return false }
        var history = messages[conversation] ?? []
        guard !history.contains(where: { $0.deduplicationID == message.deduplicationID }) else { return false }
        open(conversation)
        history.append(message)
        history.sort { $0.sentAt < $1.sentAt }
        messages[conversation] = Array(history.suffix(50))
        if message.senderUID != ownUID || latestMetadata[conversation] == nil {
            latestMetadata[conversation] = message
        }
        if message.senderUID != ownUID { lastReceived[conversation] = receivedAt }
        let notify = message.senderUID != ownUID && visibleConversation != conversation
        if notify {
            unreadCounts[conversation] = min((unreadCounts[conversation] ?? 0) + 1, 50)
        }
        evictOldestIfNeeded()
        return notify && messages[conversation] != nil
    }

    private mutating func evictOldestIfNeeded(excluding excluded: Conversation? = nil) {
        if messages.count > 50, let oldest = conversations.last(where: { $0 != excluded }) {
            messages.removeValue(forKey: oldest)
            unreadCounts.removeValue(forKey: oldest)
            lastReceived.removeValue(forKey: oldest)
            latestMetadata.removeValue(forKey: oldest)
            insertionOrder.removeValue(forKey: oldest)
        }
    }
}

private final class TAKChatParser: NSObject, XMLParserDelegate {
    var type: String?
    var chat: [String: String]?
    var group: [String: String]?
    var timestamp: String?
    var remarksTo: String?
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
        case "event/detail/remarks":
            text = ""
            remarksTo = attributes["to"]
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
