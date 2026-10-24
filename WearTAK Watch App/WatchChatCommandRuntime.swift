import Foundation

enum WatchChatCommandOutcome: Equatable {
    case notCommand
    case consumed
    case reply(String)
    case phoneProvisioning
    case setDittoEnabled(Bool)
}

@MainActor
final class WatchChatCommandRuntime {
    private enum Change {
        case callSign(String)
        case team(TeamColor)
        case role(UserRoleGroup, String)
        case height(Int)
        case weight(Int)
        case birthYear(Int)
        case sex(String)
        case userType(String)
        case pants(Int)
        case waist(Int)

        var key: String {
            switch self {
            case .callSign: "callsign"
            case .team: "team"
            case .role: "role"
            case .height: "height"
            case .weight: "weight"
            case .birthYear: "birthyear"
            case .sex: "sex"
            case .userType: "usertype"
            case .pants: "pants"
            case .waist: "waist"
            }
        }

        @MainActor
        func apply(to settings: AppSettings) {
            switch self {
            case .callSign(let value): settings.callSign = value
            case .team(let value): settings.teamColor = value
            case .role(let group, let value):
                settings.roleGroup = group
                settings.role = value
            case .height(let value): settings.heightInches = value
            case .weight(let value): settings.weightPounds = value
            case .birthYear(let value): settings.birthYear = value
            case .sex(let value): settings.sex = value
            case .userType(let value): settings.userType = value
            case .pants(let value): settings.uniformPantsLength = value
            case .waist(let value): settings.uniformWaistSize = value
            }
        }
    }

