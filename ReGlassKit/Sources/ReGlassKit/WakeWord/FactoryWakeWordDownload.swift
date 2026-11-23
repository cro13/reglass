import CryptoKit
import Foundation

/// Downloads and verifies Meta's factory "Hey Meta" set for the firmware the glasses report.
/// All requests go to Meta's update service and CDN.
///
///  - The seven spoken prompts come from the factory English language pack for the glasses' current build.
///    Each prompt is checked against its SHA-256 in the pack manifest, and the pack against Meta's checksum
///    when the offer carries one.
///  - The wake model: the XRSP blob in Meta's full firmware image that matches `WakeWordSet.heyMetaModelFingerprints`.
///    `FirmwareImageDownload` verifies the Orca container and checks the image against Meta's checksum when supplied.
struct FactoryWakeWordDownload {
    enum Failure: Error, LocalizedError, Equatable {
        case invalidDevice, signIn, unavailable, response, package, network, modelUnknown

        var errorDescription: String? {
            switch self {
            case .invalidDevice: return "ReGlass can't read your glasses' firmware version, so it can't ask Meta for the right files."
            case .signIn: return "Sign in with Meta again before downloading the factory set."
            case .unavailable: return "Meta isn't offering the factory files for your glasses' firmware. Nothing was saved. You can still import a factory set you already have."
            case .response: return "ReGlass couldn't read Meta's factory download response. Nothing was saved."
            case .package: return "The factory files didn't match Meta's checksums. Nothing was saved."
            case .network: return "The factory download couldn't finish. Check your connection and try again."
            case .modelUnknown: return "This firmware's \u{201C}Hey Meta\u{201D} model isn't one ReGlass recognises yet. Nothing was saved."
            }
        }
    }

    enum Package: CaseIterable {
        case language, firmware

        var name: String { self == .firmware ? "FetchConstellationUpdates" : "FetchConstellationFeatureUpdates" }
        var document: String { self == .firmware ? "155904535318377635033579516369" : "10649732309712548951633872342" }
        var root: String { self == .firmware ? "xar_constellation_updates" : "xar_constellation_feature_updates" }
    }

    /// What a download produced: Meta's language resource version and the eight files by name.
    struct Result: Sendable {
        let resourceVersion: String
        let contents: [String: [UInt8]]
    }

    /// The size limits for the language pack (the English pack is about 1.7 MB) and its manifest.
    static let maxLanguageBytes = 16 * 1024 * 1024
    static let maxManifestBytes = 1024 * 1024

    /// `firmware` is the build the glasses report (e.g. "1086324946"). No arbitrary URL, server text or account
    /// identifier is ever included in errors or logs.
    func fetch(token: String, serial: String, firmware: String,
               progress: @Sendable (String) async -> Void) async throws -> Result {
        guard !token.isEmpty, !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw Failure.signIn
        }
        guard serial.range(of: "\\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\\z", options: .regularExpression) != nil,
              (1...19).contains(firmware.utf8.count), firmware.utf8.allSatisfy({ (48...57).contains($0) }),
              firmware != "0" else {
            throw Failure.invalidDevice
        }
        do {
            // 1) The language pack Meta offers for this firmware.
            await progress("Asking Meta for your glasses' language pack…")
            let request = try Self.request(.language, token: token, serial: serial, firmware: firmware)
            let metadata = try await FactoryDownloadNetwork.read(request, limit: 4 * 1024 * 1024, redirects: false)
            let offer = try Self.languageOffer(metadata, serial: serial)
            kitLog("device", "factory language offer for firmware \(firmware): resource \(offer.version), "
                   + "\(offer.size) bytes\(offer.sha256 == nil ? ", no checksum" : "")")
            await progress("Downloading the spoken prompts…")
            // Deliberately a new request and ephemeral session: no login header, cookie or cache on the CDN.
            let pack = try await FactoryDownloadNetwork.read(URLRequest(url: offer.url), limit: offer.size, redirects: true)
            guard pack.count == offer.size, offer.sha256 == nil || Self.hash(pack) == offer.sha256 else {
                throw Failure.package
            }
            var contents = try Self.prompts(from: pack)

            // 2) The wake model, from Meta's current full image (checksum + container shape checked there).
            try Task.checkCancellation()
            await progress("Downloading the factory wake model…")
            let image: FirmwareImageDownload.Image
            do {
                let firmwareOffer = try await FirmwareOffer.fetch(token: token, serial: serial)
                image = try await FirmwareImageDownload.fetch(firmwareOffer)
            } catch is CancellationError { throw CancellationError() }
            catch let error as FirmwareOffer.Failure where error == .signIn { throw Failure.signIn }
            catch let error as FirmwareOffer.Failure where error == .response { throw Failure.response }
            catch let error as URLError where error.code == .cancelled { throw CancellationError() }
            catch is URLError { throw Failure.network }
            catch let error as FirmwareImageDownload.Failure where error == .network { throw Failure.network }
            catch { throw Failure.unavailable }
            defer { FirmwareImageDownload.discard(image) }
            await progress("Checking the eight factory files…")
            guard let model = Self.heyMetaModel(in: image.bytes) else {
                kitLog("device", "factory download: no known Hey Meta model in the offered image; nothing saved")
                throw Failure.modelUnknown
            }
            contents[ResourceOta.wakeModelFilename] = model
            return Result(resourceVersion: offer.version, contents: contents)
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as Failure { throw error }
        catch { throw Failure.network }
    }

