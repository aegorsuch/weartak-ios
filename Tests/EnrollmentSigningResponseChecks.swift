import Foundation

@main
struct EnrollmentSigningResponseChecks {
    static func main() throws {
        func decode(_ fields: [String: Any]) throws -> EnrollmentSigningResponse {
            try JSONDecoder().decode(EnrollmentSigningResponse.self,
                                     from: JSONSerialization.data(withJSONObject: fields))
        }
        func check(_ fields: [String: Any], authorities: [String]) throws {
            let result = try decode(fields)
            precondition(result.signedCert == "leaf")
            precondition(result.certificateAuthorities == authorities)
        }
        try check(["signedCert": "leaf", "ca": "ots-root"], authorities: ["ots-root"])
        try check(["signedCert": "leaf", "ca0": "root", "ca1": "intermediate"],
                  authorities: ["root", "intermediate"])
        try check(["signedCert": "leaf", "ca10": "ten", "ca2": "two", "ca1": "one",
                   "ca0": "zero", "ca": "ots-root"],
                  authorities: ["ots-root", "zero", "one", "two", "ten"])
        try check(["signedCert": "leaf"], authorities: [])
        try check(["signedCert": "leaf", "ca00": "zero-zero", "ca0": "zero",
                   "ca01": "zero-one", "ca1": "one", "ca999999999999999999999999999999": "huge"],
                  authorities: ["zero", "zero-zero", "zero-one", "one", "huge"])
        try check(["signedCert": "leaf", "case": NSNull(), "ca-1": 42, "ca1x": false,
                   "ca١": [], "CA": [:], "ca 1": NSNull(), "ca1.0": 12],
                  authorities: [])
        for key in ["ca", "ca0", "ca1", "ca10"] {
            for value: Any in [NSNull(), 42, true, ["nested"], ["value": "nested"]] {
                do {
                    _ = try decode(["signedCert": "leaf", key: value])
                    fatalError("Non-text CA accepted for \(key)")
                } catch is DecodingError {}
            }
        }
        for fields: [String: Any] in [[:], ["signedCert": NSNull()], ["signedCert": 42]] {
            do {
                _ = try decode(fields)
                fatalError("Missing or non-text signed certificate accepted")
            } catch is DecodingError {}
        }
        // Companion uses JSON signClient/v2, not the XML signing protocol.
        for xml in [
            "<response><signedCert>leaf</signedCert><ca>root</ca></response>",
            "<response><signedCert>leaf</signedCert><ca>first</ca><ca>second</ca></response>",
            "<response><signedCert>leaf</signedCert><ca0>first</ca0><ca0>second</ca0></response>"
        ] {
            do {
                _ = try JSONDecoder().decode(EnrollmentSigningResponse.self, from: Data(xml.utf8))
                fatalError("Unsupported XML signing response accepted")
            } catch is DecodingError {}
        }
        print("PASS: enrollment ca/caN selection, numeric ordering, non-text rejection and XML rejection")
    }
}
