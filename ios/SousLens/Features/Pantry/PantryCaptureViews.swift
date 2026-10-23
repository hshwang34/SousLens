import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

// MARK: - Speak / Type instead

struct SpeakCaptureView: View {
    @Bindable var model: SpeakCaptureViewModel
    let onObservation: (PantryObservation) -> Void

    /// Resets to false on release *and* when the system cancels the gesture (scroll, sheet
    /// dismissal, interruption), so the microphone can never stay on after the finger lifts.
    @GestureState private var pressing = false
    @FocusState private var fieldFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("What do you have?")
                        .font(SLFont.title2)
                        .foregroundStyle(SLColor.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("For example: “chicken thighs, two onions, gochujang and honey”. You’ll review every item before anything is added.")
                        .font(SLFont.callout)
                        .foregroundStyle(SLColor.textSecondary)
                }

                if model.mode == .speak {
                    micBlock
                }

                transcriptField

                if let message = model.message {
                    MessageBlock(text: message, isWarning: true, showsSettings: model.permissionDenied)
                }

                Button {
                    Task { await model.findItems() }
                } label: {
                    if model.isSubmitting {
                        ProgressView().tint(.white).frame(maxWidth: .infinity)
                    } else {
                        Text("Find items")
                    }
                }
                .buttonStyle(SLButtonStyle(prominent: true))
                .disabled(!model.canFindItems)
                .slDisabledAppearance(!model.canFindItems)
                .accessibilityIdentifier("speak.findItems")

                modeSwitch
            }
            .padding(Spacing.screen)
        }
        .navigationTitle("Speak")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.endListening() }
        }
        .onChange(of: model.observation) { _, observation in
            if let observation {
                model.observation = nil
                onObservation(observation)
            }
        }
    }

    /// Push-and-hold. Listening is visible the whole time it is on (PRD §13.2, §6.1).
    private var micBlock: some View {
        VStack(spacing: Spacing.md) {
            Text("SousLens listens only while you hold the button. What you say becomes text here; the audio isn’t kept.")
                .font(SLFont.footnote)
                .foregroundStyle(SLColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                Circle()
                    .fill(model.isListening ? SLColor.danger : SLColor.accent)
                    .frame(width: 96, height: 96)
                Image(systemName: model.isListening ? "waveform" : "mic.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .accessibilityHidden(true)
            }
            .scaleEffect(pressing ? 1.08 : 1)
            .animation(.easeOut(duration: 0.15), value: pressing)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressing) { _, state, _ in state = true }
            )
            .onChange(of: pressing) { _, isPressed in
                if isPressed {
                    fieldFocused = false
                    Task { await model.beginListening() }
                } else {
                    model.endListening()
                }
            }
            .accessibilityElement()
            .accessibilityLabel(model.isListening ? "Stop listening" : "Hold to talk")
            .accessibilityHint("Double-tap to start listening, double-tap again to stop")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { Task { await model.toggleListening() } }
            .accessibilityIdentifier("speak.mic")
            .frame(maxWidth: .infinity)

            if let indicator = model.listeningIndicator {
                Label(indicator, systemImage: "mic.fill")
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.danger)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .background(SLColor.surfaceRaised, in: Capsule())
                    .accessibilityIdentifier("speak.listening")
            } else {
                Text(model.isStarting ? "Starting…" : "Hold to talk")
                    .font(SLFont.callout)
                    .foregroundStyle(SLColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var transcriptField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(model.mode == .speak ? "Transcript (edit if it misheard)" : "Type what you have")
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
            TextField("chicken thighs, two onions, gochujang and honey", text: $model.transcript, axis: .vertical)
                .lineLimit(3...8)
                .focused($fieldFocused)
                .textInputAutocapitalization(.never)
                .padding(Spacing.md)
                .background(SLColor.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .disabled(model.isListening)
                .accessibilityIdentifier("speak.transcript")
        }
    }

    @ViewBuilder
    private var modeSwitch: some View {
        if model.mode == .speak {
            Button {
                model.typeInstead()
                fieldFocused = true
            } label: {
                Label("Type instead", systemImage: "keyboard")
            }
            .buttonStyle(SLButtonStyle(prominent: false))
            .accessibilityIdentifier("speak.typeInstead")
        } else if model.canSpeak {
            Button {
                model.useMicrophone()
                fieldFocused = false
            } label: {
                Label("Use the microphone", systemImage: "mic")
            }
            .buttonStyle(SLButtonStyle(prominent: false))
            .accessibilityIdentifier("speak.useMic")
        }
    }
}

// MARK: - Scan

struct ScanCaptureView: View {
    @Bindable var model: ScanCaptureViewModel
    let onObservation: (PantryObservation) -> Void

