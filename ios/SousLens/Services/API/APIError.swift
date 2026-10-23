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
    /// Any other HTTP error that carried the PRD envelope. `details` is the envelope's optional
    /// `details` object (validation problems, conflicting draft id, ...).
    case server(status: Int, code: String, message: String, retryable: Bool, correlationId: String?, details: JSONValue? = nil)
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
        case .server(_, _, let message, _, _, _):
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
        case .server(_, _, _, let retryable, _, _): return retryable
        default: return false
        }
    }

    var correlationId: String? {
        switch self {
        case .unauthorized(_, let id), .http(_, let id), .server(_, _, _, _, let id, _): return id
        default: return nil
        }
    }

    var status: Int? {
        switch self {
        case .unauthorized: return 401
        case .server(let status, _, _, _, _, _), .http(let status, _): return status
        default: return nil
        }
    }

    var details: JSONValue? {
        if case .server(_, _, _, _, _, let details) = self { return details }
        return nil
    }

    // MARK: - Brief 003 detail readers

    /// `422 VALIDATION_ERROR` on publish: the draft's problems, read from `details`.
    /// Accepts `{"problems":[{field,message}]}`, `{"validation":{"problems":[...]}}` or a bare
    /// array of `{field,message}`; anything else yields nil (the envelope message still shows).
    var validationProblems: [DraftProblem]? {
        guard case .server(let status, let code, _, _, _, let details) = self,
              status == 422 || code == "VALIDATION_ERROR",
              let details
        else { return nil }
        let candidates: [JSONValue?] = [details["problems"], details["validation"]?["problems"], details]
        for candidate in candidates {
            if let array = candidate?.arrayValue {
                let problems = array.compactMap { item -> DraftProblem? in
                    guard let field = item["field"]?.stringValue, let message = item["message"]?.stringValue else { return nil }
                    return DraftProblem(field: field, message: message)
                }
                if !problems.isEmpty || !array.isEmpty { return problems }
            }
        }
        return nil
    }

    /// `409 STATE_CONFLICT` on `POST /recipes/{id}/edit`: the draft that already exists.
    var conflictingDraftId: UUID? {
        guard case .server(let status, let code, _, _, _, let details) = self,
              status == 409 || code == "STATE_CONFLICT",
              let raw = details?["draft_id"]?.stringValue
        else { return nil }
        return UUID(uuidString: raw)
    }
}
