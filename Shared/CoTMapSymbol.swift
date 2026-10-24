import Foundation

enum CoTCamera {
    static func recognizes(type: String, hasVideoDetail: Bool = false) -> Bool {
        type == "b-i-v" || hasVideoDetail
    }

    static func pickerGlyph(type: String, hasVideoDetail: Bool = false, isAlert: Bool = false,
                            isUser: Bool = false) -> String {
        if isAlert { return "exclamationmark.triangle.fill" }
        if recognizes(type: type, hasVideoDetail: hasVideoDetail) { return "video.fill" }
        return isUser ? "person.fill" : "mappin"
    }
}

enum CoTMapSymbol: String {
    case fixedWing = "airplane"
    case rotaryWing = "helicopter.fill"
    case uav = "paperplane.fill"
    case sea = "sailboat.fill"
    case vehicle = "car.fill"
    case medical = "cross.case.fill"
    case canine = "dog.fill"
    case weapon = "scope"
    case spi = "viewfinder"

    init?(cotType: String) {
        if cotType == "b-m-p-s-p-i" { self = .spi; return }
        let parts = cotType.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "a", parts[1].count == 1 else { return nil }
        let function = Array(parts.dropFirst(2))
        if function.starts(with: ["A", "M", "F", "Q"]) || function == ["A", "M"] { self = .uav }
        else if function.starts(with: ["A", "C", "F"]) { self = .fixedWing }
        else if function.starts(with: ["A", "C", "H"]) { self = .rotaryWing }
        else if function.starts(with: ["S"]) { self = .sea }
        else if function.starts(with: ["G", "U", "C", "I", "I"]) { self = .vehicle }
        else if function.starts(with: ["G", "U", "S", "M"]) { self = .medical }
        else if function.starts(with: ["G", "A"]) { self = .canine }
        else if function.starts(with: ["G", "E", "W"]) { self = .weapon }
        else { return nil }
    }
}
