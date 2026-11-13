import Foundation

/// PRD error envelope: `{"error": {"code", "message", "retryable", "correlation_id", "details"?}}`.
/// `details` is optional and open-shaped (brief 003: `VALIDATION_ERROR` carries the draft's
/// problems, `STATE_CONFLICT` carries `draft_id`).
struct APIErrorEnvelope: Decodable, Sendable, Equatable {
    struct Body: Decodable, Sendable, Equatable {
        let code: String
        let message: String
        let retryable: Bool
        let correlationId: String?
        let details: JSONValue?
    }

    let error: Body
}
