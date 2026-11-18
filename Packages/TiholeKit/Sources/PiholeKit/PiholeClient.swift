import Foundation

/// Pi-hole v6 FTL REST API client for a single instance.
///
/// It manages a session (`X-FTL-SID` header auth) and transparently
/// re-authenticates once on a 401. Being an actor, it is safe to call from
/// any number of concurrent tasks; overlapping 401s share a single login so a
/// burst of parallel fetches never exhausts FTL's session seats.
///
/// The password and session ID are never logged.
public actor PiholeClient {
    /// Instance host root, e.g. "https://pi.hole" (no trailing "/api").
    public nonisolated let baseURL: String

    nonisolated let apiURL: String
    nonisolated let session: URLSession
    nonisolated let timeout: TimeInterval

    private let ownsSession: Bool
    private let password: String

    private var sid: String?
    private var loginTask: Task<Void, Error>?

    /// Creates a client.
    ///
    /// - Parameters:
    ///   - baseURL: Instance host root with scheme, e.g. "https://192.168.1.2".
    ///     A trailing slash or "/api" suffix is normalized away.
    ///   - password: App password (preferred) or web password.
    ///   - verifyTLS: Pass false to accept a self-signed certificate from this
    ///     instance's host. Other hosts are still verified.
    ///   - timeout: Per-request timeout in seconds.
    ///   - session: Overrides the URLSession (tests, custom transports). When
    ///     given, `verifyTLS` is ignored.
    public init(
        baseURL: String,
        password: String,
        verifyTLS: Bool = true,
        timeout: TimeInterval = 10,
        session: URLSession? = nil
    ) {
        let root = PiholeClient.normalize(baseURL)
        self.baseURL = root
        self.apiURL = root + "/api"
        self.password = password
        self.timeout = timeout

        if let session {
            self.session = session
            self.ownsSession = false
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            // Header auth only. FTL also sets a session cookie at login, and
            // echoing it back would switch the server to cookie mode, which
            // demands a CSRF token.
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil

            let delegate: URLSessionDelegate?
            if verifyTLS {
                delegate = nil
            } else {
                delegate = InsecureTrustDelegate(host: URL(string: root)?.host)
            }
            self.session = URLSession(
                configuration: configuration,
                delegate: delegate,
                delegateQueue: nil
            )
            self.ownsSession = true
        }
    }

    deinit {
        if ownsSession {
            session.invalidateAndCancel()
        }
    }

    /// Strips trailing slashes and an "/api" suffix from an instance URL.
    static func normalize(_ baseURL: String) -> String {
        var root = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while root.hasSuffix("/") {
            root.removeLast()
        }
        if root.hasSuffix("/api") {
            root.removeLast(4)
        }
        return root
    }

    // MARK: - Session state

    /// The current session ID, or nil when not authenticated. For tests and
    /// diagnostics; callers must not log it.
    var sessionID: String? { sid }

    func setSessionID(_ value: String?) {
        sid = value
    }

    // MARK: - Transport

    /// Performs an authenticated request against `path` (which starts with
    /// "/" and is relative to the /api root) and returns the 2xx body. On a
    /// 401 it logs in once and retries. Non-2xx responses throw
    /// `PiholeError.api`.
    func perform(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        try await send(method, path, body: body, allowRetry: true, sendAuth: true)
    }

    /// Issues a single request. With `allowRetry`, a 401 re-authenticates
    /// (single-flight) and retries exactly once. `sendAuth` controls whether
    /// the stored session ID is attached; login passes false so it never
    /// sends a stale session.
    private func send(
        _ method: String,
        _ path: String,
        body: Data?,
        allowRetry: Bool,
        sendAuth: Bool
    ) async throws -> Data {
        let operation = method + " " + path
        var request = try makeRequest(method, path)
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Remember the session we send so re-auth can tell whether another
        // task already refreshed it.
        var sentSID: String?
        if sendAuth, let sid, !sid.isEmpty {
            sentSID = sid
            request.setValue(sid, forHTTPHeaderField: "X-FTL-SID")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PiholeClient.mapTransportError(error, operation: operation)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PiholeError.network(
                operation: operation,
                underlying: URLError(.badServerResponse)
            )
        }

        if http.statusCode == 401 && allowRetry {
            try await reauth(staleSID: sentSID)
            return try await send(
                method,
                path,
                body: body,
                allowRetry: false,
                sendAuth: sendAuth
            )
        }

        guard (200..<300).contains(http.statusCode) else {
            throw PiholeError.api(decodeAPIError(status: http.statusCode, data: data))
        }
        return data
    }

    private func makeRequest(_ method: String, _ path: String) throws -> URLRequest {
        guard let url = URL(string: apiURL + path), url.host != nil else {
            throw PiholeError.invalidURL(apiURL + path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        return request
    }

    /// Cancellation surfaces as `CancellationError` so callers can ignore it;
    /// everything else becomes a `.network` failure.
    static func mapTransportError(_ error: Error, operation: String) -> Error {
        if error is CancellationError {
            return error
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return CancellationError()
        }
        if error is PiholeError {
            return error
        }
        return PiholeError.network(operation: operation, underlying: error)
    }

    // MARK: - Auth

    /// Re-authenticates at most once across concurrent callers. `staleSID` is
    /// the session the failed request sent (nil if none). If the stored
    /// session has already moved past it, another task logged in while this
    /// one waited and there is nothing to do.
    private func reauth(staleSID: String?) async throws {
        if let current = sid, !current.isEmpty, current != staleSID {
            return
        }
        if let inFlight = loginTask {
            try await inFlight.value
            return
        }
        let task = Task { try await self.performLogin() }
        loginTask = task
        defer { loginTask = nil }
        try await task.value
    }

    /// Authenticates with the stored password and stores the returned
    /// session ID. 2FA is not supported: an app password bypasses it.
    private func performLogin() async throws {
        let body = try encodeJSON(LoginRequest(password: password))

        let data: Data
        do {
            data = try await send("POST", "/auth", body: body, allowRetry: false, sendAuth: false)
        } catch let error as PiholeError {
            if case .api(let apiError) = error {
                throw PiholeError.auth(status: apiError.status, message: apiError.message)
            }
            throw error
        }

        let envelope = try decode(SessionEnvelope.self, from: data, operation: "POST /auth")
        let session = envelope.session
        guard session.valid, !session.sid.isEmpty else {
            let message = session.message.isEmpty
                ? "login did not return a valid session"
                : session.message
            throw PiholeError.auth(status: 401, message: message)
        }
        sid = session.sid
    }

    /// Authenticates and stores a session. Optional: every request also logs
    /// in on demand.
    public func login() async throws {
        if let inFlight = loginTask {
            try await inFlight.value
            return
        }
        let task = Task { try await self.performLogin() }
        loginTask = task
        defer { loginTask = nil }
        try await task.value
    }

    /// Ends the current session via `DELETE /api/auth` and forgets the
    /// session ID. A no-op when there is no session. The session ID is
    /// forgotten even if the request fails, so a later call starts clean.
    public func logout() async throws {
        guard let current = sid, !current.isEmpty else { return }
        defer { sid = nil }
        _ = try await send("DELETE", "/auth", body: nil, allowRetry: false, sendAuth: true)
    }

    // MARK: - Gravity stream

    /// Triggers `POST /api/action/gravity` and yields its progress output
    /// line by line until the stream closes.
    ///
    /// Unlike every other endpoint this response is neither JSON nor SSE: it
    /// is a raw chunked text stream. On a 401 it re-authenticates once and
    /// retries. Cancelling the consuming task stops the stream.
    public nonisolated func updateGravity(
        timeout: TimeInterval = 300
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.streamGravity(timeout: timeout, allowRetry: true) { line in
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func streamGravity(
        timeout: TimeInterval,
        allowRetry: Bool,
        onLine: @Sendable (String) -> Void
    ) async throws {
        let operation = "POST /action/gravity"
        var request = try makeRequest("POST", "/action/gravity")
        request.timeoutInterval = timeout
        request.setValue("text/plain", forHTTPHeaderField: "Accept")

        var sentSID: String?
        if let sid, !sid.isEmpty {
            sentSID = sid
            request.setValue(sid, forHTTPHeaderField: "X-FTL-SID")
        }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw PiholeClient.mapTransportError(error, operation: operation)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PiholeError.network(
                operation: operation,
                underlying: URLError(.badServerResponse)
            )
        }

        if http.statusCode == 401 && allowRetry {
            try await reauth(staleSID: sentSID)
            try await streamGravity(timeout: timeout, allowRetry: false, onLine: onLine)
            return
        }

        do {
            guard (200..<300).contains(http.statusCode) else {
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                    if data.count >= 64 * 1024 { break }
                }
                throw PiholeError.api(decodeAPIError(status: http.statusCode, data: data))
            }

            for try await line in bytes.lines {
                try Task.checkCancellation()
                onLine(line)
            }
        } catch {
            throw PiholeClient.mapTransportError(error, operation: operation)
        }
    }

    // MARK: - Coding helpers

    nonisolated func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        operation: String
    ) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw PiholeError.decoding(operation: operation, underlying: error)
        }
    }

    nonisolated func encodeJSON<B: Encodable>(_ body: B) throws -> Data {
        try JSONEncoder().encode(body)
    }
}

