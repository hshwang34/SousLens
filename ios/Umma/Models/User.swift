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

    /// Brief 015: what brought the user here. Unknown values from a newer server read as `nil`.
    enum Role: String, Codable, Sendable, CaseIterable {
        case cook
        case creator
    }

    let id: UUID
    let displayName: String
    let preferenceUnits: Units
    let createdAt: Date
    /// `nil` from an older server or a cached user saved before brief 012; treated as `free`.
    var entitlement: Entitlement? = nil
    /// Brief 015: `nil` until first-run onboarding is finished (the app shows it until then).
    var onboardedAt: Date? = nil
    var role: Role? = nil

    var needsOnboarding: Bool { onboardedAt == nil }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, preferenceUnits, createdAt, entitlement, onboardedAt, role
    }

    init(id: UUID, displayName: String, preferenceUnits: Units, createdAt: Date,
         entitlement: Entitlement? = nil, onboardedAt: Date? = nil, role: Role? = nil) {
        self.id = id
        self.displayName = displayName
        self.preferenceUnits = preferenceUnits
        self.createdAt = createdAt
        self.entitlement = entitlement
        self.onboardedAt = onboardedAt
        self.role = role
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        preferenceUnits = try c.decode(Units.self, forKey: .preferenceUnits)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        entitlement = try c.decodeIfPresent(Entitlement.self, forKey: .entitlement)
        onboardedAt = try c.decodeIfPresent(Date.self, forKey: .onboardedAt)
        // An unknown role from a newer server is treated as "not chosen", not a decode failure.
        role = try? c.decodeIfPresent(Role.self, forKey: .role)
    }
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
