import Foundation

struct EnrollmentSigningResponse: Decodable {
    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    let signedCert: String
    let certificateAuthorities: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        guard let signedCertKey = Key(stringValue: "signedCert") else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid signedCert key."))
        }
        signedCert = try container.decode(String.self, forKey: signedCertKey)
        let authorityKeys = container.allKeys.filter { key in
            guard key.stringValue.hasPrefix("ca") else { return false }
            let suffix = key.stringValue.dropFirst(2)
            return suffix.isEmpty || suffix.utf8.allSatisfy { (48...57).contains($0) }
        }.sorted(by: Self.authorityKeyOrder)
        certificateAuthorities = try authorityKeys.map { try container.decode(String.self, forKey: $0) }
    }

    private static func authorityKeyOrder(_ first: Key, _ second: Key) -> Bool {
        if first.stringValue == "ca" || second.stringValue == "ca" {
            return first.stringValue == "ca" && second.stringValue != "ca"
        }
        let firstNumber = first.stringValue.dropFirst(2).drop(while: { $0 == "0" })
        let secondNumber = second.stringValue.dropFirst(2).drop(while: { $0 == "0" })
        if firstNumber.count != secondNumber.count { return firstNumber.count < secondNumber.count }
        if firstNumber != secondNumber { return firstNumber.lexicographicallyPrecedes(secondNumber) }
        return first.stringValue < second.stringValue
    }
}
