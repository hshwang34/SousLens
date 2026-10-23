import Foundation

/// PRD error envelope: `{"error": {"code", "message", "retryable", "correlation_id"}}`.
struct APIErrorEnvelope: Decodable, Sendable, Equatable {
    struct Body: Decodable, Sendable, Equatable {
        let code: String
        let message: String
        let retryable: Bool
        let correlationId: String?
    }

    let error: Body
}