    /// Requests the English language pack using the glasses' current firmware version.
    /// The full-image query reports firmware version zero and asks for a full update only.
    static func request(_ package: Package, token: String, serial: String, firmware: String? = nil) throws -> URLRequest {
        let reported: String
        switch package {
        case .firmware:
            reported = "0"
        case .language:
            guard let firmware, firmware != "0" else { throw Failure.invalidDevice }
            reported = firmware
        }
        let info: [String: Any] = [
            "device_type": "ota.orca.user", "device_serial": serial,
            "device_ota_session_id": UUID().uuidString.lowercased(),
            "device_firmware_version": reported,
            "device_feature_list": package == .language
                ? [["feature_name": ResourceOta.feature, "feature_version": NSNull()]] : [],
            "device_artifact_list": [], "device_firmware_full_update_only": package == .firmware,
            "device_firmware_rollout_token": NSNull(), "device_manage_mode": NSNull(),
            "constellation_device_type": NSNull(), "constellation_device_firmware_version": NSNull(),
            "constellation_device_serial": NSNull(), "supports_firmware_manifest_v1": true,
        ]
        let variables = try JSONSerialization.data(withJSONObject:
            ["fetch_request": ["constellation_updates_request_info": [info]]], options: [.sortedKeys])
        let fields = [
            ("fb_api_req_friendly_name", package.name), ("client_doc_id", package.document),
            ("variables", String(decoding: variables, as: UTF8.self)), ("method", "post"),
            ("locale", "en_US"), ("pretty", "false"), ("format", "json"),
        ]
        var request = URLRequest(url: URL(string: "https://ar-genai.graph.meta.com/graphql")!)
        request.httpMethod = "POST"
        request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        request.httpBody = Data(fields.map { key, value in
            key + "=" + value.addingPercentEncoding(withAllowedCharacters: safe)!
        }.joined(separator: "&").utf8)
        return request
    }

    struct LanguageOffer {
        let version: String
        let size: Int
        let url: URL
        /// Meta's SHA-256 for the pack, when the offer carries one.
        let sha256: String?
    }

    /// A top-level `error` that means the Meta sign-in is no longer valid: an `OAuthException` or code 190. Any other
    /// error is a failed response, not a reason to sign in again.
    static func isSignInError(_ error: Any) -> Bool {
        guard let error = error as? [String: Any] else { return false }
        if error["type"] as? String == "OAuthException" { return true }
        if let code = error["code"] as? Int { return code == 190 }
        if let code = error["code"] as? String { return code == "190" }
        return false
    }

