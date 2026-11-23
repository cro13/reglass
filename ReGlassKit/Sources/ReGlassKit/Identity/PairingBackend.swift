import Foundation

/// An ownership receipt as carried over svc36: `{1: signature, 2: JSON body}`. The body bytes are what the
/// signature covers, so they are kept exactly as Meta or the glasses produced them. Never log either part.
struct OwnershipReceipt: Sendable, Equatable {
    let signature: [UInt8]
    let body: [UInt8]

    func encoded() -> [UInt8] { Wire.fieldBytes(1, signature) + Wire.fieldBytes(2, body) }

    static func decode(_ data: [UInt8]) throws -> OwnershipReceipt {
        let fields = try Wire.parse(data)
        return OwnershipReceipt(signature: fields.bytes(1), body: fields.bytes(2))
    }

    /// Both parts present and the body a JSON object. Checked before a receipt is forwarded anywhere.
    var isWellFormed: Bool {
        guard !signature.isEmpty, !body.isEmpty, case .object = try? OrderedJSON.parse(body) else { return false }
        return true
    }

    /// Reads a top-level field of the receipt body, such as the serial number or user ID. Numbers return as text.
    func field(_ name: String) -> String? {
        guard case .object(let members) = try? OrderedJSON.parse(body),
              let value = members.first(where: { $0.key == name })?.value else { return nil }
        switch value {
        case .string(let text): return text
        case .literal(let text): return text == "null" ? nil : text
        default: return nil
        }
    }
}

/// Meta's hardware pairing service issues a pending receipt for the app key and returns a final receipt after
/// the glasses sign the pending one. ReGlass sends the form fields in order, URL-encoded and gzipped.
struct PairingBackend: Sendable {
    let userToken: String
    let universe: String
    let appToken: String

    func pairRequest(certificate: [UInt8], serial: String, deviceNonce: [UInt8], appPublicKey: [UInt8]) async throws
        -> OwnershipReceipt {
        var fields = commonFields
        fields.append(("device_cert", base64(certificate)))
        fields.append(("serial_number", serial))
        fields.append(("additional_data", OrderedJSON.object([
            ("device_nonce", .string(base64(deviceNonce))),
            ("app_pubkey", .string(base64(appPublicKey))),
            ("secondary_cert", .string("")),
        ]).pythonDumps()))
        return try await post("pair_request", fields, receiptKey: "pending_ownership_receipt")
    }

    func pair(devicePendingReceipt: OwnershipReceipt) async throws -> OwnershipReceipt {
        var fields = commonFields
        fields.append(("device_pending_ownership_receipt", String(decoding: devicePendingReceipt.body, as: UTF8.self)))
        fields.append(("device_pending_ownership_receipt_signature", base64(devicePendingReceipt.signature)))
        // A normal pairing leaves the temporary pairing option unset.
        return try await post("pair", fields, receiptKey: "final_ownership_receipt")
    }

    private var commonFields: [(String, String)] {
        [
            ("access_token", appToken),
            ("user_access_token", userToken),
            ("user_token_universe", universe),
            ("pair_protocol_version", "4"),
        ]
    }

