import Foundation

struct ChatCommand: Equatable {
    let name: String
    let arguments: [String: String]
    var positional: [String] = []
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
    static let maximumProvisioningLength = 24_000
    private static let namePattern = try! NSRegularExpression(pattern: "^[a-z]{1,32}$")
    private static let keyPattern = try! NSRegularExpression(pattern: "^[a-z][a-z0-9]{0,15}$")

    static func parse(_ text: String) -> ChatCommandParse {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.lowercased().hasPrefix(prefix) else { return .notCommand }
        guard body.utf8.count <= maximumProvisioningLength else { return .malformed("too long") }

        let rest = Array(body.dropFirst(prefix.count))
        let nameEnd = rest.firstIndex(where: \.isWhitespace) ?? rest.endIndex
        let name = String(rest[..<nameEnd]).lowercased()
        guard matches(namePattern, name) else { return .malformed("invalid command name") }
        let provisioning = name == "usep12" || name == "setpdl"
        guard provisioning || body.utf8.count <= maximumLength else { return .malformed("too long") }

        var arguments: [String: String] = [:]
        var positional: [String] = []
        var index = nameEnd
        while true {
            while index < rest.endIndex, rest[index].isWhitespace { index += 1 }
            guard index < rest.endIndex else { break }
            // The credential is the first positional token, including base64 padding in a PDL.
            if provisioning, positional.isEmpty {
                let end = rest[index...].firstIndex(where: \.isWhitespace) ?? rest.endIndex
                let token = String(rest[index..<end])
                guard !token.isEmpty else { return .malformed("missing credential") }
                positional.append(token)
                index = end
                continue
            }
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
            guard (!value.isEmpty || (provisioning && key == "password")),
                  value.utf8.count <= maximumValueLength,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                return .malformed("invalid argument value")
            }
            arguments[key] = value
        }
        return .parsed(ChatCommand(name: name, arguments: arguments, positional: positional))
    }

    private static func matches(_ pattern: NSRegularExpression, _ value: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        return pattern.firstMatch(in: value, range: range)?.range == range
    }
}

enum ChatCommandAuthorization: Equatable {
    case allowed, senderNotAllowed, stale, duplicate, rateLimited
}

struct ChatCommandAuthorizer: Codable {
    private var seen: [String: Date] = [:]
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
        seen = seen.filter { now.timeIntervalSince($0.value) <= maximumAge * 2 }
        // Length-prefix the sender so delimiter characters cannot create colliding receipt keys.
        let key = "\(sender.utf8.count):\(sender)\(messageID)"
        guard seen[key] == nil else { return .duplicate }
        guard seen.count < maximumRemembered else { return .rateLimited }
        seen[key] = now
        return .allowed
    }

    static func parseAllowList(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

enum AtomicRecordReplacement {
    enum Failure: Error { case readbackMismatch }

    static func apply<Value: Equatable>(_ candidate: Value,
        read: () throws -> Value?, write: (Value) throws -> Void, remove: () throws -> Void) throws {
        let previous = try read()
        try write(candidate)
        do {
            guard try read() == candidate else { throw Failure.readbackMismatch }
        } catch {
            if let previous { try write(previous) } else { try remove() }
            throw error
        }
    }
}

struct ChatP12Request {
    static let maximumBytes = 8_192
    let data: Data
    let password: String
    let server: String?

    init(_ command: ChatCommand) throws {
        guard command.name == "usep12", command.positional.count == 1,
              Set(command.arguments.keys).isSubset(of: ["password", "server"]) else {
            throw Failure.syntax
        }
        let hex = Array(command.positional[0].utf8)
        guard !hex.isEmpty, hex.count <= Self.maximumBytes * 2, hex.count.isMultiple(of: 2) else {
            throw Failure.hex
        }
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: byte - 48
            case 65...70: byte - 55
            case 97...102: byte - 87
            default: nil
            }
        }
        var decoded = Data(capacity: hex.count / 2)
        for index in stride(from: 0, to: hex.count, by: 2) {
            guard let high = nibble(hex[index]), let low = nibble(hex[index + 1]) else { throw Failure.hex }
            decoded.append(high * 16 + low)
        }
        data = decoded
        password = command.arguments["password"] ?? "atakatak"
        server = command.arguments["server"]
    }

    enum Failure: Error { case syntax, hex }
}
