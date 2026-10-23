import Foundation
import Observation

/// Speak / Type instead (J2, PAN-02). Push-and-hold listens through `SpeechInput`; release leaves an
/// editable transcript. "Type instead" feeds the same text field, so the flow works without a
/// microphone, without permission, and in the simulator. "Find items" sends the text as a
/// transcript observation: candidates only, nothing is added to the pantry here.
@MainActor
@Observable
final class SpeakCaptureViewModel {
    enum InputMode: Equatable {
        case speak
        case type
    }

    var transcript = "" {
        didSet {
            if transcript.count > PantryLimits.transcript { transcript = String(transcript.prefix(PantryLimits.transcript)) }
        }
    }
    private(set) var mode: InputMode
    private(set) var isListening = false
    private(set) var isStarting = false
    private(set) var isSubmitting = false
    /// Permission / availability / request failure copy.
    private(set) var message: String?
    /// True when the message is a permission denial (the view offers "Open Settings").
    private(set) var permissionDenied = false
    /// Set once the server returns candidates; the view pushes Scan review.
    var observation: PantryObservation?
    /// The task draining the transcript stream; tests await it.
    private(set) var listenTask: Task<Void, Never>?

    private let speech: any SpeechInput
    private let service: PantryService
    /// A release that arrives while the start is still suspended (permission prompt) wins.
    private var releaseRequested = false

    init(speech: any SpeechInput, service: PantryService) {
        self.speech = speech
        self.service = service
        mode = speech.isAvailable ? .speak : .type
        if !speech.isAvailable {
            message = "Speech isn’t available on this device. Type what you have instead."
        }
    }

    var canSpeak: Bool { speech.isAvailable }

    /// PRD §6.1: always say which input is live. Only the phone microphone is claimed here; a
    /// glasses route is never named without a verified HFP route (CLAUDE.md "honest device state").
    var listeningIndicator: String? {
        guard isListening else { return nil }
        return speech.kind == .phone ? "Listening… (iPhone microphone)" : "Listening…"
    }

    var cleanTranscript: String { DraftText.multiLine(transcript, max: PantryLimits.transcript) }
    var canFindItems: Bool { !cleanTranscript.isEmpty && !isListening && !isStarting && !isSubmitting }

    func typeInstead() {
        if isListening || isStarting { endListening() }
        mode = .type
    }

    func useMicrophone() {
        guard speech.isAvailable else { return }
        mode = .speak
    }

    /// Press began.
    func beginListening() async {
        guard speech.isAvailable, !isListening, !isStarting, !isSubmitting else { return }
        isStarting = true
        releaseRequested = false
        message = nil
        permissionDenied = false
        defer { isStarting = false }
        let stream: AsyncStream<TranscriptChunk>
        do {
            stream = try await speech.startListening()
        } catch let error as CaptureError {
            handle(error)
            return
        } catch {
            message = error.localizedDescription
            return
        }
        isListening = true
        let prefix = transcript.isEmpty ? "" : transcript + " "
        listenTask = Task { [weak self] in
            for await chunk in stream {
                // Chunks are cumulative (best transcription so far).
                self?.transcript = prefix + chunk.text
            }
            self?.isListening = false
        }
        if releaseRequested {
            endListening()
        }
    }

    /// Press ended (or VoiceOver toggled off). Audio stops at once; the final words still arrive.
    func endListening() {
        if isStarting { releaseRequested = true }
        speech.stop()
    }

    /// VoiceOver can't press-and-hold: a double tap toggles instead.
    func toggleListening() async {
        if isListening { endListening() } else { await beginListening() }
    }

    func findItems() async {
        let text = cleanTranscript
        guard !text.isEmpty, !isSubmitting else { return }
        if isListening { endListening(); await listenTask?.value }
        isSubmitting = true
        message = nil
        defer { isSubmitting = false }
        do {
            observation = try await service.observeTranscript(text)
        } catch let error as APIError where error == .cancelled {
            return
        } catch {
            message = error.pantryMessage
        }
    }

