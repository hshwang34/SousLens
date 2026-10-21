import Foundation
import Observation
import os

/// Owns the signed-in user and the Keychain token. Drives `RootView`.
@MainActor
@Observable
final class AuthStore {
    enum State: Equatable {
        case restoring
        case signedOut
        case signedIn(User)
    }

    private(set) var state: State = .restoring
    /// Message shown on the sign-in screen (restore failure, forced sign-out, ...).
    var banner: String?
    /// Set after `requestCode`; the sign-in screen shows the code step while this is non-nil.
    private(set) var pendingChallenge: DevLoginChallenge?
    private(set) var pendingEmail: String?

    var user: User? {
        if case .signedIn(let user) = state { return user }
        return nil
    }

    var isSignedIn: Bool { user != nil }

    private let api: AuthService
    private let tokenStore: TokenStore
    private let defaults: UserDefaults
    private let recipeCache: RecipeCaching?
    /// Shared with `APIClient`; bumped on every sign-in/out so late 401s from an old session are ignored.
    let generation: SessionGeneration
    private let logger = Logger(subsystem: "com.souslens.ios", category: "auth")
    nonisolated static let cachedUserKey = "auth.cachedUser"
    nonisolated static let hasLaunchedKey = "auth.hasLaunched"

    init(api: AuthService,
         tokenStore: TokenStore,
         defaults: UserDefaults = .standard,
         recipeCache: RecipeCaching? = nil,
         generation: SessionGeneration = SessionGeneration()) {
        self.api = api
        self.tokenStore = tokenStore
        self.defaults = defaults
        self.recipeCache = recipeCache
        self.generation = generation
    }

    /// Called once at launch. A cached user + token signs in immediately (offline-friendly), then
    /// `/v1/me` refreshes in the background; a 401 on that refresh clears everything.
    func restore() async {
        // The Keychain survives an app reinstall but UserDefaults does not: a missing launch flag
        // means a fresh install, so any token left over from the previous install is discarded.
        if !defaults.bool(forKey: Self.hasLaunchedKey) {
            defaults.set(true, forKey: Self.hasLaunchedKey)
            clearCredentials()
        }
        guard tokenStore.currentToken() != nil else {
            state = .signedOut
            return
        }
        if let cached = cachedUser() {
            state = .signedIn(cached)
        }
        do {
            let user = try await api.me()
            cache(user)
            state = .signedIn(user)
            banner = nil
        } catch let error as APIError {
            switch error {
            case .unauthorized:
                forceSignOut(reason: "Your session ended. Please sign in again.")
            default:
                if case .signedIn = state {
                    logger.info("restore: kept cached user; refresh failed: \(error.userMessage, privacy: .public)")
                } else {
                    state = .signedOut
                    banner = error.userMessage
                }
            }
        } catch {
            if case .signedIn = state { return }
            state = .signedOut
            banner = error.localizedDescription
        }
    }

    /// Step 1 of dev sign-in. The backend logs a 6-digit code; nothing is stored yet.
    @discardableResult
    func requestCode(email: String) async throws -> DevLoginChallenge {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let challenge = try await api.requestDevCode(email: trimmed)
        pendingEmail = trimmed
        pendingChallenge = challenge
        banner = nil
        return challenge
    }

    /// Step 2. A wrong or expired code throws `APIError.unauthorized` with the server's message and
    /// leaves `pendingChallenge` in place so the user can retry; no session exists to tear down.
    func verify(challengeId: String, code: String) async throws {
        let response = try await api.verifyDevCode(challengeId: challengeId, code: code.trimmingCharacters(in: .whitespacesAndNewlines))
        generation.advance()
        try tokenStore.save(token: response.accessToken)
        cache(response.user)
        pendingChallenge = nil
        pendingEmail = nil
        banner = nil
        state = .signedIn(response.user)
    }

    /// "Use a different email": back to step 1.
    func cancelPendingChallenge() {
        pendingChallenge = nil
        pendingEmail = nil
    }

    func signOut(reason: String? = nil) {
        forceSignOut(reason: reason)
    }

    /// Invoked by `APIClient` on any 401. A 401 issued under an older generation belongs to a
    /// session that is already gone and must not end the current one.
    func handleUnauthorized(_ event: UnauthorizedEvent) {
        guard isSignedIn, event.generation == generation.current() else { return }
        forceSignOut(reason: "Your session ended. Please sign in again.")
    }

    /// The server address changed: every credential belonged to the old server, so drop them all
    /// whatever `state` says (a token can linger in the Keychain while signed out after a failed
    /// restore). Only a user who was actually signed in sees a banner.
    func serverChanged(to newValue: String) {
        let wasSignedIn = isSignedIn
        cancelPendingChallenge()
        forceSignOut(reason: wasSignedIn ? "Server changed to \(newValue). Sign in again." : nil)
    }

    private func forceSignOut(reason: String?) {
        generation.advance()
        clearCredentials()
        banner = reason
        state = .signedOut
    }

    /// Token, cached user, and cached recipes — everything tied to the signed-in session/server.
    private func clearCredentials() {
        do {
            try tokenStore.clear()
        } catch {
            logger.error("keychain clear failed: \(String(describing: error), privacy: .public)")
        }
        defaults.removeObject(forKey: Self.cachedUserKey)
        do {
            try recipeCache?.clear()
        } catch {
            logger.error("recipe cache clear failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func cache(_ user: User) {
        if let data = try? JSONCoding.makeEncoder().encode(user) {
            defaults.set(data, forKey: Self.cachedUserKey)
        }
    }

    private func cachedUser() -> User? {
        guard let data = defaults.data(forKey: Self.cachedUserKey) else { return nil }
        return try? JSONCoding.makeDecoder().decode(User.self, from: data)
    }
}