    private var authorizer = ChatCommandAuthorizer()
    private let defaults: UserDefaults
    private let replayKey = "WearTAK.chatCommandReceipts"
    private var replayStorageFailed = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.object(forKey: replayKey) {
            do {
                guard let data = stored as? Data else { throw ChatP12Request.Failure.syntax }
                authorizer = try JSONDecoder().decode(ChatCommandAuthorizer.self, from: data)
            } catch {
                replayStorageFailed = true
            }
        }
    }

    func handle(_ message: TAKChatMessage, ownUID: String, settings: AppSettings,
                now: Date = Date()) -> WatchChatCommandOutcome {
        let parsed = ChatCommandParser.parse(message.text)
        let sensitive = TAKChatMessage.isProvisioningCommand(message.text)
        guard message.senderUID != ownUID, !message.isGroup, settings.commandsEnabled else {
            return sensitive ? .consumed : .notCommand
        }
        guard parsed != .notCommand else { return .notCommand }
        switch authorizer.authorize(senderUID: message.senderUID, allowedUIDs: settings.commandSenderUIDs,
            messageID: message.id, sentAt: message.sentAt, now: now) {
        case .allowed:
            guard !replayStorageFailed else { return .reply("Commands unavailable: replay storage could not be read.") }
            do {
                defaults.set(try JSONEncoder().encode(authorizer), forKey: replayKey)
            } catch {
                replayStorageFailed = true
                return .reply("Commands unavailable: replay storage could not be saved.")
            }
        case .duplicate:
            return .consumed
        case .rateLimited:
            return .reply("Command rejected: rate limit. Retry after five minutes.")
        case .senderNotAllowed, .stale:
            return sensitive ? .consumed : .notCommand
        }
        switch parsed {
        case .notCommand:
            return .notCommand
        case .malformed(let reason):
            return .reply("Command rejected: \(reason)")
        case .parsed(let command):
            if command.name == "toggleditto" {
                guard !settings.networkPreferencesLocked else { return .reply("Command rejected: network settings are locked.") }
                guard command.arguments.isEmpty, command.positional.count == 1,
                      ["on", "off"].contains(command.positional[0]) else {
                    return .reply("Use toggleditto on or toggleditto off; nothing changed.")
                }
                return .setDittoEnabled(command.positional[0] == "on")
            }
            if command.name == "usep12" {
                guard !settings.networkPreferencesLocked else { return .reply("Command rejected: network settings are locked.") }
                do { _ = try ChatP12Request(command) }
                catch ChatP12Request.Failure.server {
                    return .reply("Command rejected: server=<configured-server-UUID> is required; nothing changed.")
                }
                catch { return .reply("Command rejected: invalid P12 command.") }
                return .phoneProvisioning
            }
            return .reply(execute(command, settings: settings))
        }
    }

    private func execute(_ command: ChatCommand, settings: AppSettings) -> String {
        if command.name == "setpdl" {
            guard !settings.networkPreferencesLocked else { return "Command rejected: network settings are locked." }
            guard command.positional.count == 1, command.arguments.isEmpty else {
                return "Use setpdl <pdl>."
            }
            do {
                try settings.storeDittoCustomPDL(command.positional[0])
                settings.dittoIdentitySource = .custom
                return "Custom Ditto identity updated."
            } catch {
                return "Command rejected: invalid identity or secure storage unavailable."
            }
        }
        if command.name == "enrollserver" || command.name == "loadprofile" {
            return "\(command.name) is not supported in WearTAK for iOS."
        }

        let keysByCommand: [String: Set<String>] = [
            "setcallsign": ["callsign"], "setteam": ["team"], "setrole": ["role"],
            "setheight": ["height"], "setweight": ["weight"], "setbirthyear": ["birthyear"],
            "setsex": ["sex"], "setusertype": ["usertype"], "setpants": ["pants"],
            "setwaist": ["waist"]
        ]
        let allowedKeys = command.name == "setprofile"
            ? Set(keysByCommand.values.flatMap { $0 })
            : keysByCommand[command.name]
        guard let allowedKeys else { return "Unknown command: \(command.name)" }
        guard !command.arguments.isEmpty else {
            return "\(command.name) needs \(allowedKeys.sorted().joined(separator: ", "))=<value>."
        }
        let suppliedKeys = Set(command.arguments.keys)
        guard suppliedKeys.isSubset(of: allowedKeys) else {
            return "\(command.name) does not accept \(suppliedKeys.subtracting(allowedKeys).sorted().joined(separator: ", "))."
        }

        var changes: [Change] = []
        for key in command.arguments.keys.sorted() {
            guard let value = command.arguments[key], let change = parse(key: key, value: value) else {
                return "Invalid \(key); nothing changed."
            }
            changes.append(change)
        }
        changes.forEach { $0.apply(to: settings) }
        return "Updated \(changes.map(\.key).joined(separator: ", "))."
    }

    private func parse(key: String, value: String) -> Change? {
        switch key {
        case "callsign":
            guard value.range(of: #"^[A-Za-z0-9][A-Za-z0-9 _.\-]{0,31}$"#, options: .regularExpression) != nil else {
                return nil
            }
            return .callSign(value.trimmingCharacters(in: .whitespacesAndNewlines))
        case "team":
            return TeamColor.allCases.first { $0.rawValue.caseInsensitiveCompare(value) == .orderedSame }
                .map(Change.team)
        case "role":
            for group in UserRoleGroup.allCases {
                if let role = group.roles.first(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
                    return .role(group, role)
                }
            }
            return nil
        case "height":
            guard let match = value.range(of: #"^([1-8])\s*['-]\s*(\d{1,2})"?$"#,
                                          options: .regularExpression) else { return nil }
            let captures = String(value[match])
            guard let feet = captures.first?.wholeNumberValue,
                  let inchesText = captures.split(whereSeparator: { !$0.isNumber }).last,
                  let inches = Int(inchesText), inches < 12 else { return nil }
            let total = feet * 12 + inches
            return (48...84).contains(total) ? .height(total) : nil
        case "weight":
            return integer(value, range: 80...320).map(Change.weight)
        case "birthyear":
            return integer(value, range: 1920...Calendar.current.component(.year, from: Date())).map(Change.birthYear)
        case "sex":
            return AppSettings.sexOptions.first { $0.caseInsensitiveCompare(value) == .orderedSame }.map(Change.sex)
        case "usertype":
            return AppSettings.userTypeOptions.first { $0.caseInsensitiveCompare(value) == .orderedSame }.map(Change.userType)
        case "pants":
            return integer(value, range: 24...60).map(Change.pants)
        case "waist":
            return integer(value, range: 24...60).map(Change.waist)
        default:
            return nil
        }
    }

    private func integer(_ value: String, range: ClosedRange<Int>) -> Int? {
        guard let number = Int(value), range.contains(number) else { return nil }
        return number
    }
}
