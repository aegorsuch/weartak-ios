import Foundation

struct ChatCommand: Equatable {
    let name: String
    let arguments: [String: String]
}

enum ChatCommandParse: Equatable {
    case notCommand
    case malformed(String)
    case parsed(ChatCommand)
}

enum ChatCommandParser {
    static let prefix = "#weartakcommand"
    static let maximumLength = 768
    static let maximumArguments = 12
    static let maximumValueLength = 128
    private static let namePattern = try! NSRegularExpression(pattern: "^[a-z]{1,32}$")
    private static let keyPattern = try! NSRegularExpression(pattern: "^[a-z][a-z0-9]{0,15}$")

    static func parse(_ text: String) -> ChatCommandParse {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.lowercased().hasPrefix(prefix) else { return .notCommand }
        guard body.utf8.count <= maximumLength else { return .malformed("too long") }

        let rest = Array(body.dropFirst(prefix.count))
        let nameEnd = rest.firstIndex(where: \.isWhitespace) ?? rest.endIndex
        let name = String(rest[..<nameEnd]).lowercased()
        guard matches(namePattern, name) else { return .malformed("invalid command name") }

        var arguments: [String: String] = [:]
        var index = nameEnd
        while true {
            while index < rest.endIndex, rest[index].isWhitespace { index += 1 }
            guard index < rest.endIndex else { break }
            guard let equals = rest[index...].firstIndex(of: "=") else {
                return .malformed("argument without value")
            }
            let key = String(rest[index..<equals]).lowercased()
            guard matches(keyPattern, key) else { return .malformed("invalid argument name") }
            guard arguments[key] == nil else { return .malformed("duplicate argument") }
            guard arguments.count < maximumArguments else { return .malformed("too many arguments") }
            index = equals + 1

            var value = ""
            if index < rest.endIndex, rest[index] == "\"" {
                index += 1
                var closed = false
                while index < rest.endIndex {
                    let character = rest[index]
                    index += 1
                    if character == "\\" && index < rest.endIndex &&
                        (rest[index] == "\"" || rest[index] == "\\") {
                        value.append(rest[index])
                        index += 1
                    } else if character == "\"" {
                        closed = true
                        break
                    } else {
                        value.append(character)
                    }
                }
                guard closed else { return .malformed("unterminated quote") }
                if index < rest.endIndex, !rest[index].isWhitespace {
                    return .malformed("text after quote")
                }
            } else {
                while index < rest.endIndex, !rest[index].isWhitespace {
                    value.append(rest[index])
                    index += 1
                }
            }
            guard !value.isEmpty, value.utf8.count <= maximumValueLength,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                return .malformed("invalid argument value")
            }
            arguments[key] = value
        }
        return .parsed(ChatCommand(name: name, arguments: arguments))
    }

    private static func matches(_ pattern: NSRegularExpression, _ value: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        return pattern.firstMatch(in: value, range: range)?.range == range
    }
}

enum ChatCommandAuthorization: Equatable {
    case allowed, senderNotAllowed, stale, duplicate
}

struct ChatCommandAuthorizer {
    private(set) var seen: [String] = []
    let maximumAge: TimeInterval
    let maximumRemembered: Int

    init(maximumAge: TimeInterval = 300, maximumRemembered: Int = 128) {
        self.maximumAge = maximumAge
        self.maximumRemembered = maximumRemembered
    }

    mutating func authorize(senderUID: String, allowedUIDs: [String], messageID: String,
                            sentAt: Date, now: Date) -> ChatCommandAuthorization {
        let sender = senderUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sender.isEmpty, allowedUIDs.contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == sender
        }) else { return .senderNotAllowed }
        let age = now.timeIntervalSince(sentAt)
        guard age.isFinite, abs(age) <= maximumAge else { return .stale }
        let key = "\(sender)|\(messageID)"
        guard !seen.contains(key) else { return .duplicate }
        seen.append(key)
        if seen.count > maximumRemembered { seen.removeFirst(seen.count - maximumRemembered) }
        return .allowed
    }

    static func parseAllowList(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
