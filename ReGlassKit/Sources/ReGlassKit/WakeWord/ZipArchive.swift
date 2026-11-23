import Compression
import Foundation

/// A small read-only ZIP reader for archives held in memory: Meta's language pack and a custom set picked in Files.
/// Stored and deflated entries only; no ZIP64, encryption, multi-disk archives or symbolic links. Every name is checked
/// (no absolute paths, `..`, backslashes or control characters) and a name may appear once. Nothing is ever written
/// to disk from an archive by name: callers ask for the entries they expect.
struct ZipArchive {
    struct Entry: Equatable {
        let name: String
        let method: UInt16
        let crc32: UInt32
        let compressedSize: Int
        let size: Int
        let localHeaderOffset: Int

        var isDirectory: Bool { name.hasSuffix("/") }
        /// The last path component.
        var basename: String { name.split(separator: "/").last.map(String.init) ?? name }
    }

    enum Failure: Error, Equatable {
        case malformed(String)
        case unsupported(String)
        case tooLarge(String)
    }

    let entries: [Entry]
    private let bytes: [UInt8]

    init(_ bytes: [UInt8], maxEntries: Int = 1024) throws {
        self.bytes = bytes
        let end = try Self.endOfCentralDirectory(bytes)
        guard end.count <= maxEntries else { throw Failure.tooLarge("too many entries") }
        var entries: [Entry] = []
        var names = Set<String>()
        var at = end.offset
        for _ in 0..<end.count {
            guard at + 46 <= end.offset + end.size, Self.u32(bytes, at) == 0x0201_4b50 else {
                throw Failure.malformed("central directory")
            }
            let madeBy = Self.u16(bytes, at + 4)
            let flags = Self.u16(bytes, at + 8)
            let method = Self.u16(bytes, at + 10)
            let crc = Self.u32(bytes, at + 16)
            let compressed = Self.u32(bytes, at + 20)
            let size = Self.u32(bytes, at + 24)
            let nameLength = Int(Self.u16(bytes, at + 28))
            let extraLength = Int(Self.u16(bytes, at + 30))
            let commentLength = Int(Self.u16(bytes, at + 32))
            let disk = Self.u16(bytes, at + 34)
            let external = Self.u32(bytes, at + 38)
            let local = Self.u32(bytes, at + 42)
            let next = at + 46 + nameLength + extraLength + commentLength
            guard next <= end.offset + end.size else { throw Failure.malformed("central directory entry") }
            guard flags & 0x0041 == 0 else { throw Failure.unsupported("encrypted entry") }
            guard method == 0 || method == 8 else { throw Failure.unsupported("compression method \(method)") }
            guard compressed != 0xFFFF_FFFF, size != 0xFFFF_FFFF, local != 0xFFFF_FFFF, disk == 0 else {
                throw Failure.unsupported("ZIP64 or multi-disk entry")
            }
            // A Unix-made entry carries its mode in the high half of the external attributes: refuse symbolic links.
            if madeBy >> 8 == 3, (external >> 16) & 0xF000 == 0xA000 { throw Failure.unsupported("symbolic link") }
            let nameBytes = Array(bytes[(at + 46)..<(at + 46 + nameLength)])
            guard let name = String(bytes: nameBytes, encoding: .utf8), Self.isSafe(name) else {
                throw Failure.malformed("entry name")
            }
            guard names.insert(name).inserted else { throw Failure.malformed("duplicate entry \(name)") }
            entries.append(Entry(name: name, method: method, crc32: crc, compressedSize: Int(compressed),
                                 size: Int(size), localHeaderOffset: Int(local)))
            at = next
        }
        self.entries = entries
    }

    func entry(named name: String) -> Entry? {
        entries.first { $0.name == name }
    }

