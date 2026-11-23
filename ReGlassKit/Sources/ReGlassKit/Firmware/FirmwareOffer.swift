import Foundation

/// A single-image offer from Meta's firmware update service.
///
/// The request identifies the Audio glasses, reports version 0, asks for a full update and advertises manifest
/// version 1 support. The service selects the target build.
///
/// The installer accepts a plain firmware image with no application ID or recognized artifact type. A manifest
/// pack can contain a primary image and additional resources that need to be unpacked before transfer.
///
/// An offer includes the target and base versions, release channel and priority, download URL, checksum and byte
/// length. It can also include key identifiers, header lines and a payload offset. The size override in the header
/// takes precedence for tag 5 of the svc29 install request. The payload must fit inside the downloaded file.
///
/// Logs omit the signed URL, token, header text and key material.
struct FirmwareOffer: Sendable, Equatable {
    /// The decimal build number this update installs.
    let targetVersion: String
    /// The delta source build. In the known full-image offer it equals the target.
    let baseVersion: String
    /// The signed CDN URL for the image. Never logged.
    let downloadURI: URL
    /// The downloaded file's exact byte length.
    let fileSize: Int
    /// The size sent at tag 5 of the svc29 install request. Uses the header override when present, otherwise
    /// the file size. Always > 0 and `payloadOffset + payloadSize <= fileSize`.
    let payloadSize: Int
    /// The server's 64-digit hexadecimal SHA-256 digest. Nil only when the server sent an empty string.
    let fileChecksum: String?
    /// Install header lines joined with newlines and sent as-is at tag 7 of the svc29 install request. Empty when
    /// absent. The glasses read them to interpret the package.
    let metaHeaders: String
    /// Optional numeric identifier of the key-encryption key.
    let kekId: Int64?
    /// Optional hash of the key-encryption key.
    let kekHash: String?
    /// The non-negative offset the glasses use to find the image in the package (0 when absent). The transfer
    /// sends the whole downloaded file.
    let payloadOffset: Int64
    /// Whether the server supplied an install options object.
    let extraOptionsPresent: Bool
    /// The release channel's exact decimal text, sent at tag 14 of the svc29 install request.
    let releaseChannelId: String
    /// A case-insensitive `POWERWASH=1` header requests a factory wipe. The installer refuses it by default.
    let powerwash: Bool

    /// Maximum image download size. A full Audio image is about 10.4 MiB.
    static let maxImageBytes = 20 * 1024 * 1024

    enum Failure: Error, Equatable { case signIn, response, noOffer, tooLarge, badURL, checksum, unsupportedShape }

