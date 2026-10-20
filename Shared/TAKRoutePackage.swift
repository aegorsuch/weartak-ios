import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum TAKRoutePackage {
    static let maximumBytes = 4_194_304
    static let maximumExpandedBytes = 1_048_576

    enum Failure: LocalizedError {
        case invalidAdvertisement, invalidArchive, invalidManifest, noRoutes, hashMismatch
        var errorDescription: String? {
            switch self {
            case .invalidAdvertisement: return "Route package rejected: invalid server content advertisement."
            case .invalidArchive: return "Route package rejected: unsupported, damaged, or oversized ZIP."
            case .invalidManifest: return "Route package rejected: invalid mission package manifest."
            case .noRoutes: return "Route package contains no supported routes."
            case .hashMismatch: return "Route package rejected: SHA-256 or advertised size does not match."
            }
        }
    }

    struct Advertisement: Equatable {
        let hash: String
        let size: Int

        static func parse(_ xml: String) throws -> Self? {
            let delegate = PackageXML()
            try parseXML(Data(xml.utf8), delegate: delegate)
            guard delegate.type == "b-f-t-r" else { return nil }
            guard let values = delegate.transfer, let hash = values["sha256"],
                  hash.count == 64, hash.utf8.allSatisfy({
                      (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                  }),
                  let size = (values["sizeInBytes"] ?? values["size"]).flatMap(Int.init),
                  (1...maximumBytes).contains(size),
                  values["size"].map({ Int($0) == size }) ?? true,
                  let url = values["senderUrl"].flatMap(URLComponents.init(string:)),
                  url.scheme == "https", url.host?.isEmpty == false,
                  (url.port ?? 443) == 8443, url.user == nil, url.password == nil, url.fragment == nil,
                  url.percentEncodedPath == "/Marti/sync/content",
                  url.queryItems?.count == 1, url.queryItems?.first?.name == "hash",
                  url.queryItems?.first?.value?.lowercased() == hash.lowercased() else {
                throw Failure.invalidAdvertisement
            }
            return Self(hash: hash.lowercased(), size: size)
        }
    }

    /// The reader never extracts files. Only manifest-listed CoT is passed to the route parser.
    static func routes(entries: [String: Data], serverID: String) throws -> [GarminRoute] {
        guard entries.count <= 64,
              entries.values.reduce(0, { $0 + $1.count }) <= maximumExpandedBytes else {
            throw Failure.invalidArchive
        }
        guard let manifest = entries["MANIFEST/manifest.xml"] else { throw Failure.invalidManifest }
        let delegate = PackageXML()
        try parseXML(manifest, delegate: delegate)
        guard delegate.manifest, !delegate.contents.isEmpty, delegate.contents.count <= 32 else {
            throw Failure.invalidManifest
        }
        var store = GarminRouteStore()
        var seen = Set<String>()
        var routeIDs = Set<String>()
        for path in delegate.contents {
            guard safePath(path), seen.insert(path).inserted, let data = entries[path] else {
                throw Failure.invalidManifest
            }
            guard path.lowercased().hasSuffix(".cot") else { continue }
            for event in try GarminRouteCoT.parse(data, serverId: serverID) {
                if case .route(let route) = event {
                    guard routeIDs.insert(route.uid).inserted else { throw Failure.invalidManifest }
                    try store.upsert(route)
                }
            }
        }
        guard !store.routes.isEmpty else { throw Failure.noRoutes }
        return store.routes
    }

    static func safePath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 256 && !path.contains("\\") && !path.contains(":") &&
            !path.hasPrefix("/") && path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." } &&
            !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func parseXML(_ data: Data, delegate: PackageXML) throws {
        guard data.count <= maximumExpandedBytes, let xml = String(data: data, encoding: .utf8),
              !xml.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !xml.localizedCaseInsensitiveContains("<!ENTITY") else { throw Failure.invalidManifest }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.invalid else { throw Failure.invalidManifest }
    }
}

private final class PackageXML: NSObject, XMLParserDelegate {
    var type: String?
    var transfer: [String: String]?
    var manifest = false
    var contents: [String] = []
    var invalid = false
    private var stack: [String] = []

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        stack.append(name)
        guard stack.count <= 16 else { invalid = true; parser.abortParsing(); return }
        if stack == ["event"] { type = attributes["type"] }
        if stack == ["event", "detail", "fileshare"] {
            if transfer != nil { invalid = true }
            transfer = attributes
        }
        if stack == ["MissionPackageManifest"] { manifest = attributes["version"] == "2" }
        if stack == ["MissionPackageManifest", "Contents", "Content"], attributes["ignore"] != "true" {
            guard let path = attributes["zipEntry"], contents.count < 32 else {
                invalid = true; parser.abortParsing(); return
            }
            contents.append(path)
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        stack.removeLast()
    }
}
