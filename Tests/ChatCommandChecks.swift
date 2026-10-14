import Foundation

@main
struct ChatCommandChecks {
    static func main() {
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
        print("PASS: command parsing, sender UID allow-list, freshness, and replay protection")
    }
}
