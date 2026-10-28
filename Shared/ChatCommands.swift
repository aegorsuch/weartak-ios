import Foundation

struct ChatCommand: Equatable {
    let name: String
    let arguments: [String: String]
    var positional: [String] = []
}

struct ServerEnrollmentCommand: Equatable {
    let name: String
    let url: String
    let port: Int

    init(_ command: ChatCommand) throws {
        guard command.name == "enrollserver", command.positional.isEmpty,
              Set(command.arguments.keys).isSubset(of: ["name", "url", "port"]),
              let name = command.arguments["name"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, name.utf8.count <= 128,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let address = command.arguments["url"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !address.isEmpty else { throw Failure.invalid }
        let port: Int
        if let value = command.arguments["port"] {
            guard let parsed = Int(value), (1...65535).contains(parsed) else { throw Failure.invalid }
            port = parsed
        } else {
            port = 8089
        }
        let input = address.contains("://") ? address : "https://" + address
        guard let components = URLComponents(string: input), components.scheme == "https",
              components.port == nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/", let host = components.host,
              !host.isEmpty, !host.contains(where: { $0.isWhitespace }) else {
            throw Failure.invalid
        }
        self.name = name
        url = host
        self.port = port
    }

    enum Failure: Error { case invalid }
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
    private static let namePattern = try! NSRegularExpression(pattern: "^[a-z][a-z0-9]{0,31}$")
    private static let keyPattern = try! NSRegularExpression(pattern: "^[a-z][a-z0-9]{0,15}$")

    static func parse(_ text: String) -> ChatCommandParse {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.lowercased().hasPrefix(prefix) else { return .notCommand }
        guard body.utf8.count <= maximumProvisioningLength else { return .malformed("too long") }

        let rest = Array(body.dropFirst(prefix.count).drop(while: { $0.isWhitespace }))
        let nameEnd = rest.firstIndex(where: \.isWhitespace) ?? rest.endIndex
        let name = String(rest[..<nameEnd]).lowercased()
        guard matches(namePattern, name) else { return .malformed("invalid command name") }
        let remainder = String(rest[nameEnd...].drop(while: \.isWhitespace))
        let namedEnrollment = ["name=", "url=", "port="].contains {
            remainder.lowercased().hasPrefix($0)
        }
        if name == "enrollserver", !namedEnrollment {
            // Comma syntax: the password is everything after the fourth comma, so it is not tokenized.
            guard remainder.utf8.count <= EnrollServerRequest.maximumLength else { return .malformed("too long") }
            return .parsed(ChatCommand(name: name, arguments: [:], positional: [remainder]))
        }
        let provisioning = name == "usep12" || name == "setpdl"
        let acceptsPositional = provisioning || name == "toggleditto"
        guard provisioning || body.utf8.count <= maximumLength else { return .malformed("too long") }

        var arguments: [String: String] = [:]
        var positional: [String] = []
        var index = nameEnd
        while true {
            while index < rest.endIndex, rest[index].isWhitespace { index += 1 }
            guard index < rest.endIndex else { break }
            // The credential is the first positional token, including base64 padding in a PDL.
            if acceptsPositional, positional.isEmpty {
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

enum ChatCommandAllowList {
    static func replacing(_ entries: [String], at index: Int, with candidate: String) -> [String] {
        guard entries.indices.contains(index) else { return entries }
        var updated = entries
        updated[index] = candidate
        return normalize(updated)
    }

    static func removing(_ entries: [String], at index: Int) -> [String] {
        guard entries.indices.contains(index) else { return entries }
        var updated = entries
        updated.remove(at: index)
        return normalize(updated)
    }

    private static func normalize(_ entries: [String]) -> [String] {
        ChatCommandAuthorizer.parseAllowList(entries.joined(separator: "\n"))
    }
}

enum AtomicRecordReplacement {
    enum Failure: Error { case readbackMismatch }

    /// `commit` runs after the readback; if it throws, the previous record is restored.
    static func apply<Value: Equatable>(_ candidate: Value,
        read: () throws -> Value?, write: (Value) throws -> Void, remove: () throws -> Void,
        commit: () throws -> Void = {}) throws {
        let previous = try read()
        try write(candidate)
        do {
            guard try read() == candidate else { throw Failure.readbackMismatch }
            try commit()
        } catch {
            if let previous { try write(previous) } else { try remove() }
            throw error
        }
    }
}

/// `enrollserver name,address,port,username,password`; the password is everything after the fourth comma.
struct EnrollServerRequest {
    static let maximumLength = 1_024
    let name: String
    let address: String
    let port: Int
    let username: String
    let password: String

    init(_ command: ChatCommand) throws {
        guard command.name == "enrollserver", command.arguments.isEmpty, command.positional.count == 1 else {
            throw Failure.syntax
        }
        let fields = command.positional[0].split(separator: ",", maxSplits: 4, omittingEmptySubsequences: false)
        guard fields.count == 5 else { throw Failure.syntax }
        func clean(_ value: Substring) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
        func printable(_ value: String) -> Bool {
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
        let name = clean(fields[0]), address = clean(fields[1]), username = clean(fields[3])
        let password = String(fields[4])
        guard !name.isEmpty, name.utf8.count <= 64, printable(name),
              !address.isEmpty, address.utf8.count <= 253, printable(address),
              !address.contains(where: \.isWhitespace),
              let port = Int(clean(fields[2])), (1...65535).contains(port),
              !username.isEmpty, username.utf8.count <= 128, !username.contains(":"), printable(username),
              !password.isEmpty, password.utf8.count <= 512, printable(password) else { throw Failure.syntax }
        self.name = name
        self.address = address
        self.port = port
        self.username = username
        self.password = password
    }

    enum Failure: Error { case syntax }
}

struct ChatP12Request {
    static let maximumBytes = 8_192
    let data: Data
    let password: String
    let server: UUID

    init(_ command: ChatCommand) throws {
        guard command.name == "usep12", command.positional.count == 1,
              Set(command.arguments.keys).isSubset(of: ["password", "server"]) else {
            throw Failure.syntax
        }
        guard let selector = command.arguments["server"], let server = UUID(uuidString: selector) else {
            throw Failure.server
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
        self.server = server
    }

    enum Failure: Error { case syntax, hex, server }
}
