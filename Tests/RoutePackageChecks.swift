import Foundation
import CryptoKit
import zlib

@main
struct RoutePackageChecks {
    static func main() throws {
        func rejects(_ operation: () throws -> Void, line: UInt = #line) {
            do { try operation(); fatalError("Expected rejection at line \(line)") }
            catch {}
        }
        let hash = String(repeating: "a", count: 64)
        let xml = """
        <event type="b-f-t-r"><detail><fileshare sha256="\(hash)" sizeInBytes="100"
        senderUrl="https://192.0.2.1:8443/Marti/sync/content?hash=\(hash)"/></detail></event>
        """
        let advertisement = try TAKRoutePackage.Advertisement.parse(xml)
        precondition(advertisement == .init(hash: hash, size: 100))
        let unrelated = try TAKRoutePackage.Advertisement.parse("<event type=\"a-f-G\"/>")
        precondition(unrelated == nil)
        for invalid in [
            xml.replacingOccurrences(of: "https:", with: "http:"),
            xml.replacingOccurrences(of: ":8443", with: ":443"),
            xml.replacingOccurrences(of: "sizeInBytes=\"100\"", with: "sizeInBytes=\"4194305\""),
            xml.replacingOccurrences(of: "sizeInBytes=\"100\"", with: "sizeInBytes=\"0\""),
            xml.replacingOccurrences(of: "/Marti/sync/content", with: "/Marti/api/missions"),
            xml.replacingOccurrences(of: "https://", with: "https://user:secret@"),
            xml.replacingOccurrences(of: "sha256=\"\(hash)\"", with: "sha256=\"bad\""),
            xml.replacingOccurrences(of: "sizeInBytes=\"100\"", with: "sizeInBytes=\"100\" size=\"101\""),
            "<!DOCTYPE event [<!ENTITY x SYSTEM \"file:///etc/passwd\">]>" + xml
        ] { rejects { _ = try TAKRoutePackage.Advertisement.parse(invalid) } }
        let routeXML = """
        <event uid="route-1" type="b-m-r"><detail><contact callsign="Route One"/>
        <link relation="c" point="38,-77" callsign="Start"/>
        <link relation="c" point="38.1,-77.1" callsign="End"/></detail></event>
        """
        let manifest = """
        <MissionPackageManifest version="2"><Configuration>
        <Parameter name="onReceiveImport" value="true"/><Parameter name="onReceiveDelete" value="true"/>
        </Configuration><Contents><Content ignore="false" zipEntry="route-1/route-1.cot"/>
        </Contents></MissionPackageManifest>
        """
        let files = ["MANIFEST/": Data(), "MANIFEST/manifest.xml": Data(manifest.utf8),
                     "route-1/route-1.cot": Data(routeXML.utf8)]
        let routes = try TAKRoutePackage.routes(entries: files, serverID: "server")
        precondition(routes.count == 1 && routes[0].points.count == 2)
        precondition(routes[0].points[1].name == "End")
        let namedAndUnnamed = GarminRoute(serverId: "server", uid: "named-test", name: "Named test",
            points: [.init(lat: 1, lon: 1, name: " Alpha "),
                     .init(lat: 2, lon: 2, name: nil),
                     .init(lat: 3, lon: 3, name: " \n "),
                     .init(lat: 4, lon: 4, name: "Delta")])
        precondition(namedAndUnnamed.namedPoints.map { $0.index } == [0, 3])
        precondition(namedAndUnnamed.namedPoints.map { $0.name } == ["Alpha", "Delta"])
        precondition(namedAndUnnamed.namedPoints.map { $0.point } == [namedAndUnnamed.points[0], namedAndUnnamed.points[3]])
        let originalGeometry = namedAndUnnamed.payload["points"] as? [[String: Any]]
        precondition(namedAndUnnamed.points.count == 4 && originalGeometry?.count == 4)
        precondition(originalGeometry?[1]["lat"] as? Double == 2 && originalGeometry?[2]["lat"] as? Double == 3)
        let unnamed = GarminRoute(serverId: "server", uid: "unnamed-test", name: "Unnamed",
            points: [.init(lat: 1, lon: 1), .init(lat: 2, lon: 2, name: "\t")])
        precondition(unnamed.namedPoints.isEmpty && unnamed.points.count == 2)
        var other = routes[0]
        other = GarminRoute(serverId: "other", uid: other.uid, name: other.name, points: other.points)
        precondition(routes[0].id != other.id)
        var local = WatchRoutes()
        try local.replace(routes + [other])
        local.remove(routes[0])
        precondition(local.routes.isEmpty, "Remove all local source copies of the same route UID")
        try local.replace(routes + [other])
        precondition(local.routes == routes + [other])
        local = try JSONDecoder().decode(WatchRoutes.self, from: JSONEncoder().encode(local))
        try local.receive([.route(routes[0])], serverID: "server")
        precondition(local.routes == routes + [other])
        try local.receive([.remove(other.uid)], serverID: "other")
        precondition(local.routes == routes)
        rejects { _ = try TAKRoutePackage.routes(entries: [:], serverID: "server") }
        for path in ["../route.cot", "/route.cot", "a\\route.cot", "C:route.cot", "a//route.cot"] {
            precondition(!TAKRoutePackage.safePath(path))
            var invalid = files
            invalid["MANIFEST/manifest.xml"] = Data(manifest.replacingOccurrences(of: "route-1/route-1.cot", with: path).utf8)
            rejects { _ = try TAKRoutePackage.routes(entries: invalid, serverID: "server") }
        }
        var nonRoute = files
        nonRoute["route-1/route-1.cot"] = Data("<event uid=\"x\" type=\"t-x-d-d\"/>".utf8)
        rejects { _ = try TAKRoutePackage.routes(entries: nonRoute, serverID: "server") }
        var withDelete = files
        withDelete["route-1/route-1.cot"] = Data((routeXML +
            "<event uid=\"delete\" type=\"t-x-d-d\"><detail><link uid=\"route-1\"/></detail></event>").utf8)
        let routesIgnoringDelete = try TAKRoutePackage.routes(entries: withDelete, serverID: "server")
        precondition(routesIgnoringDelete == routes)
        var deeplyNested = files
        deeplyNested["MANIFEST/manifest.xml"] = Data((String(repeating: "<nested>", count: 17) +
            String(repeating: "</nested>", count: 17)).utf8)
        rejects { _ = try TAKRoutePackage.routes(entries: deeplyNested, serverID: "server") }
        var invalidGeometry = files
        invalidGeometry["route-1/route-1.cot"] = Data(routeXML.replacingOccurrences(of: "38,-77", with: "91,-77").utf8)
        rejects { _ = try TAKRoutePackage.routes(entries: invalidGeometry, serverID: "server") }
        for method in [0, 8] {
            let archive = zip(files, method: method)
            let request = TAKRoutePackage.Advertisement(
                hash: SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined(), size: archive.count)
            let imported = try RoutePackageZIP.routes(archive, advertisement: request, serverID: "server")
            precondition(imported == routes)
            rejects { _ = try RoutePackageZIP.routes(archive, advertisement: .init(hash: hash, size: archive.count), serverID: "server") }
            rejects { _ = try RoutePackageZIP.routes(archive, advertisement: .init(hash: request.hash, size: 1), serverID: "server") }
            rejects { _ = try RoutePackageZIP.entries(archive.dropLast()) }
        }
        rejects { _ = try RoutePackageZIP.entries(zip(files, method: 9)) }
        rejects { _ = try RoutePackageZIP.entries(zip(files, flags: 1)) }
        rejects { _ = try RoutePackageZIP.entries(zip(files, corruptCRC: true)) }
        rejects { _ = try RoutePackageZIP.entries(zip(files, expandedSize: TAKRoutePackage.maximumExpandedBytes + 1)) }
        rejects { _ = try RoutePackageZIP.entries(zip(["../escape.cot": Data(routeXML.utf8)])) }
        rejects { _ = try RoutePackageZIP.entries(Data(repeating: 0, count: 30)) }
        var multiDisk = zip(files)
        multiDisk[multiDisk.count - 18] = 1
        rejects { _ = try RoutePackageZIP.entries(multiDisk) }
        var symlink = zip(files)
        let central = symlink.range(of: Data([0x50, 0x4b, 0x01, 0x02]))!.lowerBound
        symlink[central + 41] = 0xa0
        rejects { _ = try RoutePackageZIP.entries(symlink) }
        print("PASS: route package advertisement policy, ZIP stored/deflate/CRC/budgets, manifest, geometry and watch-local removal/replay")
    }

