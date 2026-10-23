import Foundation

/// Brief 004 endpoints (`docs/product/briefs/004-api-contract.md`). `APIClient` is the real
/// implementation; view-model tests inject `FakePantryService`.
protocol PantryService: Sendable {
    /// `GET /pantry`, sorted by `normalized_name`.
    func listPantry() async throws -> [PantryItem]
    /// `POST /pantry` → 201. A duplicate without a `resolution` → 409 `DUPLICATE_PANTRY_ITEM`
    /// (`APIError.pantryConflicts`).
    func addPantryItems(_ items: [NewPantryItem], observationId: UUID?) async throws -> [PantryItem]
    func updatePantryItem(id: UUID, _ patch: PantryItemPatch) async throws -> PantryItem
    /// "Still have it": bumps `last_confirmed_at`.
    func confirmPantryItem(id: UUID) async throws -> PantryItem
    func deletePantryItem(id: UUID) async throws
    /// Spoken or typed text → candidates. Nothing is written to the pantry.
    func observeTranscript(_ transcript: String) async throws -> PantryObservation
    /// One photo (multipart) → candidates. Nothing is written to the pantry.
    func observePhoto(_ photo: PantryPhotoUpload) async throws -> PantryObservation
    /// `POST /recipe-versions/{id}/fit`.
    func fit(recipeVersionId: UUID) async throws -> PantryFit
}

extension APIClient: PantryService {
    func listPantry() async throws -> [PantryItem] {
        let response: ItemsResponse<PantryItem> = try await send(.get("/v1/pantry"))
        return response.items
    }

    func addPantryItems(_ items: [NewPantryItem], observationId: UUID?) async throws -> [PantryItem] {
        let body = try encoder.encode(CreatePantryItemsRequest(items: items, observationId: observationId))
        let response: ItemsResponse<PantryItem> = try await send(.post("/v1/pantry", body: body))
        return response.items
    }

    func updatePantryItem(id: UUID, _ patch: PantryItemPatch) async throws -> PantryItem {
        try await send(.patch("/v1/pantry/\(Self.pathId(id))", body: try encoder.encode(patch)))
    }

    func confirmPantryItem(id: UUID) async throws -> PantryItem {
        try await send(.post("/v1/pantry/\(Self.pathId(id))/confirm", body: Self.emptyObject))
    }

    func deletePantryItem(id: UUID) async throws {
        _ = try await raw(.delete("/v1/pantry/\(Self.pathId(id))"))
    }

    func observeTranscript(_ transcript: String) async throws -> PantryObservation {
        let body = try encoder.encode(TranscriptObservationRequest(mode: "transcript", transcript: transcript))
        return try await send(.post("/v1/pantry/observations", body: body))
    }

    func observePhoto(_ photo: PantryPhotoUpload) async throws -> PantryObservation {
        try await send(.multipart("/v1/pantry/observations", form: MultipartFormData.pantryPhoto(photo)))
    }

    func fit(recipeVersionId: UUID) async throws -> PantryFit {
        try await send(.post("/v1/recipe-versions/\(Self.pathId(recipeVersionId))/fit", body: Self.emptyObject))
    }
}

private struct TranscriptObservationRequest: Encodable {
    let mode: String
    let transcript: String
}

/// Minimal RFC 7578 `multipart/form-data` body. Built in memory and handed to `URLRequest`; the
/// photo bytes are never written to disk (PRD §13.2).
struct MultipartFormData: Sendable, Equatable {
    struct Part: Sendable, Equatable {
        let name: String
        let filename: String?
        let contentType: String?
        let data: Data
    }

    let boundary: String
    private(set) var parts: [Part] = []

    init(boundary: String = "SousLens-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(_ name: String, _ value: String) {
        parts.append(Part(name: name, filename: nil, contentType: nil, data: Data(value.utf8)))
    }

    mutating func addFile(_ name: String, filename: String, contentType: String, data: Data) {
        parts.append(Part(name: name, filename: filename, contentType: contentType, data: data))
    }

    func encoded() -> Data {
        var body = Data()
        func line(_ string: String) { body.append(Data((string + "\r\n").utf8)) }
        for part in parts {
            line("--\(boundary)")
            if let filename = part.filename {
                line("Content-Disposition: form-data; name=\"\(Self.quoted(part.name))\"; filename=\"\(Self.quoted(filename))\"")
            } else {
                line("Content-Disposition: form-data; name=\"\(Self.quoted(part.name))\"")
            }
            if let contentType = part.contentType {
                line("Content-Type: \(contentType)")
            }
            line("")
            body.append(part.data)
            line("")
        }
        line("--\(boundary)--")
        return body
    }

    /// Names and filenames are our own constants, but never let one break the header.
    private static func quoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    /// `mode=photo`, optional `fixture=<stem>` (mock only), `image` as JPEG.
    static func pantryPhoto(_ photo: PantryPhotoUpload, boundary: String = "SousLens-\(UUID().uuidString)") -> MultipartFormData {
        var form = MultipartFormData(boundary: boundary)
        form.addField("mode", "photo")
        if let fixture = photo.fixture, !fixture.isEmpty {
            form.addField("fixture", fixture)
        }
        form.addFile("image", filename: "pantry.jpg", contentType: "image/jpeg", data: photo.jpegData)
        return form
    }
}
