import Foundation
import XCTest
@testable import SousLensGlasses

/// Polls on the main actor until `condition` holds (DAT callbacks hop through `Task { @MainActor }`).
@MainActor
func waitUntil(_ description: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line,
               _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("Timed out waiting for: \(description)", file: file, line: line)
            return
        }
        try? await Task.sleep(for: .milliseconds(50))
    }
}

/// Records the photo that reaches `POST /pantry/observations` (the endpoint the iPhone camera uses).
final class RecordingPantryService: PantryService, @unchecked Sendable {
    private let lock = NSLock()
    private var _photos: [PantryPhotoUpload] = []
    var photos: [PantryPhotoUpload] { lock.withLock { _photos } }

    func observePhoto(_ photo: PantryPhotoUpload) async throws -> PantryObservation {
        lock.withLock { _photos.append(photo) }
        return PantryObservation(observationId: UUID(), mode: .photo, provider: "mock", candidates: [],
                                 unknowns: [], requiresConfirmation: true, expiresAt: Date().addingTimeInterval(600))
    }

    func listPantry() async throws -> [PantryItem] { [] }
    func addPantryItems(_ items: [NewPantryItem], observationId: UUID?) async throws -> [PantryItem] { [] }
    func updatePantryItem(id: UUID, _ patch: PantryItemPatch) async throws -> PantryItem { throw APIError.cancelled }
    func confirmPantryItem(id: UUID) async throws -> PantryItem { throw APIError.cancelled }
    func deletePantryItem(id: UUID) async throws {}
    func observeTranscript(_ transcript: String) async throws -> PantryObservation { throw APIError.cancelled }
    func fit(recipeVersionId: UUID) async throws -> PantryFit { throw APIError.cancelled }
}

/// Counts every cooking call, so a test can prove the glasses never touched a session.
final class RecordingCookingService: CookingService, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.withLock { _calls } }
    private func record(_ name: String) { lock.withLock { _calls.append(name) } }

    let summary = SessionSummary(id: UUID(), recipeVersionId: UUID(), recipeId: UUID(), title: "Kimchi fried rice",
                                 status: .active, stepIndex: 2, stepsCount: 6, updatedAt: Date())

    func activeSessions() async throws -> [SessionSummary] { record("activeSessions"); return [summary] }
    func suggestSubstitutions(recipeVersionId: UUID, ingredientRef: String) async throws -> SubstitutionResult { record("suggest"); throw APIError.cancelled }
    func createSession(recipeVersionId: UUID, adaptations: [AdaptationInput]) async throws -> CookingSession { record("create"); throw APIError.cancelled }
    func session(id: UUID) async throws -> CookingSession { record("session"); throw APIError.cancelled }
    func deleteSession(id: UUID) async throws { record("delete") }
    func sendCommand(sessionId: UUID, _ command: SessionCommand, idempotencyKey: String) async throws -> CookingSession { record("command"); throw APIError.cancelled }
    func ask(sessionId: UUID, query: String, groundedRevision: Int) async throws -> AskResponse { record("ask"); throw APIError.cancelled }
    func addNote(sessionId: UUID, text: String, idempotencyKey: String) async throws -> SessionNote { record("note"); throw APIError.cancelled }
    func myVariation(recipeVersionId: UUID) async throws -> PrivateVariation? { record("variation"); return nil }
    func deleteMyVariation(recipeVersionId: UUID) async throws { record("deleteVariation") }
}
