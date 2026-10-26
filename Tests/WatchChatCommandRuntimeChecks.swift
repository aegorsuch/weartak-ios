import Foundation

enum TeamColor: String, CaseIterable { case blue = "Blue" }
enum UserRoleGroup: CaseIterable {
    case standard
    var roles: [String] { ["Team Member"] }
}

@MainActor
final class AppSettings {
    static let sexOptions = ["N/A"]
    static let userTypeOptions = ["N/A"]
    var commandsEnabled = true
    var commandSenderUIDs = ["authorized"]
    var networkPreferencesLocked = false
    var multicastEnabled = true
    var callSign = "Original"
    var teamColor = TeamColor.blue
    var roleGroup = UserRoleGroup.standard
    var role = "Team Member"
    var heightInches = 70
    var weightPounds = 160
    var birthYear = 1990
    var sex = "N/A"
    var userType = "N/A"
    var uniformPantsLength = 32
    var uniformWaistSize = 32
    var dittoIdentitySource = DittoIdentitySource.community
    var storedPDL: String?

    func storeDittoCustomPDL(_ value: String) throws {
        guard value == "fixture==" else { throw ChatP12Request.Failure.syntax }
        storedPDL = value
    }
}

@main
struct WatchChatCommandRuntimeChecks {
    @MainActor
    static func main() {
        let suite = "WatchCommandChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let runtime = WatchChatCommandRuntime(defaults: defaults)
        let settings = AppSettings()
        let now = Date()
        func message(_ text: String, id: String = UUID().uuidString, sender: String = "authorized",
                     group: Bool = false, sentAt: Date? = nil) -> TAKChatMessage {
            TAKChatMessage(id: id, senderUID: sender, recipientUID: "watch", senderCallSign: "Sender",
                text: text, sentAt: sentAt ?? now, isGroup: group)
        }
        let credential = "#weartakcommandusep12 " + String(repeating: "ab", count: 4_096) +
            " server=\(UUID().uuidString)"
        let first = message(credential, id: "one-command-many-routes")
        precondition(runtime.handle(first, ownUID: "watch", settings: settings, now: now) == .phoneProvisioning)
        precondition(runtime.handle(first, ownUID: "watch", settings: settings, now: now) == .consumed)
        let restarted = WatchChatCommandRuntime(defaults: defaults)
        precondition(restarted.handle(first, ownUID: "watch", settings: settings, now: now) == .consumed)
        for rejected in [
            message(credential, sender: "untrusted"),
            message(credential, group: true),
            message(credential, sender: "watch"),
            message(credential, sentAt: now.addingTimeInterval(-301))
        ] {
            precondition(runtime.handle(rejected, ownUID: "watch", settings: settings, now: now) == .consumed)
        }
        settings.commandsEnabled = false
        precondition(runtime.handle(message(credential), ownUID: "watch", settings: settings, now: now) == .consumed)
        settings.commandsEnabled = true
        settings.networkPreferencesLocked = true
        guard case .reply(let locked) = runtime.handle(message(credential), ownUID: "watch", settings: settings, now: now)
        else { fatalError("Locked credential command accepted") }
        precondition(!locked.contains("abab"))
        settings.networkPreferencesLocked = false
        let enroll = "#weartakcommandenrollserver Training,tak.example.gov,8089,alice,s3cret,pw"
        precondition(TAKChatMessage.isProvisioningCommand(enroll) && TAKChatMessage.isEnrollServerCommand(enroll))
        precondition(!TAKChatMessage.isEnrollServerCommand(credential))
        precondition(runtime.handle(message(enroll, group: true), ownUID: "watch", settings: settings, now: now) == .phoneProvisioning)
        // A phone-relayed event keeps the original sender, so the allowlist applies to the real sender.
        func relayed(sender: String) -> TAKChatMessage {
            let xml = try! TAKChatMessage.outgoing(senderUID: sender, senderCallSign: "Operator", recipientUID: "watch",
                recipientCallSign: "Watch", text: enroll, now: now, messageID: UUID().uuidString)
            return TAKChatMessage.parse(xml, ownUID: "watch")!
        }
        precondition(runtime.handle(relayed(sender: "authorized"), ownUID: "watch", settings: settings, now: now) == .phoneProvisioning)
        precondition(runtime.handle(relayed(sender: "phone-uid"), ownUID: "watch", settings: settings, now: now) == .consumed)
        precondition(runtime.handle(message(enroll, sender: "untrusted", group: true), ownUID: "watch",
            settings: settings, now: now) == .consumed)
        precondition(runtime.handle(message(enroll, sender: "watch", group: true), ownUID: "watch",
            settings: settings, now: now) == .consumed)
        precondition(runtime.handle(message(credential, group: true), ownUID: "watch", settings: settings, now: now) == .consumed)
        settings.networkPreferencesLocked = true
        guard case .reply(let enrollLocked) = runtime.handle(message(enroll), ownUID: "watch", settings: settings, now: now)
        else { fatalError("Locked enrollserver accepted") }
        precondition(enrollLocked == "Command rejected: network settings are locked." && !enrollLocked.contains("s3cret"))
        settings.networkPreferencesLocked = false
        guard case .reply(let badEnroll) = runtime.handle(
            message("#weartakcommandenrollserver Training,tak.example.gov,nope,alice,s3cret"),
            ownUID: "watch", settings: settings, now: now) else { fatalError("Malformed enrollserver accepted") }
        precondition(!badEnroll.contains("s3cret") && !badEnroll.contains("alice"))
        settings.commandsEnabled = false
        precondition(runtime.handle(message(enroll), ownUID: "watch", settings: settings, now: now) == .consumed)
        settings.commandsEnabled = true
        let missingServer = message("#weartakcommandusep12 00")
        precondition(runtime.handle(missingServer, ownUID: "watch", settings: settings, now: now) ==
            .reply("Command rejected: server=<configured-server-UUID> is required; nothing changed."))
        let invalid = message("#weartakcommandusep12 private-fixture server=\(UUID().uuidString)")
        guard case .reply(let rejected) = runtime.handle(invalid, ownUID: "watch", settings: settings, now: now)
        else { fatalError("Invalid credential accepted") }
        precondition(!rejected.contains("private-fixture"))
        precondition(runtime.handle(message("#weartakcommandsetpdl fixture=="), ownUID: "watch",
            settings: settings, now: now) == .reply("Custom Ditto identity updated."))
        precondition(settings.storedPDL == "fixture==" && settings.dittoIdentitySource == .custom)
        precondition(runtime.handle(message("#weartakcommandsetcallsign callsign=Updated"), ownUID: "watch",
            settings: settings, now: now) == .reply("Updated callsign."))
        precondition(settings.callSign == "Updated")
        for (argument, enabled) in [("on", true), ("off", false)] {
            let request = message("#weartakcommandtoggleditto \(argument)")
            precondition(runtime.handle(request, ownUID: "watch", settings: settings, now: now) == .setDittoEnabled(enabled))
            precondition(runtime.handle(request, ownUID: "watch", settings: settings, now: now) == .consumed)
            precondition(runtime.handle(message("#weartakcommandtoggleditto \(argument)"),
                ownUID: "watch", settings: settings, now: now) == .setDittoEnabled(enabled))
            precondition(settings.dittoIdentitySource == .custom && settings.storedPDL == "fixture==")
        }
        for arguments in ["", "toggle", "ON", "on extra=yes", "off on"] {
            guard case .reply = runtime.handle(message("#weartakcommandtoggleditto \(arguments)"),
                ownUID: "watch", settings: settings, now: now) else { fatalError("Invalid Ditto state accepted") }
        }
        for (name, enabled) in [("enablemulticast", true), ("disablemulticast", false)] {
            precondition(runtime.handle(message("#weartakcommand \(name)"),
                ownUID: "watch", settings: settings, now: now) == .setMulticastEnabled(enabled))
            for arguments in ["on", "enabled=true"] {
                guard case .reply = runtime.handle(message("#weartakcommand \(name) \(arguments)"),
                    ownUID: "watch", settings: settings, now: now) else {
                    fatalError("Network command arguments must be rejected")
                }
            }
        }
        for (name, enabled) in [("enabletakservers", true), ("disabletakservers", false)] {
            precondition(runtime.handle(message("#weartakcommand \(name)"),
                ownUID: "watch", settings: settings, now: now) == .setPhoneTakServersEnabled(enabled))
            guard case .reply = runtime.handle(message("#weartakcommand \(name) on"),
                ownUID: "watch", settings: settings, now: now) else {
                fatalError("TAK server command arguments must be rejected")
            }
        }
        let enrollServer = message("#weartakcommand enrollserver name=North url=tak.example port=8443")
        guard case .phoneServerEnrollment(let enrollment) = runtime.handle(
            enrollServer, ownUID: "watch", settings: settings, now: now) else {
            fatalError("Authorized server enrollment command was not forwarded to Companion")
        }
        precondition(enrollment.name == "North" && enrollment.url == "tak.example" && enrollment.port == 8443)
        guard case .reply = runtime.handle(
            message("#weartakcommand enrollserver name=North url=tak.example password=\"\""),
            ownUID: "watch", settings: settings, now: now) else {
            fatalError("Server enrollment must reject credential arguments")
        }
        precondition(runtime.handle(message("#weartakcommand enrollserver name=North url=tak.example",
            sender: "untrusted"), ownUID: "watch", settings: settings, now: now) == .consumed)
        settings.networkPreferencesLocked = true
        guard case .reply = runtime.handle(message("#weartakcommandtoggleditto on"),
            ownUID: "watch", settings: settings, now: now) else { fatalError("Locked Ditto mutation accepted") }
        for name in ["enablemulticast", "disablemulticast", "enabletakservers", "disabletakservers"] {
            guard case .reply(let reason) = runtime.handle(message("#weartakcommand \(name)"),
                ownUID: "watch", settings: settings, now: now), reason.contains("network settings are locked") else {
                fatalError("Network command must respect the admin network lock")
            }
        }
        guard case .reply(let enrollmentLock) = runtime.handle(
            message("#weartakcommand enrollserver name=North url=tak.example"),
            ownUID: "watch", settings: settings, now: now) else {
            fatalError("Server enrollment must respect the network lock")
        }
        precondition(enrollmentLock.contains("network settings are locked"))
        print("PASS: direct-only command authorization (enrollserver any channel), cross-route dedup, credential redaction, locks and positional PDL")
    }
}