    /// The English language offer for this serial number, including its decimal resource version, size, HTTPS URL
    /// on Meta's CDN and optional checksum.
    static func languageOffer(_ data: Data, serial: String) throws -> LanguageOffer {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.response }
        if let error = json["error"], !(error is NSNull) {
            throw isSignInError(error) ? Failure.signIn : Failure.response
        }
        if let errors = json["errors"], !(errors is NSNull), !((errors as? [Any])?.isEmpty ?? false) {
            throw Failure.response
        }
        guard let body = json["data"] as? [String: Any], let root = body[Package.language.root] as? [String: Any],
              let responses = root["constellation_updates_response_info"] as? [[String: Any]] else {
            throw Failure.response
        }
        var candidates: [[String: Any]] = []
        for response in responses where response["device_serial"] as? String == serial {
            for update in response["resource_updates_info"] as? [[String: Any]] ?? [] {
                let feature = update["feature"] as? [String: Any]
                if feature?["feature_name"] as? String == ResourceOta.feature {
                    candidates += update["feature_resource_updates_info"] as? [[String: Any]] ?? []
                }
            }
        }
        for value in candidates {
            guard let version = text(value["resource_version"]), (1...19).contains(version.utf8.count),
                  version.utf8.allSatisfy({ (48...57).contains($0) }),
                  let sizeText = text(value["file_size"]), let size = Int(sizeText), (1...maxLanguageBytes).contains(size),
                  let uri = value["file_uri"] as? String, uri.count <= 16_384,
                  let url = URL(string: uri), isDownloadURL(url) else { continue }
            let checksum = text(value["file_checksum"]).map { $0.lowercased().replacingOccurrences(of: "sha256:", with: "") }
            let sha = checksum.flatMap { isSHA256($0) ? $0 : nil }
            if checksum != nil, sha == nil {
                kitLog("device", "factory language offer: its checksum isn't SHA-256, so only the pack's own file "
                       + "hashes are checked")
            }
            return LanguageOffer(version: version, size: size, url: url, sha256: sha)
        }
        kitLog("device", "factory language offer: \(candidates.isEmpty ? "nothing offered" : "\(candidates.count) unusable")")
        throw Failure.unavailable
    }

    /// Reads the seven prompts for the factory English variant. The pack manifest (version 1 or 2) lists each
    /// file's path and SHA-256 digest, which ReGlass verifies before returning it.
    static func prompts(from pack: Data) throws -> [String: [UInt8]] {
        let zip: ZipArchive
        do { zip = try ZipArchive(Array(pack)) } catch { throw Failure.package }
        guard let manifestEntry = zip.entries.first(where: { $0.name == "manifest.json" }),
              let manifestBytes = try? zip.contents(of: manifestEntry, limit: maxManifestBytes),
              let manifest = try? JSONSerialization.jsonObject(with: Data(manifestBytes)) as? [String: Any],
              let schema = manifest["schema_version"] as? Int, (1...2).contains(schema),
              let variants = manifest["variants"] as? [[String: Any]],
              let variant = variants.first(where: { $0["id"] as? String == WakeWordSet.factoryVariant }),
              let files = variant["files"] as? [[String: Any]] else {
            throw Failure.package
        }
        var result: [String: [UInt8]] = [:]
        for filename in ResourceOta.filenames where filename != ResourceOta.wakeModelFilename {
            let path = WakeWordSet.factoryVariant + "/" + filename
            guard let listed = files.first(where: { $0["path"] as? String == path }),
                  let checksum = (listed["checksum"] as? String)?.lowercased(), checksum.hasPrefix("sha256:"),
                  let entry = zip.entries.first(where: { $0.name == path && !$0.isDirectory }),
                  (1...WakeWordSet.maxFileBytes).contains(entry.size) else {
                throw Failure.package
            }
            let expected = String(checksum.dropFirst("sha256:".count))
            guard isSHA256(expected) else { throw Failure.package }
            let bytes: [UInt8]
            do { bytes = try zip.contents(of: entry, limit: WakeWordSet.maxFileBytes) } catch { throw Failure.package }
            guard hash(Data(bytes)) == expected else { throw Failure.package }
            result[filename] = bytes
        }
        return result
    }

    /// Meta's "Hey Meta" model inside a firmware image: an XRSP blob (magic, then its total length as a
    /// little-endian u32 at byte 12) whose SHA-256 is a known Hey Meta fingerprint. Only reads the image.
    static func heyMetaModel(in image: [UInt8]) -> [UInt8]? {
        let magic = WakeWordSet.wakeModelMagic
        var start = 0
        while start + 16 <= image.count {
            guard let index = (start...(image.count - magic.count)).first(where: { at in
                image[at] == magic[0] && image[at + 1] == magic[1] && image[at + 2] == magic[2] && image[at + 3] == magic[3]
            }) else { return nil }
            if index + 16 <= image.count {
                let length = Int(image[index + 12]) | Int(image[index + 13]) << 8
                    | Int(image[index + 14]) << 16 | Int(image[index + 15]) << 24
                if (16...WakeWordSet.maxFileBytes).contains(length), index + length <= image.count {
                    let candidate = Array(image[index..<(index + length)])
                    if WakeWordSet.heyMetaModelFingerprints.contains(hash(Data(candidate))) { return candidate }
                }
            }
            start = index + magic.count
        }
        return nil
    }

    static func isDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.fragment == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return ["fbcdn.net", "facebook.com", "meta.com", "fbsbx.com"].contains {
            host == $0 || host.hasSuffix("." + $0)
        }
    }

    private static func isSHA256(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func text(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
}

/// Bounds metadata and package bodies while receiving them. Redirects can only stay on Meta's HTTPS CDN;
/// authenticated metadata requests never redirect. Cookies, credentials and URL caches are disabled.
final class FactoryDownloadNetwork: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let redirects: Bool
    init(redirects: Bool) { self.redirects = redirects }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(redirects && request.url.map(FactoryWakeWordDownload.isDownloadURL) == true
            && request.value(forHTTPHeaderField: "Authorization") == nil ? request : nil)
    }

    static func validate(_ response: URLResponse, for request: URLRequest, limit: Int) throws {
        guard let response = response as? HTTPURLResponse else { throw FactoryWakeWordDownload.Failure.response }
        if (response.statusCode == 401 || response.statusCode == 403),
           request.value(forHTTPHeaderField: "Authorization") != nil {
            throw FactoryWakeWordDownload.Failure.signIn
        }
        guard response.statusCode == 200, response.expectedContentLength <= Int64(limit) else {
            throw FactoryWakeWordDownload.Failure.response
        }
    }

    static func read(_ request: URLRequest, limit: Int, redirects: Bool) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        let session = URLSession(configuration: config, delegate: FactoryDownloadNetwork(redirects: redirects), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: request)
        try validate(response, for: request, limit: limit)
        var data = Data()
        data.reserveCapacity(min(limit, 64 * 1024))
        for try await byte in stream {
            if data.count % (64 * 1024) == 0 { try Task.checkCancellation() }
            guard data.count < limit else { throw FactoryWakeWordDownload.Failure.response }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }
}
