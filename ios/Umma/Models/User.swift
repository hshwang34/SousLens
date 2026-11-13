import Foundation

struct User: Codable, Sendable, Identifiable, Hashable {
    enum Units: String, Codable, Sendable, CaseIterable {
        case us
        case metric

        var displayName: String {
            switch self {
            case .us: return "US (cups, °F)"
            case .metric: return "Metric (grams, °C)"
            }
        }
    }

    let id: UUID
    let displayName: String
    let preferenceUnits: Units
    let createdAt: Date
}

struct DevLoginRequest: Encodable, Sendable {
    let email: String
}

/// `POST /v1/auth/dev-login` → 202. The code itself is printed in the backend's log.
struct DevLoginChallenge: Decodable, Sendable, Equatable {
    let challengeId: String
    let expiresInSeconds: Int
    let hint: String?
    /// Client-side receipt time, for the countdown. Not part of the wire payload.
    var receivedAt = Date()

    private enum CodingKeys: String, CodingKey {
        case challengeId, expiresInSeconds, hint
    }

    var expiresAt: Date { receivedAt.addingTimeInterval(TimeInterval(expiresInSeconds)) }
}

struct DevLoginVerifyRequest: Encodable, Sendable {
    let challengeId: String
    let code: String
}

struct AuthResponse: Decodable, Sendable {
    let accessToken: String
    let tokenType: String
    let user: User
}

struct HealthResponse: Decodable, Sendable, Equatable {
    let status: String
    let version: String
    let aiProvider: String
}
