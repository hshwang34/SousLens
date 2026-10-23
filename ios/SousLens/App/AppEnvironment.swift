import Foundation
import Observation

/// Explore stack destinations. A card is carried when we have one (list tap) so the header can
/// paint before the detail loads; a deep link only has the id.
enum RecipeRoute: Hashable {
    case recipe(id: UUID, card: RecipeCard?)

    static func card(_ card: RecipeCard) -> RecipeRoute { .recipe(id: card.recipeId, card: card) }
}

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
    /// Explore's navigation stack. Deep links push onto it from any tab.
    var exploreRoutes: [RecipeRoute] = []
    /// A link that arrived while signed out; applied once the user is signed in.
    private(set) var pendingDeepLink: DeepLink?

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

    // MARK: - Deep links (brief 003 REC-01)

    /// `onOpenURL` entry point. Unrecognised URLs are ignored. Returns the parsed link for tests.
    @discardableResult
    func open(url: URL) -> DeepLink? {
        guard let link = DeepLink.parse(url) else { return nil }
        open(link)
        return link
    }

    func open(_ link: DeepLink) {
        guard auth.isSignedIn else {
            pendingDeepLink = link
            return
        }
        pendingDeepLink = nil
        switch link {
        case .recipe(let id):
            selectedTab = .explore
            exploreRoutes = [.recipe(id: id, card: nil)]
        }
    }

    /// Called when the signed-in UI appears.
    func applyPendingDeepLink() {
        guard let link = pendingDeepLink else { return }
        open(link)
    }

    #if DEBUG
    /// Tests only: mark the session signed in with a placeholder user, no network.
    func forceSignedInForTests() {
        auth.forceSignedInForTests()
    }
    #endif

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
            // Token, cached user, recipe cache, pending sign-in code: all belong to the old server.
            if let auth {
                auth.serverChanged(to: newValue)
            } else {
                try? recipeCache.clear()
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