    @State private var pickerItem: PhotosPickerItem?
    /// Decoded once per photo for the preview (memory only).
    @State private var previewImage: UIImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Scan a shelf or the fridge")
                        .font(SLFont.title2)
                        .foregroundStyle(SLColor.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("The camera turns on only when you tap it and stops right after the photo. The photo is analysed once and not kept. You’ll review every item before anything is added.")
                        .font(SLFont.callout)
                        .foregroundStyle(SLColor.textSecondary)
                }

                viewfinder

                if let message = model.message {
                    MessageBlock(text: message, isWarning: true, showsSettings: model.permissionDenied)
                }

                actions
            }
            .padding(Spacing.screen)
        }
        .navigationTitle("Scan")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                // Loaded into memory; PhotosPicker gives us bytes, never a file we keep.
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await model.usePickedPhoto(data)
                }
                pickerItem = nil
            }
        }
        .onChange(of: model.observation) { _, observation in
            if let observation {
                model.observation = nil
                onObservation(observation)
            }
        }
        .onChange(of: model.photoData) { _, data in
            previewImage = data.flatMap(UIImage.init(data:))
        }
    }

    @ViewBuilder
    private var viewfinder: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .fill(SLColor.surfaceRaised)
            if model.hasPhoto, let image = previewImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("Photo to scan")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.cameraOn, let provider = model.camera as? CameraPreviewProviding {
                CameraPreviewView(session: provider.previewSession)
                    .accessibilityLabel("Camera viewfinder")
            } else {
                VStack(spacing: Spacing.sm) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 44, weight: .light))
                        .accessibilityHidden(true)
                    Text(model.cameraOn ? "Camera on" : "Camera off")
                        .font(SLFont.callout)
                }
                .foregroundStyle(SLColor.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.cameraOn {
                Label("Camera on", systemImage: "circle.fill")
                    .font(SLFont.caption)
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                    .background(SLColor.danger, in: Capsule())
                    .padding(Spacing.sm)
                    .accessibilityIdentifier("scan.cameraOn")
            }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: Spacing.sm) {
            if model.cameraOn {
                Button {
                    Task { await model.capture() }
                } label: {
                    Label("Take photo", systemImage: "camera.circle.fill")
                }
                .buttonStyle(SLButtonStyle(prominent: true))
                .disabled(model.isCapturing)
                .accessibilityIdentifier("scan.capture")
                Button("Turn camera off") {
                    Task { await model.cancelCamera() }
                }
                .buttonStyle(SLButtonStyle(prominent: false))
            } else if model.hasPhoto {
                Button {
                    Task { await model.findItems() }
                } label: {
                    if model.isSubmitting {
                        ProgressView().tint(.white).frame(maxWidth: .infinity)
                    } else {
                        Text("Find items")
                    }
                }
                .buttonStyle(SLButtonStyle(prominent: true))
                .disabled(!model.canFindItems)
                .accessibilityIdentifier("scan.findItems")
                Button("Use a different photo") { model.discardPhoto() }
                    .buttonStyle(SLButtonStyle(prominent: false))
                    .disabled(model.isSubmitting)
            } else {
                if model.canUseCamera {
                    Button {
                        Task { await model.startCamera() }
                    } label: {
                        Label(model.isStartingCamera ? "Starting camera…" : "Start camera", systemImage: "camera")
                    }
                    .buttonStyle(SLButtonStyle(prominent: true))
                    .disabled(model.isStartingCamera)
                    .accessibilityIdentifier("scan.startCamera")
                }
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("Choose photo", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(SLButtonStyle(prominent: !model.canUseCamera))
                .accessibilityIdentifier("scan.choosePhoto")
                if !model.canUseCamera {
                    Text("No camera available here, so choose a photo instead.")
                        .font(SLFont.footnote)
                        .foregroundStyle(SLColor.textSecondary)
                }
            }
        }
    }
}

/// Live viewfinder for the phone camera (device only; the simulator has no camera).
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer {
            // `layerClass` guarantees the type.
            layer as! AVCaptureVideoPreviewLayer // swiftlint:disable:this force_cast
        }
    }

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        if uiView.previewLayer.session !== session { uiView.previewLayer.session = session }
    }

    static func dismantleUIView(_ uiView: PreviewUIView, coordinator: ()) {
        uiView.previewLayer.session = nil
    }
}

/// Inline warning with an optional "Open Settings" for a denied permission.
struct MessageBlock: View {
    let text: String
    var isWarning = false
    var showsSettings = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Label {
                Text(text).font(SLFont.callout)
            } icon: {
                Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "info.circle.fill")
            }
            .foregroundStyle(isWarning ? SLColor.warning : SLColor.textSecondary)
            if showsSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { openURL(url) }
                    .font(SLFont.callout.weight(.semibold))
                    .frame(minHeight: Metrics.minTapTarget)
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SLColor.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