    private static func zip(_ files: [String: Data], method: Int = 0, flags: Int = 0,
                            corruptCRC: Bool = false, expandedSize: Int? = nil) -> Data {
        func number(_ value: Int, _ bytes: Int) -> Data {
            Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        var local = Data(), central = Data()
        for name in files.keys.sorted() {
            let value = files[name]!
            let nameData = Data(name.utf8)
            let checksum = value.withUnsafeBytes { Int(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(value.count))) }
            // A final uncompressed DEFLATE block still exercises raw inflate and its exact byte accounting.
            let compressed = method == 8
                ? Data([1]) + number(value.count, 2) + number(~value.count, 2) + value : value
            let crc = corruptCRC ? checksum ^ 1 : checksum
            let size = expandedSize ?? value.count
            let offset = local.count
            local += number(0x04034b50, 4) + number(20, 2) + number(flags, 2) + number(method, 2)
            local += Data(repeating: 0, count: 4) + number(crc, 4) + number(compressed.count, 4) + number(size, 4)
            local += number(nameData.count, 2) + number(0, 2) + nameData + compressed
            central += number(0x02014b50, 4) + number(20, 2) + number(20, 2) + number(flags, 2) + number(method, 2)
            central += Data(repeating: 0, count: 4) + number(crc, 4) + number(compressed.count, 4) + number(size, 4)
            central += number(nameData.count, 2) + Data(repeating: 0, count: 12) + number(offset, 4) + nameData
        }
        let end = number(0x06054b50, 4) + Data(repeating: 0, count: 4) +
            number(files.count, 2) + number(files.count, 2) + number(central.count, 4) + number(local.count, 4) + number(0, 2)
        return local + central + end
    }
}