    private func handle(_ error: CaptureError) {
        switch error {
        case .cancelled:
            return
        case .permissionDenied(_, let explainer):
            permissionDenied = true
            message = explainer + " You can also type instead."
            mode = .type
        case .unavailable:
            message = "Speech isn’t available right now. Type what you have instead."
            mode = .type
        default:
            message = (error.errorDescription ?? "Couldn’t start listening.") + " You can type instead."
        }
    }
}

/// Scan (J2, PAN-03): an explicit tap turns the camera on, one frame is captured, and the camera
/// stops immediately. "Choose photo" is the same path for a picked image. The photo lives only in
/// memory and is dropped as soon as the server has answered (PRD §13.2).
@MainActor
@Observable
final class ScanCaptureViewModel {
    private(set) var isStartingCamera = false
    private(set) var isCapturing = false
    private(set) var isSubmitting = false
    /// Raw bytes of the photo being previewed (camera JPEG or picked image). Memory only.
    private(set) var photoData: Data?
    private(set) var message: String?
    private(set) var permissionDenied = false
    var observation: PantryObservation?

    let camera: any CameraSource
    private let service: PantryService
    private let encode: @Sendable (Data) async throws -> PantryPhotoUpload
    /// Mock-mode fixture stem (debug launch argument only); nil in normal use.
    private let fixture: String?

    init(camera: any CameraSource,
         service: PantryService,
         fixture: String? = nil,
         encode: @escaping @Sendable (Data) async throws -> PantryPhotoUpload = { try await PantryImageEncoder.encodeDetached($0) }) {
        self.camera = camera
        self.service = service
        self.fixture = fixture
        self.encode = encode
    }

    var canUseCamera: Bool { camera.isAvailable }
    /// Drives the visible "Camera on" indicator; read from the source, never assumed.
    var cameraOn: Bool { camera.activeIndicator }
    var hasPhoto: Bool { photoData != nil }
    var canFindItems: Bool { photoData != nil && !isSubmitting && !cameraOn }

    func startCamera() async {
        guard camera.isAvailable, !cameraOn, !isStartingCamera else {
            if !camera.isAvailable { message = "No camera here. Choose a photo instead." }
            return
        }
        isStartingCamera = true
        message = nil
        permissionDenied = false
        defer { isStartingCamera = false }
        do {
            photoData = nil
            try await camera.startPreview()
        } catch let error as CaptureError {
            await camera.stopPreview()
            switch error {
            case .cancelled: return
            case .permissionDenied(_, let explainer):
                permissionDenied = true
                message = explainer + " You can also choose a photo instead."
            default:
                message = (error.errorDescription ?? "The camera didn’t start.") + " You can choose a photo instead."
            }
        } catch {
            await camera.stopPreview()
            message = error.localizedDescription
        }
    }

    /// Takes one frame and stops the camera straight away, whatever happens.
    func capture() async {
        guard cameraOn, !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        do {
            let frame = try await camera.captureFrame()
            await camera.stopPreview()
            photoData = frame.jpegData
        } catch {
            await camera.stopPreview()
            message = "Couldn’t take the photo: \(error.pantryMessage)"
        }
    }

    func cancelCamera() async {
        await camera.stopPreview()
    }

    func usePickedPhoto(_ data: Data) async {
        await camera.stopPreview()
        message = nil
        photoData = data
    }

    func discardPhoto() {
        photoData = nil
    }

    func findItems() async {
        guard let data = photoData, !isSubmitting else { return }
        isSubmitting = true
        message = nil
        defer { isSubmitting = false }
        do {
            var upload = try await encode(data)
            upload.fixture = fixture
            let result = try await service.observePhoto(upload)
            // The server has the candidates; the photo is no longer needed anywhere.
            photoData = nil
            observation = result
        } catch let error as APIError where error == .cancelled {
            return
        } catch {
            // Kept in memory only so "Find items" can be retried; dropped when the sheet closes.
            message = error.pantryMessage
        }
    }

    /// Sheet closing: camera off, photo gone.
    func tearDown() async {
        photoData = nil
        await camera.stopPreview()
    }
}
