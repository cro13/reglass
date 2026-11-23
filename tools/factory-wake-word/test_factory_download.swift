import CryptoKit
import Foundation

/// Offline checks of FactoryWakeWordDownload, run by test_factory_download.py. Argument 1 is the folder of synthetic
/// language packs; an optional argument 2 is a local Meta firmware image to search for the real Hey Meta model.
@main
struct FactoryDownloadTests {
    typealias Download = FactoryWakeWordDownload
    static var checks = 0
    static let cdn = "https://scontent.xx.fbcdn.net/v/language.zip?signature=test"

    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
        checks += 1
    }

    /// The operation must throw exactly `expected`.
    static func fails(_ expected: Download.Failure, _ message: String, _ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Expected \(expected): " + message) }
        catch { expect(error as? Download.Failure == expected, "Expected \(expected), got \(error): " + message) }
    }

    static func hex(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        try requests()
        try responseStatuses()
        try languageOffers()
        try languagePacks(folder)
        models()
        downloadURLs()
        await inputChecks()
        if CommandLine.arguments.count > 2 {
            try realFirmware(URL(fileURLWithPath: CommandLine.arguments[2]), folder)
        }
        print("Factory download: \(checks) checks passed (no network requests).")
    }

    // MARK: request()

    /// The form fields of a query body, and the one device row inside its `variables`.
    static func fields(_ request: URLRequest) throws -> (form: [String: String], info: [String: Any]) {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        var form: [String: String] = [:]
        for item in URLComponents(string: "https://example.test/?" + body)?.queryItems ?? [] { form[item.name] = item.value }
        let variables = try JSONSerialization.jsonObject(with: Data((form["variables"] ?? "").utf8)) as? [String: Any]
        let rows = (variables?["fetch_request"] as? [String: Any])?["constellation_updates_request_info"] as? [[String: Any]]
        expect(rows?.count == 1, "One device row per query")
        return (form, rows![0])
    }

    static func requests() throws {
        fails(.invalidDevice, "language query without the glasses' build") {
            _ = try Download.request(.language, token: "test-token-7f3a", serial: "test-serial")
        }
        var fullOnly: [Download.Package] = []
        var sessions = Set<String>()
        for package in Download.Package.allCases {
            // Both get the glasses' build; only the language query may send it.
            let request = try Download.request(package, token: "test-token-7f3a", serial: "test-serial", firmware: "1086324946")
            expect(request.url?.absoluteString == "https://ar-genai.graph.meta.com/graphql", "Fixed Graph endpoint")
            expect(request.httpMethod == "POST", "Query uses POST")
            expect(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token-7f3a", "Token in the header")
            expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded", "Form body")
            expect(!String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("test-token"), "Token not in the body")
            let (form, info) = try fields(request)
            let name = package == .firmware ? "FetchConstellationUpdates" : "FetchConstellationFeatureUpdates"
            expect(form["fb_api_req_friendly_name"] == name, "Query name")
            expect(form["client_doc_id"] == package.document, "Persisted query id")
            expect(info["device_type"] as? String == "ota.orca.user", "Audio glasses product")
            expect(info["device_serial"] as? String == "test-serial", "Serial sent")
            expect(info["supports_firmware_manifest_v1"] as? Bool == true, "Firmware manifest v1 supported")
            let session = info["device_ota_session_id"] as? String ?? ""
            expect(UUID(uuidString: session) != nil && session == session.lowercased(), "Lowercase session id")
            sessions.insert(session)
            let features = info["device_feature_list"] as? [[String: Any]]
            if package == .language {
                expect(info["device_firmware_version"] as? String == "1086324946", "Language query sends the glasses' build")
                expect(features?.count == 1 && features?[0]["feature_name"] as? String == "luna.language_en_us"
                       && features?[0]["feature_version"] is NSNull, "Language query asks for luna.language_en_us")
                expect(info["device_firmware_full_update_only"] as? Bool == false, "Language query is not full-update-only")
            } else {
                expect(info["device_firmware_version"] as? String == "0", "Firmware query sends 0")
                expect(features?.isEmpty == true, "Firmware query asks for no feature")
            }
            if info["device_firmware_full_update_only"] as? Bool == true { fullOnly.append(package) }
        }
        expect(fullOnly == [.firmware], "Only the firmware query is full-update-only")
        expect(sessions.count == Download.Package.allCases.count, "A new session id per query")
    }

    static func responseStatuses() throws {
        let cdnRequest = URLRequest(url: URL(string: cdn)!)
        for status in [401, 403] {
            for package in Download.Package.allCases {
                let request = try Download.request(package, token: "test-token-7f3a", serial: "test-serial",
                                                   firmware: "1086324946")
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                fails(.signIn, "\(package) metadata HTTP \(status)") {
                    try FactoryDownloadNetwork.validate(response, for: request, limit: 1024)
                }
            }
            let response = HTTPURLResponse(url: cdnRequest.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            fails(.response, "CDN download HTTP \(status)") {
                try FactoryDownloadNetwork.validate(response, for: cdnRequest, limit: 1024)
            }
        }
    }

    // MARK: languageOffer()

    static func update(version: Any = "1086338170", size: Any = "1712345", uri: String = cdn,
                       checksum: String? = nil) -> [String: Any] {
        var update: [String: Any] = ["resource_version": version, "file_size": size, "file_uri": uri]
        if let checksum { update["file_checksum"] = checksum }
        return update
    }

    /// A constellation feature response with one device row, in the shape the parser reads.
    static func response(serial: String = "test-serial", feature: String = "luna.language_en_us",
                         updates: [[String: Any]] = [update()], root: String = "xar_constellation_feature_updates",
                         extra: [String: Any] = [:]) throws -> Data {
        let device: [String: Any] = ["device_serial": serial, "resource_updates_info": [
            ["feature": ["feature_name": feature], "feature_resource_updates_info": updates]]]
        let json: [String: Any] = ["data": [root: ["constellation_updates_response_info": [device]]]]
        return try JSONSerialization.data(withJSONObject: json.merging(extra) { $1 })
    }

    static func offer(_ data: Data) throws -> Download.LanguageOffer {
        try Download.languageOffer(data, serial: "test-serial")
    }

    static func languageOffers() throws {
        let plain = try offer(response())
        expect(plain.version == "1086338170" && plain.size == 1_712_345, "Parse version and size")
        expect(plain.url.absoluteString == cdn && plain.sha256 == nil, "Parse URL; no checksum offered")
        let digest = String(repeating: "ab", count: 32)
        let checked = try offer(response(updates: [update(checksum: "SHA256:" + digest.uppercased())]))
        expect(checked.sha256 == digest, "Meta's checksum, normalised")
        let numbers = try offer(response(updates: [update(version: 1_086_338_170, size: 1_712_345)]))
        expect(numbers.version == "1086338170" && numbers.size == 1_712_345, "Numbers accepted as well as text")
        let skipped = try offer(response(updates: [update(uri: "https://example.test/language.zip"),
                                                   update(version: "1086338171")]))
        expect(skipped.version == "1086338171", "An unusable offer is skipped for a usable one")

        fails(.unavailable, "different serial") { _ = try offer(response(serial: "another-pair")) }
        fails(.unavailable, "wrong feature") { _ = try offer(response(feature: "luna.language_fr_fr")) }
        fails(.unavailable, "untrusted host") { _ = try offer(response(updates: [update(uri: "https://example.test/language.zip")])) }
        fails(.unavailable, "plain HTTP") { _ = try offer(response(updates: [update(uri: "http://scontent.xx.fbcdn.net/language.zip")])) }
        fails(.unavailable, "version not digits") { _ = try offer(response(updates: [update(version: "1.2")])) }
        fails(.unavailable, "empty pack") { _ = try offer(response(updates: [update(size: "0")])) }
        fails(.unavailable, "pack too large") { _ = try offer(response(updates: [update(size: String(Download.maxLanguageBytes + 1))])) }
        fails(.unavailable, "nothing offered") { _ = try offer(response(updates: [])) }
        fails(.response, "malformed JSON") { _ = try offer(Data("not json".utf8)) }
        fails(.response, "no data") { _ = try offer(Data("{}".utf8)) }
        fails(.response, "firmware response root") { _ = try offer(response(root: "xar_constellation_updates")) }
        fails(.response, "GraphQL errors") { _ = try offer(response(extra: ["errors": [["message": "test"]]])) }
        fails(.signIn, "OAuth error") { _ = try offer(response(extra: ["error": ["code": 190]])) }
        fails(.signIn, "OAuth exception") { _ = try offer(response(extra: ["error": ["type": "OAuthException", "code": 10]])) }
        fails(.response, "other server error") { _ = try offer(response(extra: ["error": ["code": 2, "message": "test"]])) }
    }

    // MARK: prompts(from:)

    static func languagePacks(_ folder: URL) throws {
        func pack(_ name: String) throws -> Data { try Data(contentsOf: folder.appendingPathComponent(name)) }
        expect(WakeWordSet.factoryVariant == "en_US.mai_03", "Factory variant")
        let expected = try JSONSerialization.jsonObject(with: pack("expected.json")) as? [String: String] ?? [:]
        let prompts = try Download.prompts(from: pack("pack.zip"))
        expect(Set(prompts.keys) == ResourceOta.filenames.subtracting([ResourceOta.wakeModelFilename]), "The seven prompts, no model")
        expect(Set(prompts.keys) == Set(expected.keys), "Fixture holds the same seven")
        for (name, bytes) in prompts {
            expect(hex(bytes) == expected[name], "Prompt from en_US.mai_03, not the other voice: " + name)
        }
        for (fixture, why) in [("pack-bad-sha.zip", "prompt not matching its SHA-256"),
                               ("pack-missing.zip", "prompt missing from the ZIP"),
                               ("pack-unlisted.zip", "prompt missing from the manifest"),
                               ("pack-no-variant.zip", "no en_US.mai_03 variant"),
                               ("pack-schema-3.zip", "unknown manifest schema"),
                               ("pack-no-manifest.zip", "no manifest.json")] {
            let data = try pack(fixture)
            fails(.package, why) { _ = try Download.prompts(from: data) }
        }
        fails(.package, "not a ZIP") { _ = try Download.prompts(from: Data("not a zip".utf8)) }
    }

    // MARK: heyMetaModel(in:)

    /// An XRSP blob: the magic, eight bytes, its total length as a little-endian u32, then filler.
    static func blob(length: Int, fill: UInt8 = 0x11) -> [UInt8] {
        let size = UInt32(length)
        return WakeWordSet.wakeModelMagic + [UInt8](repeating: 0, count: 8)
            + [UInt8(size & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 24)]
            + [UInt8](repeating: fill, count: max(0, length - 16))
    }

    static func models() {
        expect(!WakeWordSet.heyMetaModelFingerprints.isEmpty && WakeWordSet.heyMetaModelFingerprints.allSatisfy {
            $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) }
        }, "Fingerprints are SHA-256 hex")
        let filler = [UInt8](repeating: 0x5A, count: 4096)
        expect(Download.heyMetaModel(in: []) == nil, "Empty image")
        expect(Download.heyMetaModel(in: filler) == nil, "Image without an XRSP blob")
        expect(Download.heyMetaModel(in: filler + blob(length: 4096) + filler) == nil, "XRSP blob with an unknown fingerprint")
        expect(Download.heyMetaModel(in: filler + Array(blob(length: 1 << 20).prefix(2048))) == nil, "XRSP blob longer than the image")
        expect(Download.heyMetaModel(in: filler + WakeWordSet.wakeModelMagic) == nil, "Magic at the very end")
    }

    // MARK: isDownloadURL()

    static func downloadURLs() {
        for text in ["http://fbcdn.net/file", "https://fbcdn.net.attacker.test/file", "https://notfbcdn.net/file",
                     "https://user:pass@fbcdn.net/file", "https://fbcdn.net@attacker.test/file", "https://fbcdn.net:444/file",
                     "https://fbcdn.net/file#fragment", "file:///tmp/factory", "https://127.0.0.1/file",
                     "https://attacker.test/fbcdn.net"] {
            expect(!Download.isDownloadURL(URL(string: text)!), "Reject URL: " + text)
        }
        for text in ["https://scontent.xx.fbcdn.net:443/file", "https://lookaside.fbsbx.com/file"] {
            expect(Download.isDownloadURL(URL(string: text)!), "HTTPS Meta CDN allowed: " + text)
        }
    }

    // MARK: fetch() input checks and Failure

    /// Every case fails a check that runs before any request. Progress is reported before the first request, so a
    /// case that ever got past the checks stops here instead of reaching the network.
    static func inputChecks() async {
        let token = "test-token", serial = "test-serial", firmware = "1086324946"
        let cases: [(String, String, String, Download.Failure, String)] = [
            ("", serial, firmware, .signIn, "empty token"),
            ("test\ntoken", serial, firmware, .signIn, "control character in the token"),
            (token, "", firmware, .invalidDevice, "empty serial"),
            (token, "-serial", firmware, .invalidDevice, "serial starting with a dash"),
            (token, "test serial", firmware, .invalidDevice, "space in the serial"),
            (token, String(repeating: "a", count: 129), firmware, .invalidDevice, "serial too long"),
            (token, serial, "", .invalidDevice, "no firmware build"),
            (token, serial, "0", .invalidDevice, "firmware 0"),
            (token, serial, "10863249a6", .invalidDevice, "firmware not digits"),
            (token, serial, String(repeating: "1", count: 20), .invalidDevice, "firmware too long"),
        ]
        for (token, serial, firmware, expected, why) in cases {
            do {
                _ = try await Download().fetch(token: token, serial: serial, firmware: firmware) { _ in
                    preconditionFailure("Got past the input checks: " + why)
                }
                preconditionFailure("Expected \(expected): " + why)
            } catch {
                expect(error as? Download.Failure == expected, "Fetch refuses \(why)")
            }
        }
        let all: [Download.Failure] = [.invalidDevice, .signIn, .unavailable, .response, .package, .network, .modelUnknown]
        for failure in all {
            let text = failure.errorDescription ?? ""
            expect(!text.isEmpty && text.hasSuffix("."), "A full-sentence message for \(failure)")
        }
    }

    // MARK: A real firmware image (optional)

    static func realFirmware(_ url: URL, _ folder: URL) throws {
        let image = [UInt8](try Data(contentsOf: url))
        guard let model = Download.heyMetaModel(in: image) else { preconditionFailure("No known Hey Meta model in the image") }
        checks += 1
        expect(WakeWordSet.heyMetaModelFingerprints.contains(hex(model)), "Model has a known fingerprint")
        expect(WakeWordSet.looksLikeWakeModel(model) && model.count <= WakeWordSet.maxFileBytes, "Model is an XRSP blob")
        let magic = WakeWordSet.wakeModelMagic
        let offset = (0...(image.count - model.count)).first { at in
            image[at] == magic[0] && image[at + 1] == magic[1] && image[at + 2] == magic[2] && image[at + 3] == magic[3]
                && Array(image[at..<(at + model.count)]) == model
        }!
        expect(Download.heyMetaModel(in: blob(length: 4096) + image) == model, "Found past a decoy blob")
        expect(Download.heyMetaModel(in: Array(image.prefix(offset + model.count - 1))) == nil, "Truncated model refused")
        var contents = try Download.prompts(from: Data(contentsOf: folder.appendingPathComponent("pack.zip")))
        contents[ResourceOta.wakeModelFilename] = model
        let set = WakeWordSet.factory(firmware: "1086324946", resourceVersion: "1086338170", contents: contents)
        expect(set?.entries.count == 8 && set?.baseVersion == "1086338170.en_US.mai_03", "Model and prompts make a factory set")
        print("Found Meta's Hey Meta model (\(model.count) bytes, \(hex(model).prefix(12))…) at offset \(offset) of the local image.")
    }
}
