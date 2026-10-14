import Foundation

enum WatchChatCommandOutcome {
    case notCommand
    case consumed
    case reply(String)
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

    func handle(_ message: TAKChatMessage, ownUID: String, settings: AppSettings,
                now: Date = Date()) -> WatchChatCommandOutcome {
        guard message.senderUID != ownUID, !message.isGroup else { return .notCommand }
        let parsed = ChatCommandParser.parse(message.text)
        guard parsed != .notCommand, settings.commandsEnabled else { return .notCommand }
        switch authorizer.authorize(senderUID: message.senderUID, allowedUIDs: settings.commandSenderUIDs,
            messageID: message.id, sentAt: message.sentAt, now: now) {
        case .allowed:
            break
        case .duplicate:
            return .consumed
        case .senderNotAllowed, .stale:
            return .notCommand
        }
        switch parsed {
        case .notCommand:
            return .notCommand
        case .malformed(let reason):
            return .reply("Command rejected: \(reason)")
        case .parsed(let command):
            return .reply(execute(command, settings: settings))
        }
    }

    private func execute(_ command: ChatCommand, settings: AppSettings) -> String {
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
