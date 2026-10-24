import Foundation

@main
struct ChatCommandChecks {
    static func main() throws {
        let parsed = ChatCommandParser.parse(
            #"#weartakcommandsetprofile callsign=ODIN-2 role="Team Member" height="5'10""#)
        guard case .parsed(let command) = parsed else { fatalError("Valid command was rejected") }
        precondition(command.name == "setprofile")
        precondition(command.arguments == ["callsign": "ODIN-2", "role": "Team Member", "height": "5'10"])
        precondition(ChatCommandParser.parse("ordinary chat") == .notCommand)
        for malformed in [
            "#weartakcommand", "#weartakcommandsetcallsign callsign",
            "#weartakcommandsetcallsign callsign=one callsign=two",
            #"#weartakcommandsetprofile role="unterminated"#
        ] {
            guard case .malformed = ChatCommandParser.parse(malformed) else {
                fatalError("Malformed command was accepted")
            }
        }
        var authorizer = ChatCommandAuthorizer()
        let now = Date(timeIntervalSince1970: 2_000)
        precondition(authorizer.authorize(senderUID: "trusted-uid", allowedUIDs: ["trusted-uid"],
            messageID: "1", sentAt: now, now: now) == .allowed)
        precondition(authorizer.authorize(senderUID: "trusted-uid", allowedUIDs: ["trusted-uid"],
            messageID: "1", sentAt: now, now: now) == .duplicate)
        precondition(authorizer.authorize(senderUID: "Trusted-uid", allowedUIDs: ["trusted-uid"],
            messageID: "2", sentAt: now, now: now) == .senderNotAllowed)
        precondition(authorizer.authorize(senderUID: "trusted-uid", allowedUIDs: ["trusted-uid"],
            messageID: "3", sentAt: now.addingTimeInterval(-301), now: now) == .stale)
        precondition(ChatCommandAuthorizer.parseAllowList(" one, two\none ,, three ") == ["one", "two", "three"])
        try checkProvisioning()
        try checkAtomicReplacement()
        var limited = ChatCommandAuthorizer(maximumRemembered: 1)
        precondition(limited.authorize(senderUID: "trusted", allowedUIDs: ["trusted"],
            messageID: "same-across-routes", sentAt: now, now: now) == .allowed)
        precondition(limited.authorize(senderUID: "trusted", allowedUIDs: ["trusted"],
            messageID: "second", sentAt: now, now: now) == .rateLimited)
        precondition(limited.authorize(senderUID: "trusted", allowedUIDs: ["trusted"],
            messageID: "same-across-routes", sentAt: now, now: now) == .duplicate)
        print("PASS: command parsing, sender UID allow-list, freshness, and replay protection")
    }

    static func checkProvisioning() throws {
        func parse(_ text: String) -> ChatCommand {
            guard case .parsed(let command) = ChatCommandParser.parse(text) else {
                fatalError("Provisioning syntax rejected")
            }
            return command
        }
        let bytes = String(repeating: "aB", count: 4_096)
        let server = UUID().uuidString
        let request = try ChatP12Request(parse("#weartakcommandusep12 \(bytes) server=\(server)"))
        precondition(request.data == Data(repeating: 0xab, count: 4_096))
        precondition(request.password == "atakatak" && request.server.uuidString == server)
        let overridden = try ChatP12Request(parse(
            "#weartakcommandusep12 00 password=\"fixture only\" server=\(server)"))
        precondition(overridden.password == "fixture only" && overridden.server.uuidString == server)
        let emptyPassword = try ChatP12Request(parse("#weartakcommandusep12 00 password=\"\" server=\(server)"))
        precondition(emptyPassword.password.isEmpty)
        let pdl = parse("#weartakcommandsetpdl Zml4dHVyZQ==")
        precondition(pdl.positional == ["Zml4dHVyZQ=="] && pdl.arguments.isEmpty)
        for hex in ["", "a", "xz", "0x00", "００", String(repeating: "00", count: 8_193)] {
            do {
                _ = try ChatP12Request(ChatCommand(name: "usep12", arguments: ["server": server], positional: [hex]))
                fatalError("Invalid hex accepted")
            } catch ChatP12Request.Failure.hex {}
        }
        for args in [["url": "https://example.invalid"], ["extra": "no"]] {
            do {
                _ = try ChatP12Request(ChatCommand(name: "usep12", arguments: args, positional: ["00"]))
                fatalError("Unknown argument accepted")
            } catch ChatP12Request.Failure.syntax {}
        }
        for args in [[:], ["server": "not-configured-uuid"]] {
            do {
                _ = try ChatP12Request(ChatCommand(name: "usep12", arguments: args, positional: ["00"]))
                fatalError("Missing or malformed server ID accepted")
            } catch ChatP12Request.Failure.server {}
        }
        for text in [
            "#weartakcommandusep12 00 password=a password=b",
            "#weartakcommandsetpdl " + String(repeating: "x", count: 24_000),
            "#weartakcommandsetcallsign callsign=" + String(repeating: "x", count: 769)
        ] {
            guard case .malformed = ChatCommandParser.parse(text) else { fatalError("Oversize or duplicate accepted") }
        }
    }

    static func checkAtomicReplacement() throws {
        enum Fault: Error { case write, rollback }
        var record: String? = "old"
        try AtomicRecordReplacement.apply("new", read: { record }, write: { record = $0 }, remove: { record = nil })
        precondition(record == "new")
        record = "old"
        do {
            try AtomicRecordReplacement.apply("new", read: { record },
                write: { _ in throw Fault.write }, remove: { record = nil })
            fatalError("Write failure accepted")
        } catch Fault.write {}
        precondition(record == "old")
        for previous in ["old" as String?, nil] {
            record = previous
            var reads = 0
            do {
                try AtomicRecordReplacement.apply("new", read: {
                    reads += 1
                    return reads == 2 ? "bad readback" : record
                }, write: { record = $0 }, remove: { record = nil })
                fatalError("Readback mismatch accepted")
            } catch AtomicRecordReplacement.Failure.readbackMismatch {}
            precondition(record == previous)
        }
        record = "old"
        var reads = 0
        do {
            try AtomicRecordReplacement.apply("new", read: {
                reads += 1
                return reads == 2 ? nil : record
            }, write: {
                if $0 == "old" { throw Fault.rollback }
                record = $0
            }, remove: { record = nil })
            fatalError("Rollback failure hidden")
        } catch Fault.rollback {}
    }
}