    /// The entry's bytes, inflated and checked against its CRC-32. Refuses anything larger than `limit`.
    func contents(of entry: Entry, limit: Int) throws -> [UInt8] {
        guard !entry.isDirectory else { throw Failure.malformed("\(entry.name) is a folder") }
        // Deflate never grows data by more than a few bytes per block, so a much larger stream is refused unread.
        guard entry.size <= limit, entry.compressedSize <= limit + limit / 8 + 1024 else {
            throw Failure.tooLarge(entry.name)
        }
        let at = entry.localHeaderOffset
        guard at + 30 <= bytes.count, Self.u32(bytes, at) == 0x0403_4b50 else {
            throw Failure.malformed("local header of \(entry.name)")
        }
        let start = at + 30 + Int(Self.u16(bytes, at + 26)) + Int(Self.u16(bytes, at + 28))
        guard start <= bytes.count, entry.compressedSize <= bytes.count - start else {
            throw Failure.malformed("data of \(entry.name)")
        }
        let compressed = bytes[start..<(start + entry.compressedSize)]
        let output: [UInt8]
        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.size else { throw Failure.malformed("stored size of \(entry.name)") }
            output = Array(compressed)
        default:
            output = try Self.inflate(compressed, size: entry.size, name: entry.name)
        }
        guard CRC32.checksum(output) == entry.crc32 else { throw Failure.malformed("checksum of \(entry.name)") }
        return output
    }

    // MARK: Structure

    private static func endOfCentralDirectory(_ bytes: [UInt8]) throws -> (offset: Int, size: Int, count: Int) {
        guard bytes.count >= 22 else { throw Failure.malformed("too short for a ZIP archive") }
        let lowest = max(0, bytes.count - 22 - 0xFFFF)
        var at = bytes.count - 22
        while at >= lowest {
            if u32(bytes, at) == 0x0605_4b50 {
                let disk = u16(bytes, at + 4), directoryDisk = u16(bytes, at + 6)
                let onDisk = u16(bytes, at + 8), total = u16(bytes, at + 10)
                let size = u32(bytes, at + 12), offset = u32(bytes, at + 16)
                let comment = Int(u16(bytes, at + 20))
                guard at + 22 + comment == bytes.count else { at -= 1; continue }
                guard disk == 0, directoryDisk == 0, onDisk == total, total != 0xFFFF,
                      size != 0xFFFF_FFFF, offset != 0xFFFF_FFFF else {
                    throw Failure.unsupported("ZIP64 or multi-disk archive")
                }
                guard Int(offset) + Int(size) <= at else { throw Failure.malformed("central directory bounds") }
                return (Int(offset), Int(size), Int(total))
            }
            at -= 1
        }
        throw Failure.malformed("no end of central directory")
    }

    /// Relative, forward slashes only, no empty, `.` or `..` components, printable.
    private static func isSafe(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 512, !name.hasPrefix("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        for (index, part) in parts.enumerated() {
            if part == "." || part == ".." { return false }
            if part.isEmpty && index != parts.count - 1 { return false }
        }
        return true
    }

    private static func inflate(_ compressed: ArraySlice<UInt8>, size: Int, name: String) throws -> [UInt8] {
        if size == 0 { return [] }
        guard !compressed.isEmpty else { throw Failure.malformed("data of \(name)") }
        // One byte of slack: a stream that fills it is longer than the directory says.
        let capacity = size + 1
        let source = Array(compressed)
        let output = [UInt8](unsafeUninitializedCapacity: capacity) { buffer, count in
            count = source.withUnsafeBufferPointer { input in
                // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), which is what ZIP method 8 holds.
                compression_decode_buffer(buffer.baseAddress!, capacity, input.baseAddress!, input.count, nil,
                                          COMPRESSION_ZLIB)
            }
        }
        guard output.count == size else { throw Failure.malformed("inflated size of \(name)") }
        return output
    }

    private static func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        guard at >= 0, at + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
}

/// CRC-32 (IEEE 802.3, reflected), as ZIP uses it.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
