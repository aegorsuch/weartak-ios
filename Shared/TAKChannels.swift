import Foundation
import CoreFoundation

struct TAKChannel: Codable, Identifiable, Equatable {
    let bitPosition: Int
    let name: String
    let direction: String
    let active: Bool
    var id: Int { bitPosition }
}

struct TAKChannelServer: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    var channels: [TAKChannel] = []
    var state = "Select server to load channels"
    var error: String?
}

struct TAKChannelGroups {
    var payload: [[String: Any]]

    var channels: [TAKChannel] {
        var seen: Set<Int> = []
        return payload.compactMap { group in
            guard let number = group["bitpos"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0,
                  number.doubleValue <= Double(Int32.max), number.doubleValue.rounded() == number.doubleValue,
                  let name = group["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(number.intValue).inserted else { return nil }
            return TAKChannel(bitPosition: number.intValue, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                direction: group["direction"] as? String ?? "", active: group["active"] as? Bool ?? false)
        }
    }

    static func parse(_ data: Data) throws -> Self {
        guard data.count <= 1_048_576,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = root["data"] as? [[String: Any]] else {
            throw ChannelError.invalidResponse
        }
        return Self(payload: groups)
    }

    func changing(bitPosition: Int, active: Bool) throws -> Self {
        guard channels.contains(where: { $0.bitPosition == bitPosition }) else { throw ChannelError.unknownChannel }
        var updated = payload
        for index in updated.indices {
            if let number = updated[index]["bitpos"] as? NSNumber,
               CFGetTypeID(number) != CFBooleanGetTypeID(), number.intValue == bitPosition {
                updated[index]["active"] = active
            }
        }
        return Self(payload: updated)
    }

    func encodedPayload() throws -> Data { try JSONSerialization.data(withJSONObject: payload) }

    static func support(_ data: Data) throws -> Bool {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = root["data"] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw ChannelError.invalidResponse
        }
        return number.boolValue
    }

    enum ChannelError: LocalizedError {
        case invalidResponse, unknownChannel, unsupported
        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Invalid channel response from TAK server."
            case .unknownChannel: return "This channel is no longer available; refresh the list."
            case .unsupported: return "Channels unsupported by this TAK server."
            }
        }
    }
}