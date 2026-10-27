import Foundation

@main
struct ChatCommandChecks {
    static func main() throws {
        let parsed = ChatCommandParser.parse(
            #"#weartakcommandsetprofile callsign=ODIN-2 role="Team Member" height="5'10""#)
        guard case .parsed(let command) = parsed else { fatalError("Valid command was rejected") }
        precondition(command.name == "setprofile")
        precondition(command.arguments == ["callsign": "ODIN-2", "role": "Team Member", "height": "5'10"])
        for name in ["enabletakservers", "disabletakservers", "enablemulticast", "disablemulticast"] {
            guard case .parsed(let networkCommand) = ChatCommandParser.parse("#weartakcommand \(name)") else {
                fatalError("Network command with the documented prefix form was rejected")
            }
            precondition(networkCommand.name == name && networkCommand.arguments.isEmpty)
        }
        guard case .parsed(let enrollment) = ChatCommandParser.parse(
            #"#weartakcommand enrollserver name="Operations Team" url=tak.example"#) else {
            fatalError("Valid server enrollment command was rejected")
        }
        let enrollmentRequest = try ServerEnrollmentCommand(enrollment)
        precondition(enrollmentRequest.name == "Operations Team" && enrollmentRequest.url == "tak.example" &&
            enrollmentRequest.port == 8089)
        guard case .parsed(let customPortCommand) = ChatCommandParser.parse(
            "#weartakcommand enrollserver name=North url=https://tak.example port=8443") else {
            fatalError("Server enrollment command with port was rejected")
        }
        let customPortRequest = try ServerEnrollmentCommand(customPortCommand)
        precondition(customPortRequest.port == 8443)
        for invalidText in [
            "#weartakcommand enrollserver name= url=tak.example",
            "#weartakcommand enrollserver name=Ops url=tak.example port=0",
            "#weartakcommand enrollserver name=Ops url=https://user:pass@tak.example",
            "#weartakcommand enrollserver name=Ops url=tak.example:8446",
            "#weartakcommand enrollserver name=Ops url=tak.example password=\"\"",
            "#weartakcommand enrollserver Ops"
        ] {
            let parsed = ChatCommandParser.parse(invalidText)
            if case .malformed = parsed { continue }
            guard case .parsed(let invalidCommand) = parsed else {
                fatalError("Server enrollment command was not recognized")
            }
            do {
                _ = try ServerEnrollmentCommand(invalidCommand)
                fatalError("Invalid server enrollment command accepted")
            } catch ServerEnrollmentCommand.Failure.invalid {}
        }
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
        try checkEnrollServer()
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

    static func checkEnrollServer() throws {
        func request(_ text: String) throws -> EnrollServerRequest {
            guard case .parsed(let command) = ChatCommandParser.parse(text) else { throw EnrollServerRequest.Failure.syntax }
            return try EnrollServerRequest(command)
        }
        let valid = try request("#weartakcommandenrollserver Training, tak.example.gov ,8089, alice ,pa,ss word,=\"x\"")
        precondition(valid.name == "Training" && valid.address == "tak.example.gov" && valid.port == 8089)
        precondition(valid.username == "alice" && valid.password == "pa,ss word,=\"x\"")
        let uppercase = try request("#WEARTAKCOMMANDENROLLSERVER a,b,1,u,p")
        precondition(uppercase.password == "p")
        let spaced = try request("#weartakcommand enrollserver a,b,8089,u,p,a=1")
        precondition(spaced.password == "p,a=1")
        for text in [
            "#weartakcommandenrollserver a,b,8089,u", "#weartakcommandenrollserver a,b,0,u,p",
            "#weartakcommandenrollserver a,b,65536,u,p", "#weartakcommandenrollserver a,b,x,u,p",
            "#weartakcommandenrollserver ,b,8089,u,p", "#weartakcommandenrollserver a,,8089,u,p",
            "#weartakcommandenrollserver a,b,8089,,p", "#weartakcommandenrollserver a,b,8089,u:v,p",
            "#weartakcommandenrollserver a,b c,8089,u,p", "#weartakcommandenrollserver a,b,8089,u,",
            "#weartakcommandenrollserver a,b,8089,u," + String(repeating: "x", count: 513),
            "#weartakcommandenrollserver a,b,8089,u,p\u{7}q"
        ] {
            do { _ = try request(text); fatalError("Invalid enrollserver accepted") }
            catch EnrollServerRequest.Failure.syntax {}
        }
        guard case .malformed = ChatCommandParser.parse("#weartakcommandenrollserver " + String(repeating: "x", count: 1_100)) else {
            fatalError("Oversize enrollserver accepted")
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
        // A failed server-record commit must restore the previous certificate; success keeps the new one.
        for previous in ["old" as String?, nil] {
            record = previous
            do {
                try AtomicRecordReplacement.apply("new", read: { record }, write: { record = $0 },
                    remove: { record = nil }, commit: { throw Fault.write })
                fatalError("Commit failure accepted")
            } catch Fault.write {}
            precondition(record == previous)
        }
        record = "old"
        var committed = false
        try AtomicRecordReplacement.apply("new", read: { record }, write: { record = $0 },
            remove: { record = nil }, commit: { committed = true })
        precondition(record == "new" && committed)
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
