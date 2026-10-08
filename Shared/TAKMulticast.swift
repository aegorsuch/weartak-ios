import Foundation

#if canImport(FoundationXML)
    import FoundationXML
#endif

struct TAKMulticastEndpoint: Hashable {
    let address: String
    let port: Int
}
enum TAKMulticast {
    static let chat = TAKMulticastEndpoint(address: "224.10.10.1", port: 17012)
    static let directCoT = TAKMulticastEndpoint(address: "224.10.10.1", port: 6969)

    static func receiveEndpoints(address: String, port: Int) -> [TAKMulticastEndpoint] {
        var endpoints: [TAKMulticastEndpoint] = []
        for endpoint in [TAKMulticastEndpoint(address: address, port: port), chat, directCoT] {
            if !endpoints.contains(endpoint) { endpoints.append(endpoint) }
        }
        return endpoints
    }

    static func outbound(_ xml: String, address: String, port: Int) -> (String, TAKMulticastEndpoint) {
        let metadata = MulticastXMLMetadata(xml)
        if metadata.type == "b-t-f" { return (xml, chat) }
        guard metadata.isUser else { return (xml, TAKMulticastEndpoint(address: address, port: port)) }
        let contact = #"<contact\b[^>]*>"#
        let endpoint = #"\bendpoint\s*=\s*(['"])[^'"]*\1"#
        // Only contact tags in the multicast copy change; server copies keep STCP.
        var result = ""
        var remaining = xml[...]
        while let range = remaining.range(of: contact, options: .regularExpression) {
            result += remaining[..<range.lowerBound]
            let tag = String(remaining[range]).replacingOccurrences(
                of: endpoint,
                with: "endpoint=\"224.10.10.1:17012:udp\"", options: .regularExpression)
            result += tag
            remaining = remaining[range.upperBound...]
        }
        result += remaining
        return (result, TAKMulticastEndpoint(address: address, port: port))
    }
}
private final class MulticastXMLMetadata: NSObject, XMLParserDelegate {
    var type: String?
    var isUser = false
    private var depth = 0

