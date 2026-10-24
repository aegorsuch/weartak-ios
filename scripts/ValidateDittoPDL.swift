import Foundation

@main
struct ValidateDittoPDL {
    enum Failure: Error { case invalidCommunityIdentity }

    static func main() throws {
        let encoded = (ProcessInfo.processInfo.environment["DITTO_COMMUNITY_PDL"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !encoded.isEmpty else {
            print("Community identity absent; retaining explicit missing-identity behavior.")
            return
        }
        do {
            _ = try DittoPDLParser.parse(encoded)
        } catch {
            throw Failure.invalidCommunityIdentity
        }
        print("Community identity validated by the app's PDL parser; value redacted.")
    }
}
