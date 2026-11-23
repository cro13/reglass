import Foundation

/// A Meta pairing token, as the ownership layer consumes it: `value` is the user access token, `universe` is the
/// token universe Meta's pairing backend expects ("ar" here, "fb" reserved). Never log `value`.
struct Token: Sendable, Equatable {
    let value: String
    let universe: String

    init(_ value: String, _ universe: String) {
        self.value = value
        self.universe = universe
    }
}

// Meta's own static identifiers for the logged-out native login. All three belong to one flow and cannot be mixed.
private let metaAppID = "934401142814369"
let metaRedirectURI = "https://accounts.meta.com/native/oidc/redirect/metaai"
private let authorizeEndpoint = "https://accounts.meta.com/oidc/"
private let tokenExchangeEndpoint = "https://api.accounts.meta.com/native/oidc/token-exchange/"
private let frlaExchangeHost = "ar.graph.meta.com"

/// The user agent both OIDC/FRLA auth calls send. Pinned; the bytes are part of the request Meta accepted.
private let authUserAgent =
    "Dalvik/2.1.0 (Linux; U; Android 15) [FBAN/Stella;FBAV/289.0.0.25.162;FBSN/Android;FBSV/15;FBLC/en_US]"

/// The URL to open as the Bloks login's `next`, carrying a fresh OIDC `state`.
func metaAuthorizeURL() -> String {
    let query = pyURLEncode([
        ("app_id", metaAppID),
        ("scope", "openid"),
        ("response_type", "code"),
        ("redirect_uri", metaRedirectURI),
        ("state", randomURLSafeToken(16)),
    ])
    return "\(authorizeEndpoint)?\(query)"
}

/// Exchange the OIDC auth code the native flow delivered for an FRLA token. Returns the FRLA to cache.
func exchangeAuthCode(_ code: String) async throws -> String {
    // `urllib.parse.quote(value, safe='')` on each value; the exact body bytes are what the endpoint accepts.
    let body = [
        ("mt_app_id", metaAppID),
        ("oidc_auth_code", code),
        ("redirect_uri", metaRedirectURI),
    ].map { "\($0)=\(pyQuote($1))" }.joined(separator: "&")

    let reply = try await metaAuthPost(tokenExchangeEndpoint, host: "api.accounts.meta.com", body: Array(body.utf8))
    guard let json = jsonObject(reply.body) else { throw ReGlassError.metaRejected(status: reply.status) }
    let token = json["access_token"] as? String ?? ""
    let userID = stringOrNumber(json["user_id"])
    // Require both the access token and the user ID before accepting the exchange.
    guard !token.isEmpty, !userID.isEmpty else { throw ReGlassError.metaRejected(status: reply.status) }
    return token
}

/// Exchange a cached FRLA for the ARAe pairing token. Needs the `AR|` client token from the build.
func exchangeFrla(_ frla: String) async throws -> Token {
    guard let credentials = MetaClientCredentials.current else { throw ReGlassError.missingClientCredentials }
    let body = pyURLEncode([
        ("access_token", credentials.accountRecovery),
        ("frl_access_token", frla),
        // Use lowercase UUIDs for the session and device identifiers.
        ("logging_session_id", UUID().uuidString.lowercased()),
        ("device_id", UUID().uuidString.lowercased()),
        ("format", "json"),
        ("generate_session_cookies", "1"),
        ("generate_analytics_claim", "1"),
    ])
    let reply = try await metaAuthPost("https://\(frlaExchangeHost)/login", host: frlaExchangeHost, body: Array(body.utf8))
    guard let json = jsonObject(reply.body) else { throw ReGlassError.metaRejected(status: reply.status) }
    // An FRLA Meta no longer honours comes back as an error document; the saved login must be renewed.
    if json["error"] != nil { throw ReGlassError.signInRequired }
    guard let token = json["access_token"] as? String, !token.isEmpty else { throw ReGlassError.signInRequired }
    return Token(token, "ar")
}

// MARK: HTTP

private struct AuthReply { let status: Int; let body: [UInt8] }

/// One POST to a fixed Meta HTTPS endpoint: ephemeral session, no cookies, no redirects, no TLS exceptions.
private func metaAuthPost(_ url: String, host: String, body: [UInt8]) async throws -> AuthReply {
    guard let target = URL(string: url), target.scheme == "https", target.host == host,
          target.user == nil, target.password == nil, target.port == nil else {
        throw ReGlassError.network(code: URLError.badURL.rawValue)
    }
    var request = URLRequest(url: target)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue(authUserAgent, forHTTPHeaderField: "User-Agent")
    do {
        let (data, response) = try await MetaAuthSession.shared.upload(for: request, from: Data(body))
        return AuthReply(status: (response as? HTTPURLResponse)?.statusCode ?? -1, body: data.byteArray)
    } catch let error as URLError {
        throw error.code == .cancelled ? ReGlassError.cancelled : ReGlassError.network(code: error.code.rawValue)
    }
}

private enum MetaAuthSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration, delegate: BlockRedirects(), delegateQueue: nil)
    }()
}

/// Refuses every HTTP redirect, so an auth POST can only ever reach the fixed endpoint it was sent to.
final class BlockRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// A JSON string, or a JSON number as its text (never a boolean): Meta has sent ids both ways.
private func stringOrNumber(_ value: Any?) -> String {
    if let text = value as? String { return text }
    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
    return ""
}

/// Reads a Meta auth response as a flat JSON object. The exact bytes don't matter here — only a few string fields
/// are read — so Foundation parses it. Never log the result.
private func jsonObject(_ body: [UInt8]) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any]
}

// MARK: Percent-encoding

/// `secrets.token_urlsafe(n)`: n random bytes, base64url, no padding.
private func randomURLSafeToken(_ byteCount: Int) -> String {
    secureRandomBytes(byteCount).base64EncodedStringURLSafe()
}

private extension Array where Element == UInt8 {
    func base64EncodedStringURLSafe() -> String {
        Data(self).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// `urllib.parse.quote(value, safe='')`, byte for byte.
func pyQuote(_ value: String) -> String { percentEncode(value, plusForSpace: false) }

/// `urllib.parse.urlencode(fields)` over an ordered list of string pairs (quote_plus on each key and value).
func pyURLEncode(_ fields: [(String, String)]) -> String {
    fields.map { percentEncode($0, plusForSpace: true) + "=" + percentEncode($1, plusForSpace: true) }
        .joined(separator: "&")
}

private func percentEncode(_ value: String, plusForSpace: Bool) -> String {
    let hex = Array("0123456789ABCDEF".utf8)
    var out = [UInt8]()
    for byte in value.utf8 {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "~"):
            out.append(byte)
        case UInt8(ascii: " ") where plusForSpace:
            out.append(UInt8(ascii: "+"))
        default:
            out.append(UInt8(ascii: "%"))
            out.append(hex[Int(byte >> 4)])
            out.append(hex[Int(byte & 0x0F)])
        }
    }
    return String(decoding: out, as: UTF8.self)
}
