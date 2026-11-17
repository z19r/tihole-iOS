import Foundation

/// A decoded FTL error envelope from a non-2xx response:
///
///     { "error": { "key": "...", "message": "...", "hint": "..." }, "took": 0.0 }
public struct APIError: Error, Equatable, Sendable {
    /// HTTP status code.
    public var status: Int
    /// FTL error key, e.g. "unauthorized".
    public var key: String
    /// Human-readable message.
    public var message: String
    /// Optional remediation hint.
    public var hint: String

    public init(status: Int, key: String = "", message: String = "", hint: String = "") {
        self.status = status
        self.key = key
        self.message = message
        self.hint = hint
    }
}

/// Every failure the client can produce.
public enum PiholeError: Error, Sendable {
    /// FTL answered with a non-2xx status.
    case api(APIError)
    /// Authentication failed and could not be recovered transparently (bad
    /// password, exhausted retries).
    case auth(status: Int, message: String)
    /// Transport-level failure: DNS, connection refused, TLS, timeout.
    case network(operation: String, underlying: Error)
    /// A 2xx response whose body did not match the expected shape.
    case decoding(operation: String, underlying: Error)
    /// The instance URL could not be turned into a request.
    case invalidURL(String)
}

extension PiholeError {
    /// The API error payload, when this is an `.api` failure.
    public var apiError: APIError? {
        if case .api(let error) = self { return error }
        return nil
    }

    /// The HTTP status, when the failure carries one.
    public var status: Int? {
        switch self {
        case .api(let error): return error.status
        case .auth(let status, _): return status
        case .network, .decoding, .invalidURL: return nil
        }
    }
}

extension PiholeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .api(let error):
            let base = error.message.isEmpty ? statusMessage(error.status) : error.message
            if error.hint.isEmpty {
                return "\(base) (status \(error.status))"
            }
            return "\(base) (status \(error.status)). \(error.hint)"
        case .auth(let status, let message):
            return "Authentication failed (status \(status)): \(message)"
        case .network(_, let underlying):
            return underlying.localizedDescription
        case .decoding(let operation, _):
            return "Unexpected response from \(operation)"
        case .invalidURL(let raw):
            return "Invalid instance URL: \(raw)"
        }
    }
}

/// A concise message for an HTTP status, used when a non-2xx response carries
/// no usable FTL error envelope. Never echoes the response body.
func statusMessage(_ status: Int) -> String {
    switch status {
    case 401:
        return "invalid credentials or expired session"
    case 403:
        return "forbidden — the session lacks permission"
    default:
        let text = HTTPURLResponse.localizedString(forStatusCode: status)
        return text.isEmpty ? "unexpected status \(status)" : text.lowercased()
    }
}

/// Wire shape of an FTL error response.
private struct FTLErrorEnvelope: Decodable {
    struct Body: Decodable {
        var key: String?
        var message: String?
        var hint: String?
    }
    var error: Body?
}

/// Turns an error-response body into an `APIError`. A body that cannot be
/// decoded still yields a typed error carrying the status code.
func decodeAPIError(status: Int, data: Data) -> APIError {
    var apiError = APIError(status: status)
    if data.isEmpty {
        apiError.message = "empty error response"
        return apiError
    }
    guard let envelope = try? JSONDecoder().decode(FTLErrorEnvelope.self, from: data) else {
        // Not JSON: surface the (usually short, plain-text) body verbatim.
        apiError.message = String(decoding: data, as: UTF8.self)
        return apiError
    }
    apiError.key = envelope.error?.key ?? ""
    apiError.message = envelope.error?.message ?? ""
    apiError.hint = envelope.error?.hint ?? ""
    if apiError.message.isEmpty {
        // Valid JSON but not an FTL error envelope (a bad-password login
        // returns a session object). Never surface the raw body: it is noisy
        // and can carry session fields.
        apiError.message = statusMessage(status)
    }
    return apiError
}