/// Body of `POST /api/auth`.
private struct LoginRequest: Encodable {
    let password: String
}

/// Accepts the server certificate for one named host without verifying it.
/// Self-signed certificates are common on Pi-hole installs; this is opt-in per
/// instance and never applies to any other host.
final class InsecureTrustDelegate: NSObject, URLSessionDelegate {
    let host: String?

    init(host: String?) {
        self.host = host
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust,
              let host,
              space.host.caseInsensitiveCompare(host) == .orderedSame
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

// MARK: - Path escaping

/// URL escaping that matches Go's `url.PathEscape` / `url.QueryEscape`, so the
/// wire format is identical to the tihole TUI's.
enum Escape {
    private static let alphanumerics =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

    /// Characters left bare in a path segment: unreserved plus `$&+=:@`.
    static let segmentAllowed = CharacterSet(charactersIn: alphanumerics + "-_.~$&+=:@")

    /// Characters left bare in a query value: unreserved only.
    static let queryAllowed = CharacterSet(charactersIn: alphanumerics + "-_.~")

    /// Escapes a value for use as exactly one path segment. Regex domains and
    /// "IP domain" config values carry reserved characters, so "/" and "," and
    /// spaces are all percent-encoded.
    static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? value
    }

    static func query(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? value
    }

    /// Escapes each dotted segment of a config element path ("dns.upstreams")
    /// and joins them with "/".
    static func element(_ dotted: String) -> String {
        dotted
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { segment(String($0)) }
            .joined(separator: "/")
    }

    /// Renders key/value pairs as a query string, sorted by key. Returns ""
    /// for no pairs, otherwise a string starting with "?".
    static func queryString(_ items: [(String, String)]) -> String {
        if items.isEmpty { return "" }
        let sorted = items.sorted { $0.0 < $1.0 }
        return "?" + sorted
            .map { query($0.0) + "=" + query($0.1) }
            .joined(separator: "&")
    }
}
