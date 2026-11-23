import Foundation

/// Talks to Meta's Bloks GraphQL endpoint for the logged-out native login. One fixed TLS endpoint, no cookies, no
/// redirects, no response-body diagnostics. Returns the raw bundle string for each query; the session parses it.
///
/// Immutable after init (the token, locale, and session are all `let`), so it is `Sendable` and the session can
/// run the HTTPS call off the main actor.
final class BloksClient: Sendable {
    private let token: String
    private let locale: String
    private let session: URLSession

    init(token: String, locale: String = "en_US") {
        self.token = token
        self.locale = locale
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration, delegate: BlockRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func screen(_ appId: String, _ params: String) async throws -> String {
        try await query("6165507603411378493763367459", "FrlBloksAppRootQuery", appId, params, screen: true)
    }

    func action(_ appId: String, _ params: String) async throws -> String {
        try await query("25388939413601934797287790300", "FrlBloksAsyncActionQuery", appId, params)
    }

    func component(_ appId: String, _ params: String) async throws -> String {
        let text = try await query("26656874278801481548161588323", "FrlBloksAsyncComponentQuery", appId, params, component: true)
        guard let root = try BloksJson.decode(text) as? BloksMap,
              let response = blist(root.get("component_query_responses")).first as? BloksMap,
              let json = response.get("payload") as? String,
              let nested = try BloksJson.decode(json) as? BloksMap,
              let first = blist(nested.get("components")).first as? BloksMap,
              let payload = first.get("payload") as? BloksMap
        else { throw BloksError("Missing component payload") }
        return try BloksJson.encode(payload)
    }

    private func query(_ doc: String, _ friendlyName: String, _ appId: String, _ params: String,
                       screen: Bool = false, component: Bool = false) async throws -> String {
        try Task.checkCancellation()
        guard !token.isEmpty else { throw BloksError("Native login client is missing from this build.") }
        guard appId.hasPrefix("com.bloks."), appId.count < 512, params.utf8.count < 1_000_000 else { throw BloksError("Unsupported login request") }
        // Keep the version hash, query IDs and function table aligned with the same sign-in schema.
        let context = BloksMap([
            ("is_flipper_enabled", false), ("debug_tooling_metadata_token", nil), ("android_device_performance_class", nil),
            ("android_os_api_level", Int32(35)), ("gpu_memory_mb", Int32(4096)),
        ])
        if screen { context.set("pixel_ratio", 3.0) }
        let variables = BloksMap([
            ("params", BloksMap([
                ("app_id", appId),
                ("bloks_versioning_id", "563d6e0947a986c84a526eed86f47bc9f456d52f386d4757475b045e577e0541"),
                ("params", params),
            ])),
            ("bk_context", context),
        ])
        let name = friendlyName + "-" + appId
        let body = pyURLEncode([
            ("method", "post"), ("format", "json"), ("server_timestamps", "true"), ("locale", locale),
            ("fb_api_req_friendly_name", name), ("client_doc_id", doc), ("variables", try BloksJson.encode(variables)),
        ])
        let reply = try await post(
            "https://meta.graph.meta.com/graphql?locale=" + pyQuote(locale),
            headers: [
                "Authorization": "OAuth " + token,
                "Content-Type": "application/x-www-form-urlencoded",
                "User-Agent": "Dalvik/2.1.0 (Linux; U; Android 15) [FBAN/Stella;FBAV/294.1.0.25.165;FBSN/Android;FBSV/15;FBLC/en_US]",
                "X-FB-Friendly-Name": name,
            ],
            body: Array(body.utf8)
        )
        try Task.checkCancellation()
        guard reply.status == 200 else { throw BloksError("Native login: HTTP \(reply.status) (response withheld)") }
        guard reply.body.count < 4_000_000,
              let root = try BloksJson.decode(String(decoding: reply.body, as: UTF8.self)) as? BloksMap,
              let data = root.get("data") as? BloksMap else { throw BloksError("Native login returned no data (response withheld)") }
        var value: Any? = data
        let path = component ? ["bloks_component_query", "bloks_bundle_component_query"]
            : screen ? ["bloks_app", "bloks_bundle", "bloks_bundle_tree"]
            : ["bloks_action", "action", "action_bundle", "bloks_bundle_action"]
        for key in path { value = (value as? BloksMap)?.get(key) }
        guard let bundle = value as? String else { throw BloksError("Native login returned no bundle (response withheld)") }
        return bundle
    }

    private struct Reply { let status: Int; let body: [UInt8] }

    private func post(_ url: String, headers: [String: String], body: [UInt8]) async throws -> Reply {
        guard let target = URL(string: url), target.scheme == "https", target.host == "meta.graph.meta.com",
              target.path == "/graphql", target.user == nil, target.password == nil, target.port == nil else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.upload(for: request, from: Data(body))
        return Reply(status: (response as? HTTPURLResponse)?.statusCode ?? -1, body: data.byteArray)
    }
}
