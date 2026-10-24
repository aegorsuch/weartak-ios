import Foundation

struct ManualAlertType: RawRepresentable, Equatable, Hashable, Identifiable, CaseIterable {
    let rawValue: String
    var id: String { rawValue }

    init?(rawValue: String) {
        let text = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 128,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        self.rawValue = text
    }

    private init(_ preset: String) { rawValue = preset }
    fileprivate init(storedValue: String) { rawValue = storedValue }
    static let alert911 = Self("911 Alert")
    static let gateRunner = Self("Gate Runner")
    static let geofenceBreached = Self("Geofence Breached")
    static let gunshot = Self("Gunshot")
    static let gunshotInjury = Self("Gunshot Injury")
    static let inContact = Self("In Contact")
    static let injury = Self("Injury")
    static let ringTheBell = Self("Ring The Bell")
    static let uas = Self("UAS")
    static let vehicle = Self("Vehicle")
    static let allCases: [Self] = [
        .alert911, .gateRunner, .geofenceBreached, .gunshot,
        .inContact, .injury, .ringTheBell, .uas, .vehicle,
    ]

    static func pickerTypes(custom: [Self], label: (Self) -> String = { $0.rawValue }) -> [Self] {
        (allCases + custom).sorted {
            label($0).localizedStandardCompare(label($1)) == .orderedAscending
        }
    }

    var cotType: String {
        switch self {
        case .alert911: return "b-a-o-tbl"
        case .ringTheBell: return "b-a-o-pan"
        case .geofenceBreached: return "b-a-g"
        case .inContact: return "b-a-o-opn"
        default: return "b-a-o"
        }
    }
    var emergencyName: String { self == .geofenceBreached ? "Geo-fence Breached" : rawValue }
    static let cancelCoTType = "b-a-o-can"
    static let priority = 1
}

struct SavedManualAlerts {
    static let storageKey = "WearTAK.savedManualAlerts"
    static let maximumCount = 20
    static let maximumUTF16Length = 60
    private(set) var types: [ManualAlertType]

    enum Failure: LocalizedError {
        case invalidText, duplicate, full, unreadable
        var errorDescription: String? {
            switch self {
            case .invalidText: return String(localized: "Enter a single-line alert of 1 to 60 UTF-16 characters, without tabs or control characters.")
            case .duplicate: return String(localized: "That alert already exists.")
            case .full: return String(localized: "You can save up to 20 custom alerts. Delete one before adding another.")
            case .unreadable: return String(localized: "Saved alerts could not be loaded. Existing data has not been overwritten.")
            }
        }
    }

    init(defaults: UserDefaults) throws {
        guard let stored = defaults.object(forKey: Self.storageKey) else { types = []; return }
        guard let names = stored as? [String] else { throw Failure.unreadable }
        types = names.map { ManualAlertType(storedValue: $0) }
    }

    @discardableResult
    mutating func add(_ text: String, defaults: UserDefaults) throws -> ManualAlertType {
        let normalized = try Self.normalized(text)
        let type = ManualAlertType(storedValue: normalized)
        guard !contains(type) else { throw Failure.duplicate }
        guard types.count < Self.maximumCount else { throw Failure.full }
        types.append(type)
        defaults.set(types.map(\.rawValue), forKey: Self.storageKey)
        return type
    }

    mutating func remove(_ type: ManualAlertType, defaults: UserDefaults) {
        types.removeAll { $0 == type }
        defaults.set(types.map(\.rawValue), forKey: Self.storageKey)
    }

    private func contains(_ type: ManualAlertType) -> Bool {
        (ManualAlertType.allCases + types).contains {
            let existing = (try? Self.normalized($0.rawValue)) ?? $0.rawValue
            return existing.caseInsensitiveCompare(type.rawValue) == .orderedSame
        }
    }

    static func normalized(_ text: String) throws -> String {
        guard !text.unicodeScalars.contains(where: { $0.value <= 0x1f || (0x7f...0x9f).contains($0.value) }) else {
            throw Failure.invalidText
        }
        let value = text.unicodeScalars.split(whereSeparator: { $0.properties.isWhitespace })
            .map(String.init).joined(separator: " ")
        guard !value.isEmpty, value.utf16.count <= maximumUTF16Length else { throw Failure.invalidText }
        return value
    }
}

/// One durable start/cancel intent per user action; GPS fixes never create another manual start.
struct ManualAlertSession {
    private(set) var active: ManualAlertType?

    init(active: ManualAlertType? = nil) { self.active = active }

    @discardableResult
    mutating func start(_ type: ManualAlertType, enqueue: (ManualAlertType) -> Bool) -> Bool {
        guard active == nil, enqueue(type) else { return false }
        active = type
        return true
    }

    @discardableResult
    mutating func cancel(enqueue: (ManualAlertType) -> Bool) -> Bool {
        guard let active, enqueue(active) else { return false }
        self.active = nil
        return true
    }
}
