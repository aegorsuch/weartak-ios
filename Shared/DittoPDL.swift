#if canImport(Compression)
import Compression
import Foundation

struct DittoPDL {
    let appID: String
    let sharedKey: String
    let licenseToken: String
    let expiresAt: Date
}

enum DittoPDLError: LocalizedError {
    case missing
    case communityNotProvisioned
    case invalidBase64
    case invalidCompression
    case invalidJSON
    case unsupportedVersion
    case unsupportedIdentity
    case missingField(String)
    case expired

    var errorDescription: String? {
        switch self {
        case .missing: return "The selected Ditto PDL is not configured."
        case .communityNotProvisioned:
            return "This iPhone build has no Community Ditto identity. Select Custom on the watch and save an authorized PDL shared with your peers."
        case .invalidBase64: return "The selected Ditto PDL is not valid Base64."
        case .invalidCompression: return "The selected Ditto PDL could not be decompressed."
        case .invalidJSON: return "The selected Ditto PDL does not contain valid JSON."
        case .unsupportedVersion: return "The selected Ditto PDL version is unsupported."
        case .unsupportedIdentity: return "The selected Ditto PDL must use SharedKey identity."
        case .missingField(let field): return "The selected Ditto PDL is missing \(field)."
        case .expired: return "The selected Ditto PDL has expired."
        }
    }
}

enum DittoPDLParser {
    static let maximumEncodedBytes = DittoBridgeConfiguration.maximumPDLBytes
    static let maximumDecodedBytes = 32_768

    static func parse(_ encoded: String, now: Date = Date()) throws -> DittoPDL {
        let trimmed = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DittoPDLError.missing }
        guard trimmed.utf8.count <= maximumEncodedBytes else { throw DittoPDLError.invalidBase64 }
        var base64 = trimmed.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let compressed = Data(base64Encoded: base64), !compressed.isEmpty else {
            throw DittoPDLError.invalidBase64
        }
        guard let jsonData = decompress(compressed) else { throw DittoPDLError.invalidCompression }
        guard let object = try? JSONSerialization.jsonObject(with: jsonData),
              let json = object as? [String: Any] else { throw DittoPDLError.invalidJSON }
        guard (json["v"] as? NSNumber)?.intValue == 2 else { throw DittoPDLError.unsupportedVersion }
        guard json["it"] as? String == "SK" else { throw DittoPDLError.unsupportedIdentity }
        guard let appID = nonemptyString(json["a"]) else { throw DittoPDLError.missingField("app ID") }
        guard let sharedKey = nonemptyString(json["s"]) else { throw DittoPDLError.missingField("shared key") }
        guard let licenseToken = nonemptyString(json["t"]) else {
            throw DittoPDLError.missingField("offline license token")
        }
        guard let expiryMilliseconds = (json["e"] as? NSNumber)?.int64Value,
              expiryMilliseconds > 0 else { throw DittoPDLError.missingField("expiration") }
        let expiresAt = Date(timeIntervalSince1970: Double(expiryMilliseconds) / 1_000)
        guard expiresAt > now else { throw DittoPDLError.expired }
        return DittoPDL(appID: appID, sharedKey: sharedKey, licenseToken: licenseToken, expiresAt: expiresAt)
    }

    /// PDLs are zlib-wrapped (RFC 1950); Apple's COMPRESSION_ZLIB decodes only the raw DEFLATE body (RFC 1951).
    static func deflateBody(_ compressed: Data) -> Data? {
        let bytes = [UInt8](compressed)
        guard bytes.count > 6, bytes[0] & 0x0F == 8, bytes[0] >> 4 <= 7,
              (UInt16(bytes[0]) << 8 | UInt16(bytes[1])) % 31 == 0,
              bytes[1] & 0x20 == 0 else { return nil }
        return Data(bytes[2..<(bytes.count - 4)])
    }

    private static func decompress(_ wrapped: Data) -> Data? {
        guard let compressed = deflateBody(wrapped) else { return nil }
        var output = Data(count: maximumDecodedBytes)
        let decodedCount = output.withUnsafeMutableBytes { destination in
            compressed.withUnsafeBytes { source in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(destinationBase, maximumDecodedBytes, sourceBase,
                    compressed.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard decodedCount > 0, decodedCount < maximumDecodedBytes else { return nil }
        output.count = decodedCount
        return output
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
