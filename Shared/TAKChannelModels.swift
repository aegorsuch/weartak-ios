import Foundation

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
