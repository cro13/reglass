import CryptoKit
import Foundation

/// Downloads a firmware image to a temporary file on this iPhone for the firmware OTA. It reuses the bounded,
/// cookie-less, redirect-guarded `FactoryDownloadNetwork.read` (redirects may only stay on Meta's HTTPS CDN and
/// never carry an Authorization header). It verifies the byte length against the offer, the SHA-256 when the offer
/// carries one, and that the bytes are positively the single Orca firmware container (`OrcaImageShape`). It never
/// touches the glasses and never logs the URL.
///
/// The bytes are also kept in memory (the image is ≤ 20 MB) so the Airship sender can checksum its prefixes; the
/// temp file is the on-disk artefact the caller cleans up when it is done.
struct FirmwareImageDownload {
    struct Image {
        /// The temp file the caller removes with `discard` when finished.
        let url: URL
        /// The full image bytes.
        let bytes: [UInt8]
    }

    enum Failure: Error, Equatable { case tooLarge, size, checksum, network, notFirmwareImage }

    /// Downloads `offer.downloadURI`, verifies it, and writes it to a fresh temp file.
    static func fetch(_ offer: FirmwareOffer) async throws -> Image {
        guard offer.fileSize > 0, offer.fileSize <= FirmwareOffer.maxImageBytes else { throw Failure.tooLarge }
        let data: Data
        do {
            // Exact-length bound: `read` refuses a body whose advertised length exceeds the limit and stops at it.
            data = try await FactoryDownloadNetwork.read(URLRequest(url: offer.downloadURI),
                                                         limit: offer.fileSize, redirects: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.network
        }
        guard data.count == offer.fileSize else { throw Failure.size }
        // The offer already rejects any checksum format we can't verify (FirmwareOffer supports SHA-256 hex only);
        // re-assert it here as defence in depth, then verify. A present checksum in an unsupported format is a
        // reject, never a silent skip.
        if let checksum = offer.fileChecksum, !checksum.isEmpty {
            guard isSHA256Hex(checksum) else { throw Failure.checksum }
            guard sha256Hex(data) == checksum.lowercased() else { throw Failure.checksum }
        }
        // Positively the single Orca firmware container, never a manifest pack, ZIP or anything else sent verbatim
        // as the primary image.
        try OrcaImageShape.verify(data.byteArray, offset: Int(offer.payloadOffset), payloadSize: offer.payloadSize)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reglass-firmware-\(UUID().uuidString.lowercased()).bin")
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        return Image(url: url, bytes: data.byteArray)
    }

    /// Removes the temp file; safe to call more than once.
    static func discard(_ image: Image) {
        try? FileManager.default.removeItem(at: image.url)
    }

    private static func isSHA256Hex(_ text: String) -> Bool {
        text.count == 64 && text.lowercased().allSatisfy { "0123456789abcdef".contains($0) }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Recognises a single Orca OTA container at `payloadOffset`. The glasses expect this layout.
///
///     [0,8)        ASCII "APPUHDR6"
///     [8,12)       big-endian header length L
///     [12,42)      compatibility metadata (ASCII "QCC7226", bounded 16-bit fields)
///     [42,12+L-96) N × 48-byte signed SHA-384 descriptor digests, one per PARTDATA chunk, in transfer order
///     [12+L-96,12+L) the 96-byte ECDSA-P384 signature (r ‖ s)
///     [12+L, end)  exactly N "PARTDATA" chunks (tag 8, big-endian length 4, then `length` bytes), tiling the
///                  payload to its last byte
///
/// ReGlass checks the container structure before sending any install request. The glasses verify the ECDSA
/// signature and SHA-384 digests as the bytes arrive.
enum OrcaImageShape {
    static let magic = Array("APPUHDR6".utf8)
    static let chunkTag = Array("PARTDATA".utf8)
    /// The fixed parts of the header around the digest array: 12 bytes of framing+length, 30 of metadata, 96 of
    /// signature, and 48 bytes per descriptor digest.
    private static let metadataEnd = 42, signatureBytes = 96, digestBytes = 48
    /// A sanity ceiling on chunk count.
    private static let maxChunks = 64

    static func verify(_ bytes: [UInt8], offset: Int, payloadSize: Int) throws {
        func fail() -> FirmwareImageDownload.Failure { .notFirmwareImage }
        guard offset >= 0, payloadSize > 0, offset <= bytes.count, payloadSize <= bytes.count - offset else {
            throw fail()
        }
        let start = offset, end = offset + payloadSize
        func bigEndian32(_ at: Int) -> Int { bytes[at..<(at + 4)].reduce(0) { ($0 << 8) | Int($1) } }

        guard end - start >= 12, Array(bytes[start..<(start + 8)]) == magic else { throw fail() }
        let headerLength = bigEndian32(start + 8)
        let digestSpan = 12 + headerLength - metadataEnd - signatureBytes
        guard digestSpan >= digestBytes, digestSpan % digestBytes == 0 else { throw fail() }
        let expectedChunks = digestSpan / digestBytes
        guard expectedChunks <= maxChunks else { throw fail() }

        // Walk every chunk: each must be a PARTDATA record that fits, and together they must tile the payload.
        var at = start + 12 + headerLength
        var chunks = 0
        while at < end {
            guard chunks < expectedChunks, end - at >= 12, Array(bytes[at..<(at + 8)]) == chunkTag else { throw fail() }
            let length = bigEndian32(at + 8)
            guard length > 0, length <= end - at - 12 else { throw fail() }
            at += 12 + length
            chunks += 1
        }
        guard at == end, chunks == expectedChunks else { throw fail() }
    }
}
