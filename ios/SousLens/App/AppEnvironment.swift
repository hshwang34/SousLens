import Foundation
import Observation

/// Composition root. Everything a screen needs is injected from here via `.environment(_:)`.
@MainActor
@Observable
final class AppEnvironment {
    enum Tab: Hashable {
        case explore, saved, pantry, profile
    }

    let serverSettings: ServerSettings
    let api: APIClient
    let auth: AuthStore
    let recipeCache: RecipeCache
    let captureFlags: CaptureFeatureFlags
    let camera: any CameraSource
    let speech: any SpeechInput
    let audio: any AudioOutput

    var selectedTab: Tab = .explore

    init(serverSettings: ServerSettings,
         api: APIClient,
         auth: AuthStore,
         recipeCache: RecipeCache,
         captureFlags: CaptureFeatureFlags,
         camera: any CameraSource,
         speech: any SpeechInput,
         audio: any AudioOutput) {
        self.serverSettings = serverSettings
        self.api = api
        self.auth = auth
        self.recipeCache = recipeCache
        self.captureFlags = captureFlags
        self.camera = camera
        self.speech = speech
        self.audio = audio
    }

    /// Production wiring: Keychain token, UserDefaults server URL, real capture adapters behind flags.
    static func live(defaults: UserDefaults = .standard) -> AppEnvironment {
        let tokenStore = KeychainTokenStore()
        let generation = SessionGeneration()
        let recipeCache = RecipeCache()
        let api = APIClient(
            baseURLProvider: UserDefaultsBaseURLProvider(defaults: defaults),
            tokenProvider: tokenStore,
            sessionGeneration: generation
        )
        let auth = AuthStore(api: api, tokenStore: tokenStore, defaults: defaults,
                             recipeCache: recipeCache, generation: generation)
        let settings = ServerSettings(defaults: defaults)
        bind(api: api, auth: auth, settings: settings, recipeCache: recipeCache)
        let flags = CaptureFeatureFlags.load(from: defaults)
        return AppEnvironment(
            serverSettings: settings,
            api: api,
            auth: auth,
            recipeCache: recipeCache,
            captureFlags: flags,
            camera: flags.phoneCamera ? PhoneCameraSource() : FakeCameraSource(isAvailable: false),
            speech: flags.phoneSpeech ? PhoneSpeechInput() : FakeSpeechInput(isAvailable: false),
            audio: flags.systemAudio ? SystemAudioOutput() : FakeAudioOutput(isAvailable: false)
        )
    }

    /// Cross-object wiring shared by `live()` and tests:
    /// - any 401 → `AuthStore.handleUnauthorized` (generation-checked);
    /// - a committed server URL change → sign out (token + cached user) and drop the recipe cache,
    ///   because tokens and recipe ids belong to one backend.
    static func bind(api: APIClient, auth: AuthStore, settings: ServerSettings, recipeCache: RecipeCaching) {
        api.events.onUnauthorized { event in
            Task { @MainActor in auth.handleUnauthorized(event) }
        }
        settings.onEffectiveBaseURLChanged = { [weak auth] _, newValue in
            try? recipeCache.clear()
            guard let auth else { return }
            // A sign-in code challenge belongs to the old server too.
            auth.cancelPendingChallenge()
            if auth.isSignedIn {
                auth.signOut(reason: "Server changed to \(newValue). Sign in again.")
            }
        }
    }

    /// Previews: memory-only token, fake adapters, no Keychain or disk writes.
    static func preview(signedIn: Bool = true) -> AppEnvironment {
        let defaults = UserDefaults(suiteName: "preview.\(UUID().uuidString)") ?? .standard
        let tokenStore = InMemoryTokenStore(token: signedIn ? "preview-token" : nil)
        let api = APIClient(
            baseURLProvider: StaticBaseURLProvider(baseURL: URL(string: "http://localhost:8000")),
            tokenProvider: tokenStore
        )
        let auth = AuthStore(api: api, tokenStore: tokenStore, defaults: defaults)
        return AppEnvironment(
            serverSettings: ServerSettings(defaults: defaults),
            api: api,
            auth: auth,
            recipeCache: RecipeCache(directory: FileManager.default.temporaryDirectory.appending(path: "preview-cache")),
            captureFlags: .allOn,
            camera: FakeCameraSource(),
            speech: FakeSpeechInput(),
            audio: FakeAudioOutput()
        )
    }
}