    private func post(_ method: String, _ fields: [(String, String)], receiptKey: String) async throws
        -> OwnershipReceipt {
        guard let url = URL(string: "https://graph.facebook-hardware.com/\(method)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        let body = try gzip(Array(pyURLEncode(fields).utf8))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await PairingSession.shared.upload(for: request, from: Data(body))
        } catch let error as URLError {
            throw error.code == .cancelled ? ReGlassError.cancelled : ReGlassError.network(code: error.code.rawValue)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        // Server bodies can echo tokens or receipts: only the status is ever kept.
        guard status < 400 else {
            kitLog("ownership", "\(method): HTTP \(status)")
            throw ReGlassError.metaRejected(status: status)
        }
        guard case .object(let payload) = try? OrderedJSON.parse(data.byteArray) else {
            throw ReGlassError.protocolFailure("\(method): the response was not a JSON object")
        }
        func member(_ key: String) -> OrderedJSON? { payload.first(where: { $0.key == key })?.value }
        if member("error") != nil {
            kitLog("ownership", "\(method): Meta refused the request")
            throw ReGlassError.metaRejected(status: status)
        }
        guard let receipt = member(receiptKey) else {
            throw ReGlassError.protocolFailure("\(method): no \(receiptKey) in the response")
        }
        guard case .string(let signature)? = member("receipt_signature") else {
            throw ReGlassError.protocolFailure("\(method): no receipt_signature in the response")
        }
        // A receipt sent as a JSON string is the signed body itself; an object is re-serialised the way Python's
        // json.dumps writes it, keys in the order Meta sent them.
        let bodyText: String
        if case .string(let text) = receipt { bodyText = text } else { bodyText = receipt.pythonDumps() }
        return OwnershipReceipt(signature: lenientBase64Decode(signature), body: Array(bodyText.utf8))
    }
}

// MARK: Encoding helpers

/// Standard base64 with padding (`Base64.getEncoder()`).
private func base64(_ bytes: [UInt8]) -> String { Data(bytes).base64EncodedString() }

/// Python's `b64decode` without `validate=`: characters outside the alphabet are dropped.
private func lenientBase64Decode(_ text: String) -> [UInt8] {
    let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
    var kept = text.utf8.filter { alphabet.contains($0) }
    while kept.count % 4 != 0 { kept.append(UInt8(ascii: "=")) }
    return Data(base64Encoded: Data(kept))?.byteArray ?? []
}

/// `GZIPOutputStream`: a ten-byte header, raw DEFLATE, then CRC-32 and the input length, little endian.
private func gzip(_ data: [UInt8]) throws -> [UInt8] {
    let deflated = try (Data(data) as NSData).compressed(using: .zlib) as Data
    func littleEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)]
    }
    let header: [UInt8] = [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0]
    return header + deflated.byteArray + littleEndian(crc32(data)) + littleEndian(UInt32(truncatingIfNeeded: data.count))
}

/// CRC-32 (IEEE 802.3).
private func crc32(_ data: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data { crc = crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    return crc ^ 0xFFFF_FFFF
}

private let crc32Table: [UInt32] = (0..<256).map { n -> UInt32 in
    var c = UInt32(n)
    for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    return c
}

/// Cookie-less, cache-less, redirect-refusing: a pairing POST can only reach the fixed endpoint it names.
private enum PairingSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration, delegate: BlockRedirects(), delegateQueue: nil)
    }()
}

// MARK: Order-preserving JSON