    /// Fetches and parses the firmware offer for `serial` using the wearer's Meta token. Throws `.noOffer` when
    /// Meta offers no firmware update (e.g. the device is already current) — a clean, safe stop.
    static func fetch(token: String, serial: String) async throws -> FirmwareOffer {
        guard !token.isEmpty, !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw Failure.signIn
        }
        guard serial.range(of: "\\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\\z", options: .regularExpression) != nil else {
            throw Failure.response
        }
        let request = try FactoryWakeWordDownload.request(.firmware, token: token, serial: serial)
        let metadata: Data
        do {
            metadata = try await FactoryDownloadNetwork.read(request, limit: 4 * 1024 * 1024, redirects: false)
        } catch let error as FactoryWakeWordDownload.Failure {
            throw error == .signIn ? Failure.signIn : Failure.response
        }
        return try parse(metadata, serial: serial)
    }

    /// Parses the firmware offer for the requested serial number out of the update response.
    static func parse(_ data: Data, serial: String) throws -> FirmwareOffer {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.response }
        if let error = json["error"], !(error is NSNull) {
            throw FactoryWakeWordDownload.isSignInError(error) ? Failure.signIn : Failure.response
        }
        if let errors = json["errors"], !(errors is NSNull), !((errors as? [Any])?.isEmpty ?? false) {
            throw Failure.response
        }
        guard let body = json["data"] as? [String: Any],
              let root = body[FactoryWakeWordDownload.Package.firmware.root] as? [String: Any],
              let responses = root["constellation_updates_response_info"] as? [[String: Any]] else {
            throw Failure.response
        }
        for response in responses where response["device_serial"] as? String == serial {
            // Skip absent and null offers. Any other value must be an object.
            guard let raw = response["firmware_update_info"], !(raw is NSNull) else { continue }
            guard let info = raw as? [String: Any] else { throw Failure.response }
            return try build(info)
        }
        throw Failure.noOffer
    }

    private static func build(_ info: [String: Any]) throws -> FirmwareOffer {
        // Only plain firmware images can be sent directly to the glasses.
        let appId = try string(info["app_id"])
        let artifactType = try string(info["artifact_type"])
        let typed = appId != nil
        if typed {
            throw Failure.unsupportedShape
        }
        if let artifactType, artifactType != "UNSET_OR_UNRECOGNIZED_ENUM_VALUE" {
            throw Failure.unsupportedShape
        }

        // Versions and the release channel ID are non-negative decimals within the signed 64-bit range.
        guard let target = try string(info["target_version"]), !target.isEmpty else { throw Failure.noOffer }
        guard isLong(target), let base = try string(info["base_version"]), isLong(base),
              let channel = try string(info["release_channel_id"]), isLong(channel),
              try string(info["release_priority"]) != nil else { throw Failure.response }
        guard let sizeValue = try exactInteger(info["file_size"]), sizeValue > 0 else { throw Failure.response }
        guard sizeValue <= Int64(maxImageBytes) else { throw Failure.tooLarge }
        let size = Int(sizeValue)

        guard let uriString = try string(info["file_uri"]), uriString.count <= 16_384, let url = URL(string: uriString),
              FactoryWakeWordDownload.isDownloadURL(url) else { throw Failure.badURL }

        // Join the install header lines and read the payload's byte offset.
        var headers = ""
        var payloadOffset: Int64 = 0
        var extraPresent = false
        if let rawExtra = info["extra_install_options"], !(rawExtra is NSNull) {
            guard let extra = rawExtra as? [String: Any] else { throw Failure.response }
            headers = try headerLines(extra["headers"]).joined(separator: "\n")
            payloadOffset = try exactInteger(extra["offset"]) ?? 0
            extraPresent = true
        }
        guard payloadOffset >= 0, payloadOffset < Int64(size) else { throw Failure.response }

        // Use the header's size override when present. Reject a malformed value or a payload that extends past EOF.
        let payloadSize = try headerFileSize(headers) ?? Int64(size)
        guard payloadSize > 0, payloadSize <= Int64(size) - payloadOffset else { throw Failure.response }

        // Checksum: required. A non-empty value must be a SHA-256 hex digest; anything else is a reject.
        guard let checksumText = try string(info["file_checksum"]) else { throw Failure.checksum }
        if !checksumText.isEmpty, !isSupportedChecksum(checksumText) { throw Failure.checksum }

        return FirmwareOffer(
            targetVersion: target,
            baseVersion: base,
            downloadURI: url,
            fileSize: size,
            payloadSize: Int(payloadSize),
            fileChecksum: checksumText.isEmpty ? nil : checksumText,
            metaHeaders: headers,
            kekId: try exactInteger(info["kek_id"]),
            kekHash: try string(info["kek_hash"]).flatMap { $0.isEmpty ? nil : $0 },
            payloadOffset: payloadOffset,
            extraOptionsPresent: extraPresent,
            releaseChannelId: channel,
            powerwash: headersRequestPowerwash(headers)
        )
    }

    /// Reads the install header lines. Absent and null values mean no lines.
    private static func headerLines(_ value: Any?) throws -> [String] {
        guard let value, !(value is NSNull) else { return [] }
        guard let list = value as? [Any] else { throw Failure.response }
        return try list.map { item in
            guard let line = item as? String else { throw Failure.response }
            return line
        }
    }

    /// Reads the last `=`-separated component of the first size override header. Returns nil when
    /// the line is absent and throws when the value is not an exact positive integer.
    private static func headerFileSize(_ headers: String) throws -> Int64? {
        guard let line = headers.split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { $0.hasPrefix("FILE_SIZE") }) else { return nil }
        guard let value = line.split(separator: "=", omittingEmptySubsequences: false).last,
              isDecimal(String(value)), let size = Int64(value), size > 0 else {
            throw Failure.response
        }
        return size
    }

    /// The only checksum format ReGlass knows how to verify: a 64-char SHA-256 hex digest (either case).
    private static func isSupportedChecksum(_ checksum: String) -> Bool {
        checksum.count == 64 && checksum.lowercased().allSatisfy { "0123456789abcdef".contains($0) }
    }

    /// Detects a factory wipe request without modifying the header blob.
    private static func headersRequestPowerwash(_ headers: String) -> Bool {
        headers.range(of: "POWERWASH=1", options: .caseInsensitive) != nil
    }

    /// A log-safe one-liner: versions, sizes and flags only — never the URL, token, header text or key material.
    var logSummary: String {
        let headerSize = metaHeaders.isEmpty ? "none" : "\(metaHeaders.utf8.count)B"
        let kek = kekId.map(String.init) ?? "none"
        return "target \(targetVersion), base \(baseVersion), \(fileSize) bytes, payload \(payloadSize) at offset "
            + "\(payloadOffset), options \(extraOptionsPresent ? "present" : "absent"), headers \(headerSize), "
            + "kek \(kek), checksum \(fileChecksum == nil ? "none" : "sha256"), powerwash \(powerwash)"
    }

    // MARK: Strict JSON readers

    /// Reads a JSON string. Missing and null fields return nil. Other values throw.
    private static func string(_ value: Any?) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let text = value as? String else { throw Failure.response }
        return text
    }

    /// Reads a JSON integer or decimal string that fits exactly in an Int64. Missing and null fields return nil.
    /// Booleans, fractions, out-of-range numbers and invalid strings throw.
    private static func exactInteger(_ value: Any?) throws -> Int64? {
        guard let value, !(value is NSNull) else { return nil }
        let text: String
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { throw Failure.response }
            // `stringValue` renders an integral number as plain digits and keeps any fraction or exponent, so parsing
            // it back is an exactness check with no truncation and no silent range wrap.
            text = number.stringValue
        } else if let string = value as? String {
            text = string
        } else {
            throw Failure.response
        }
        guard isDecimal(text, allowSign: true), let exact = Int64(text) else { throw Failure.response }
        return exact
    }

    /// A non-negative decimal within the signed 64-bit range.
    private static func isLong(_ text: String) -> Bool { isDecimal(text) && Int64(text) != nil }

    private static func isDecimal(_ text: String, allowSign: Bool = false) -> Bool {
        var digits = Substring(text)
        if allowSign, digits.first == "-" { digits = digits.dropFirst() }
        return !digits.isEmpty && digits.count <= 19 && digits.allSatisfy { ("0"..."9").contains($0) }
    }
}
