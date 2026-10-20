import Foundation
import CryptoKit
import zlib

enum RoutePackageZIP {
    /// ZIP32 only, stored/deflate, bounded in memory; no archive-controlled filesystem writes.
    static func routes(_ data: Data, advertisement: TAKRoutePackage.Advertisement,
                       serverID: String) throws -> [GarminRoute] {
        guard data.count == advertisement.size, data.count <= TAKRoutePackage.maximumBytes,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == advertisement.hash else {
            throw TAKRoutePackage.Failure.hashMismatch
        }
        return try TAKRoutePackage.routes(entries: entries(data), serverID: serverID)
    }

    static func entries(_ data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        func number(_ offset: Int, _ width: Int) throws -> Int {
            guard offset >= 0, offset <= bytes.count - width else { throw TAKRoutePackage.Failure.invalidArchive }
            return (0..<width).reduce(0) { $0 | Int(bytes[offset + $1]) << ($1 * 8) }
        }
        func u16(_ offset: Int) throws -> Int { try number(offset, 2) }
        func u32(_ offset: Int) throws -> Int { try number(offset, 4) }
        guard (22...TAKRoutePackage.maximumBytes).contains(bytes.count) else {
            throw TAKRoutePackage.Failure.invalidArchive
        }
        // Locate the actual end record, including an optional ZIP comment.
        let eocd = stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1).first {
            guard (try? u32($0)) == 0x06054b50, let length = try? u16($0 + 20) else { return false }
            return $0 + 22 + length == bytes.count
        }
        guard let eocd, try u16(eocd + 4) == 0, try u16(eocd + 6) == 0,
              try u16(eocd + 8) == u16(eocd + 10) else { throw TAKRoutePackage.Failure.invalidArchive }
        let count = try u16(eocd + 10)
        let centralSize = try u32(eocd + 12)
        let centralStart = try u32(eocd + 16)
        guard (1...64).contains(count), centralStart + centralSize == eocd else {
            throw TAKRoutePackage.Failure.invalidArchive
        }
        var cursor = centralStart
        var expanded = 0
        var result: [String: Data] = [:]
        var names = Set<String>()
        var ranges: [Range<Int>] = []
        for _ in 0..<count {
            guard try u32(cursor) == 0x02014b50 else { throw TAKRoutePackage.Failure.invalidArchive }
            let flags = try u16(cursor + 8), method = try u16(cursor + 10)
            let checksum = try u32(cursor + 16), compressed = try u32(cursor + 20)
            let size = try u32(cursor + 24), nameLength = try u16(cursor + 28)
            let extraLength = try u16(cursor + 30), commentLength = try u16(cursor + 32)
            let local = try u32(cursor + 42)
            guard flags & ~0x0808 == 0, method == 0 || method == 8,
                  try u16(cursor + 34) == 0,
                  try (u32(cursor + 38) >> 16) & 0xf000 != 0xa000,
                  (1...256).contains(nameLength), cursor + 46 + nameLength + extraLength + commentLength <= eocd,
                  size <= TAKRoutePackage.maximumExpandedBytes,
                  expanded + size <= TAKRoutePackage.maximumExpandedBytes,
                  let name = String(bytes: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], encoding: .utf8),
                  names.insert(name).inserted else { throw TAKRoutePackage.Failure.invalidArchive }
            cursor += 46 + nameLength + extraLength + commentLength
            expanded += size
            let directory = name.hasSuffix("/")
            guard TAKRoutePackage.safePath(directory ? String(name.dropLast()) : name),
                  try u32(local) == 0x04034b50, try u16(local + 6) == flags,
                  try u16(local + 8) == method, try u16(local + 26) == nameLength else {
                throw TAKRoutePackage.Failure.invalidArchive
            }
            let start = try local + 30 + u16(local + 26) + u16(local + 28)
            guard local < centralStart, start + compressed <= centralStart,
                  bytes[(local + 30)..<(local + 30 + nameLength)] ==
                    bytes[(cursor - nameLength - extraLength - commentLength)..<(cursor - extraLength - commentLength)],
                  !ranges.contains(where: { $0.overlaps(local..<(start + compressed)) }) else {
                throw TAKRoutePackage.Failure.invalidArchive
            }
            ranges.append(local..<(start + compressed))
            if flags & 8 == 0 {
                guard try u32(local + 14) == checksum, try u32(local + 18) == compressed,
                      try u32(local + 22) == size else { throw TAKRoutePackage.Failure.invalidArchive }
            }
            guard !directory || size == 0 else { throw TAKRoutePackage.Failure.invalidArchive }
            let input = Array(bytes[start..<(start + compressed)])
            var output = [UInt8](repeating: 0, count: max(1, size))
            if method == 0 {
                guard compressed == size else { throw TAKRoutePackage.Failure.invalidArchive }
                output = input
            } else {
                var stream = z_stream()
                guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                    throw TAKRoutePackage.Failure.invalidArchive
                }
                defer { inflateEnd(&stream) }
                let status = input.withUnsafeBytes { source in
                    output.withUnsafeMutableBytes { destination in
                        stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                        stream.avail_in = uInt(compressed)
                        stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                        stream.avail_out = uInt(max(1, size))
                        return inflate(&stream, Z_FINISH)
                    }
                }
                guard status == Z_STREAM_END, Int(stream.total_out) == size, Int(stream.total_in) == compressed else {
                    throw TAKRoutePackage.Failure.invalidArchive
                }
                output = Array(output.prefix(size))
            }
            let crc = output.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(size)) }
            guard Int(crc) == checksum else { throw TAKRoutePackage.Failure.invalidArchive }
            if !directory { result[name] = Data(output) }
        }
        guard cursor == eocd else { throw TAKRoutePackage.Failure.invalidArchive }
        return result
    }
}
