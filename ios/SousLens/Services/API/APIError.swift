import Foundation

/// Every failure the UI can see. `userMessage` is safe to show verbatim.
enum APIError: Error, Equatable, Sendable {
    /// No server URL configured (physical device before setup).
    case noServerConfigured
    case invalidURL(String)
    /// Could not reach the server at all (connection refused, DNS, timeout).
    case unreachable(baseURL: String, underlying: String)
    /// HTTP 401. `message` is the server's envelope message when present (e.g. a wrong sign-in code).
    case unauthorized(message: String?, correlationId: String?)
    /// Any other HTTP error that carried the PRD envelope.
    case server(status: Int, code: String, message: String, retryable: Bool, correlationId: String?)
    /// Non-2xx with no parseable envelope.
    case http(status: Int, correlationId: String?)
    case decoding(String)
    case cancelled

    var userMessage: String {
        switch self {
        case .noServerConfigured:
            return "Set the server address in Profile → Server settings to continue."
        case .invalidURL(let raw):
            return "“\(raw)” is not a valid server address."
        case .unreachable(let baseURL, _):
            return "Can’t reach the server at \(baseURL). Is the backend running?"
        case .unauthorized(let message, _):
            return message ?? "Your session ended. Please sign in again."
        case .server(_, _, let message, _, _):
            return message
        case .http(let status, _):
            return "The server returned an unexpected error (HTTP \(status))."
        case .decoding:
            return "The server sent something this build doesn’t understand."
        case .cancelled:
            return "Cancelled."
        }
    }

    var isRetryable: Bool {
        switch self {
        case .unreachable, .http: return true
        case .server(_, _, _, let retryable, _): return retryable
        default: return false
        }
    }

    var correlationId: String? {
        switch self {
        case .unauthorized(_, let id), .http(_, let id), .server(_, _, _, _, let id): return id
        default: return nil
        }
    }
}