    init(_ xml: String) {
        super.init()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        if !parser.parse() || parser.parserError != nil {
            type = nil
            isUser = false
        }
    }

    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String]
    ) {
        depth += 1
        if depth == 1, name == "event" {
            type = attributes["type"]
            isUser =
                type?.hasPrefix("a-") == true
                && type?.split(separator: "-").dropFirst(2).starts(with: ["G", "U", "C"]) == true
        }
        if depth == 3, type?.hasPrefix("a-") == true {
            if name == "__group" || name == "takv" && attributes["device"] != "Map Marker"
                || name == "contact" && attributes["endpoint"] != nil || name == "uid" && attributes["Droid"] != nil
            {
                isUser = true
            }
        }
        if depth == 3, name == "emergency" {
            isUser = false
            hasEmergency = true
        }
        if hasEmergency { isUser = false }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        depth -= 1
    }
    private var hasEmergency = false
}
enum TAKDatagramDecoder {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self {
            case .invalid(let reason): return "Rejected TAK datagram: \(reason)"
            }
        }
    }

    static func decode(_ data: Data) throws -> String? {
        let bytes = Array(data)
        guard !bytes.isEmpty else { throw Failure.invalid("empty packet") }
        guard bytes.count <= 65_507 else { throw Failure.invalid("oversized packet") }
        if bytes[0] != 0xbf {
            guard let xml = String(data: data, encoding: .utf8) else { throw Failure.invalid("invalid UTF-8") }
            try validateXML(xml)
            return xml
        }
        guard bytes.count >= 3, bytes[1] == 1, bytes[2] == 0xbf else {
            throw Failure.invalid("unsupported version or header")
        }
        let message = try Fields(Array(bytes.dropFirst(3)))
        guard let event = try message.message(2) else { return nil }
        let type = try event.string(1)
        let uid = try event.string(5)
        guard !type.isEmpty, !uid.isEmpty else { throw Failure.invalid("missing type or UID") }
        var attributes = "version=\"2.0\""
        for (number, name) in [(1, "type"), (2, "access"), (3, "qos"), (4, "opex"), (5, "uid"), (9, "how")] {
            let value = try event.string(number)
            if !value.isEmpty { attributes += " \(name)=\"\(escape(value))\"" }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for (number, name) in [(6, "time"), (7, "start"), (8, "stale")] {
            let milliseconds = try event.integer(number)
            guard milliseconds > 0, milliseconds <= 253_402_300_799_999 else {
                throw Failure.invalid("invalid \(name) timestamp")
            }
            attributes +=
                " \(name)=\"\(formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000)))\""
        }
        var point = "<point"
        for (number, name) in [(10, "lat"), (11, "lon"), (12, "hae"), (13, "ce"), (14, "le")] {
            let value = try event.double(number)
            guard value.isFinite else { throw Failure.invalid("non-finite point") }
            point += " \(name)=\"\(value)\""
        }
        point += "/>"
        let detail = try event.message(15) ?? Fields([])
        var opaque = try detail.string(1)
        guard !opaque.localizedCaseInsensitiveContains("<!DOCTYPE"),
            !opaque.localizedCaseInsensitiveContains("<!ENTITY")
        else {
            throw Failure.invalid("DTD/entity declaration")
        }
        let delegate = DetailElements()
        let parser = XMLParser(data: Data("<detail>\(opaque)</detail>".utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), parser.parserError == nil else { throw Failure.invalid("malformed detail XML") }
        for (number, name, names) in [
            (2, "contact", ["endpoint", "callsign"]), (3, "__group", ["name", "role"]),
            (4, "precisionlocation", ["geopointsrc", "altsrc"]), (5, "status", []),
            (6, "takv", ["device", "platform", "os", "version"]), (7, "track", []),
        ] {
            guard let nested = try detail.message(number), !delegate.names.contains(name) else { continue }
            var tag = "<\(name)"
            for (index, attribute) in names.enumerated() {
                let value = try nested.string(index + 1)
                if name != "contact" || attribute != "endpoint" || !value.isEmpty {
                    tag += " \(attribute)=\"\(escape(value))\""
                }
            }
            if number == 5 { tag += " battery=\"\(try nested.integer(1))\"" }
            if number == 7 { tag += " speed=\"\(try nested.double(1))\" course=\"\(try nested.double(2))\"" }
            opaque += tag + "/>"
        }
        return "<event \(attributes)>\(point)<detail>\(opaque)</detail></event>"
    }

    private static func validateXML(_ xml: String) throws {
        guard !xml.localizedCaseInsensitiveContains("<!DOCTYPE"),
            !xml.localizedCaseInsensitiveContains("<!ENTITY")
        else {
            throw Failure.invalid("DTD/entity declaration")
        }
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), parser.parserError == nil else { throw Failure.invalid("malformed XML") }
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private struct Fields {
        enum Value { case integer(UInt64), fixed(UInt64), fixed32, bytes([UInt8]) }
        var values: [Int: Value] = [:]

        init(_ bytes: [UInt8]) throws {
            var offset = 0
            func varint() throws -> UInt64 {
                var value: UInt64 = 0
                for shift in stride(from: 0, to: 70, by: 7) {
                    guard offset < bytes.count else { throw Failure.invalid("truncated varint") }
                    let byte = bytes[offset]
                    offset += 1
                    guard shift < 63 || byte <= 1 else { throw Failure.invalid("varint overflow") }
                    value |= UInt64(byte & 127) << shift
                    if byte < 128 { return value }
                }
                throw Failure.invalid("varint overflow")
            }
            while offset < bytes.count {
                let tag = try varint()
                let number = tag >> 3
                guard number > 0, number <= 536_870_911 else { throw Failure.invalid("invalid field number") }
                let field = Int(number)
                switch tag & 7 {
                case 0: values[field] = .integer(try varint())
                case 1, 5:
                    let count = tag & 7 == 1 ? 8 : 4
                    guard bytes.count - offset >= count else { throw Failure.invalid("truncated fixed field") }
                    var bits: UInt64 = 0
                    for index in 0..<count { bits |= UInt64(bytes[offset + index]) << (index * 8) }
                    offset += count
                    values[field] = count == 8 ? .fixed(bits) : .fixed32
                case 2:
                    let length = try varint()
                    guard length <= UInt64(bytes.count - offset) else { throw Failure.invalid("truncated bytes") }
                    let end = offset + Int(length)
                    values[field] = .bytes(Array(bytes[offset..<end]))
                    offset = end
                default: throw Failure.invalid("unsupported wire type")
                }
            }
        }

        func string(_ field: Int) throws -> String {
            guard let value = values[field] else { return "" }
            guard case .bytes(let bytes) = value, let text = String(bytes: bytes, encoding: .utf8) else {
                throw Failure.invalid("invalid string field \(field)")
            }
            return text
        }

        func message(_ field: Int) throws -> Fields? {
            guard let value = values[field] else { return nil }
            guard case .bytes(let bytes) = value else { throw Failure.invalid("invalid message field \(field)") }
            return try Fields(bytes)
        }

        func integer(_ field: Int) throws -> UInt64 {
            guard let value = values[field] else { return 0 }
            guard case .integer(let number) = value else { throw Failure.invalid("invalid integer field \(field)") }
            return number
        }

        func double(_ field: Int) throws -> Double {
            guard let value = values[field] else { return 0 }
            guard case .fixed(let bits) = value else { throw Failure.invalid("invalid double field \(field)") }
            return Double(bitPattern: bits)
        }
    }
}
private final class DetailElements: NSObject, XMLParserDelegate {
    var names: Set<String> = []
    private var depth = 0
    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String]
    ) {
        depth += 1
        if depth == 2 { names.insert(name) }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        depth -= 1
    }
}
