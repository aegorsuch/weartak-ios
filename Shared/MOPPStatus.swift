import Foundation

enum MOPPStatus: Int, CaseIterable, Identifiable {
    case none = -1
    case mopp0 = 0
    case mopp1 = 1
    case mopp2 = 2
    case mopp3 = 3
    case mopp4 = 4

    var id: Self { self }
    static let storageKey = "WearTAK.manualMOPPStatus"

    static func load(from defaults: UserDefaults) -> Self {
        guard let value = defaults.object(forKey: storageKey) as? Int else { return .none }
        return Self(rawValue: value) ?? .none
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }
}
