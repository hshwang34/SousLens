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

    /// Brief 012 tier. Server AI (Paid voice, coach AI, Look, pantry photo, video) is gated on
    /// it server-side; the app only uses it to pick a voice transport.
    enum Entitlement: String, Codable, Sendable {
        case free
        case paid

        /// An unknown value from a newer server reads as `free`: never assume server AI.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Entitlement(rawValue: raw) ?? .free
        }
    }

    let id: UUID
    let displayName: String
    let preferenceUnits: Units
    let createdAt: Date
    /// `nil` from an older server or a cached user saved before brief 012; treated as `free`.
    var entitlement: Entitlement? = nil
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