/// Just enough JSON for receipts: objects keep their key order and numbers / booleans / null keep their literal
/// text, so a receipt object can be written back exactly as Python's `json.dumps` would.
indirect enum OrderedJSON: Equatable {
    case object([(key: String, value: OrderedJSON)])
    case array([OrderedJSON])
    case string(String)
    /// A number, `true`, `false` or `null`, as written.
    case literal(String)

    static func == (a: OrderedJSON, b: OrderedJSON) -> Bool {
        switch (a, b) {
        case (.object(let x), .object(let y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        case (.array(let x), .array(let y)): return x == y
        case (.string(let x), .string(let y)), (.literal(let x), .literal(let y)): return x == y
        default: return false
        }
    }

    static func parse(_ bytes: [UInt8]) throws -> OrderedJSON {
        var parser = Parser(bytes: bytes)
        let value = try parser.value()
        parser.skipWhitespace()
        guard parser.atEnd else { throw Parser.Failure() }
        return value
    }

    /// Python's `json.dumps(value)` with its defaults: `", "` and `": "` separators, `ensure_ascii`.
    func pythonDumps() -> String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .literal(let text):
            out += text
        case .string(let text):
            Self.writeString(text, into: &out)
        case .array(let values):
            out += "["
            for (i, value) in values.enumerated() {
                if i > 0 { out += ", " }
                value.write(into: &out)
            }
            out += "]"
        case .object(let members):
            out += "{"
            for (i, member) in members.enumerated() {
                if i > 0 { out += ", " }
                Self.writeString(member.key, into: &out)
                out += ": "
                member.value.write(into: &out)
            }
            out += "}"
        }
    }

    /// `ensure_ascii`, walked in UTF-16 units so characters outside the BMP come out as surrogate pairs.
    private static func writeString(_ text: String, into out: inout String) {
        out += "\""
        for unit in text.utf16 {
            switch unit {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case _ where unit < 0x20 || unit > 0x7E:
                let hex = String(unit, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default:
                out.unicodeScalars.append(UnicodeScalar(UInt8(unit)))
            }
        }
        out += "\""
    }

    private struct Parser {
        struct Failure: Error {}
        let bytes: [UInt8]
        var at = 0

        var atEnd: Bool { at >= bytes.count }

        mutating func skipWhitespace() {
            while at < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[at]) { at += 1 }
        }

        mutating func value() throws -> OrderedJSON {
            skipWhitespace()
            guard at < bytes.count else { throw Failure() }
            switch bytes[at] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            default: return .literal(try literal())
            }
        }

        mutating func object() throws -> OrderedJSON {
            at += 1
            var members: [(key: String, value: OrderedJSON)] = []
            skipWhitespace()
            if at < bytes.count, bytes[at] == UInt8(ascii: "}") { at += 1; return .object(members) }
            while true {
                skipWhitespace()
                guard at < bytes.count, bytes[at] == UInt8(ascii: "\"") else { throw Failure() }
                let key = try string()
                skipWhitespace()
                guard at < bytes.count, bytes[at] == UInt8(ascii: ":") else { throw Failure() }
                at += 1
                let parsed = try value()
                // Like a Python dict: a repeated key keeps its first position and takes the last value.
                if let index = members.firstIndex(where: { $0.key == key }) {
                    members[index].value = parsed
                } else {
                    members.append((key, parsed))
                }
                skipWhitespace()
                guard at < bytes.count else { throw Failure() }
                if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                guard bytes[at] == UInt8(ascii: "}") else { throw Failure() }
                at += 1
                return .object(members)
            }
        }

        mutating func array() throws -> OrderedJSON {
            at += 1
            var values: [OrderedJSON] = []
            skipWhitespace()
            if at < bytes.count, bytes[at] == UInt8(ascii: "]") { at += 1; return .array(values) }
            while true {
                values.append(try value())
                skipWhitespace()
                guard at < bytes.count else { throw Failure() }
                if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                guard bytes[at] == UInt8(ascii: "]") else { throw Failure() }
                at += 1
                return .array(values)
            }
        }

        mutating func literal() throws -> String {
            let start = at
            while at < bytes.count, !Self.delimiters.contains(bytes[at]) { at += 1 }
            let text = String(decoding: bytes[start..<at], as: UTF8.self)
            let isNumber = text.first.map { $0 == "-" || $0.isASCII && $0.isNumber } ?? false
            guard isNumber || ["true", "false", "null"].contains(text) else { throw Failure() }
            return text
        }

        mutating func string() throws -> String {
            at += 1
            var units: [UInt16] = []
            while true {
                guard at < bytes.count else { throw Failure() }
                let byte = bytes[at]
                at += 1
                switch byte {
                case UInt8(ascii: "\""):
                    return String(decoding: units, as: UTF16.self)
                case UInt8(ascii: "\\"):
                    guard at < bytes.count else { throw Failure() }
                    let escape = bytes[at]
                    at += 1
                    switch escape {
                    case UInt8(ascii: "\""): units.append(0x22)
                    case UInt8(ascii: "\\"): units.append(0x5C)
                    case UInt8(ascii: "/"): units.append(0x2F)
                    case UInt8(ascii: "b"): units.append(0x08)
                    case UInt8(ascii: "f"): units.append(0x0C)
                    case UInt8(ascii: "n"): units.append(0x0A)
                    case UInt8(ascii: "r"): units.append(0x0D)
                    case UInt8(ascii: "t"): units.append(0x09)
                    case UInt8(ascii: "u"):
                        guard at + 4 <= bytes.count,
                              let unit = UInt16(String(decoding: bytes[at..<(at + 4)], as: UTF8.self), radix: 16)
                        else { throw Failure() }
                        units.append(unit)
                        at += 4
                    default: throw Failure()
                    }
                default:
                    // Raw UTF-8: decode the whole sequence starting here.
                    var end = at
                    while end < bytes.count, bytes[end] & 0xC0 == 0x80 { end += 1 }
                    units.append(contentsOf: String(decoding: bytes[(at - 1)..<end], as: UTF8.self).utf16)
                    at = end
                }
            }
        }

        private static let delimiters: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D]
    }
}
