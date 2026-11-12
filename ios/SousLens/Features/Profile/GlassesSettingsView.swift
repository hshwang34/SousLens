import Observation
import SwiftUI
import UIKit

/// Brief 009: Settings → Glasses (glasses build only; the public app has no `glasses`).
/// Every action here is a user tap: register, allow camera, start/stop the preview.
@MainActor
@Observable
final class GlassesSettingsViewModel {
    let glasses: any GlassesController
    private(set) var isWorking = false
    private(set) var previewMessage: String?

    init(glasses: any GlassesController) {
        self.glasses = glasses
    }

    var snapshot: GlassesSnapshot { glasses.snapshot }

    var registrationText: String {
        switch snapshot.registration {
        case .unavailable(let why): return why
        case .notRegistered: return "Not registered"
        case .registering: return "Registering…"
        case .registered: return "Registered"
        }
    }

    var canRegister: Bool {
        snapshot.registration == .notRegistered && !isWorking
    }

    var canUnregister: Bool { snapshot.registration == .registered && !isWorking }

    var permissionText: String {
        switch snapshot.permission {
        case .unknown: return "Not asked yet"
        case .granted: return "Allowed"
        case .denied: return "Not allowed"
        }
    }

    var canRequestPermission: Bool {
        snapshot.registration == .registered && snapshot.permission != .granted && !isWorking
    }

    var batteryText: String? { snapshot.batteryLevel.map { "\($0)%" } }

    var previewOn: Bool { glasses.camera.activeIndicator }
    var canStartPreview: Bool { snapshot.isCameraReady && !previewOn && !isWorking }
    var previewFrame: UIImage? { (glasses.camera as? FramePreviewProviding)?.previewFrame }

    func register() async {
        isWorking = true
        defer { isWorking = false }
        await glasses.register()
    }

    func unregister() async {
        isWorking = true
        defer { isWorking = false }
        await glasses.camera.stopPreview()
        await glasses.unregister()
    }

    func requestPermission() async {
        isWorking = true
        defer { isWorking = false }
        await glasses.requestCameraPermission()
    }

    func startPreview() async {
        previewMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await glasses.camera.startPreview()
        } catch let error as CaptureError where error == .cancelled {
            return
        } catch {
            await glasses.camera.stopPreview()
            previewMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func stopPreview() async {
        await glasses.camera.stopPreview()
    }
}

struct GlassesSettingsView: View {
    @State var model: GlassesSettingsViewModel
    let audioRoute: AudioRouteMonitor

    var body: some View {
        List {
            Section {
                LabeledContent("Meta AI", value: model.registrationText)
                    .accessibilityIdentifier("glasses.registration")
                if model.canRegister {
                    Button {
                        Task { await model.register() }
                    } label: {
                        Label("Register with Meta AI", systemImage: "link")
                    }
                    .accessibilityIdentifier("glasses.register")
                }
                LabeledContent("Glasses camera", value: model.permissionText)
                    .accessibilityIdentifier("glasses.permission")
                if model.canRequestPermission {
                    Button {
                        Task { await model.requestPermission() }
                    } label: {
                        Label("Allow glasses camera", systemImage: "camera")
                    }
                    .accessibilityIdentifier("glasses.allowCamera")
                }
            } header: {
                Text("Setup")
            } footer: {
                Text("Registering opens Meta AI. Developer Mode must be on there (Settings → Your glasses → Developer Mode).")
            }

            Section {
                LabeledContent("Status") {
                    Text(model.snapshot.statusText)
                        .foregroundStyle(model.snapshot.issue == nil ? SLColor.textSecondary : SLColor.warning)
                }
                .accessibilityIdentifier("glasses.status")
                if let name = model.snapshot.deviceName {
                    LabeledContent("Glasses", value: name)
                }
                if let battery = model.batteryText {
                    LabeledContent("Battery", value: battery)
                }
                LabeledContent("Microphone", value: audioRoute.inputLabel)
                    .accessibilityIdentifier("glasses.microphone")
            } header: {
                Text("Device")
            } footer: {
                Text("“Glasses microphone” appears only when iOS routes a Bluetooth headset microphone from your glasses. Folding the glasses never ends or advances a cooking session.")
            }

            Section {
                preview
                if model.previewOn {
                    Button("Stop preview") { Task { await model.stopPreview() } }
                        .accessibilityIdentifier("glasses.stopPreview")
                } else {
                    Button {
                        Task { await model.startPreview() }
                    } label: {
                        Label("Start preview", systemImage: "eye")
                    }
                    .disabled(!model.canStartPreview)
                    .accessibilityIdentifier("glasses.startPreview")
                }
                if let message = model.previewMessage {
                    Text(message)
                        .font(SLFont.footnote)
                        .foregroundStyle(SLColor.warning)
                }
            } header: {
                Text("Camera preview")
            } footer: {
                Text("The glasses camera streams only while this preview or a scan is open. Frames are shown, never saved.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(SLColor.background)
        .navigationTitle("Glasses")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { Task { await model.stopPreview() } }
    }

    @ViewBuilder
    private var preview: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(SLColor.surfaceRaised)
            if model.previewOn, let frame = model.previewFrame {
                // Fill the box without letting a portrait frame grow the row.
                Color.clear
                    .overlay {
                        Image(uiImage: frame)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                    .accessibilityElement()
                    .accessibilityLabel("Glasses camera preview")
            } else {
                VStack(spacing: Spacing.xs) {
                    Image(systemName: "eyeglasses")
                        .font(.system(size: 32, weight: .light))
                        .accessibilityHidden(true)
                    Text(model.previewOn ? "Waiting for the first frame…" : "Preview off")
                        .font(SLFont.footnote)
                }
                .foregroundStyle(SLColor.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.previewOn {
                Label("Glasses camera on", systemImage: "circle.fill")
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.onDanger)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                    .background(SLColor.danger, in: Capsule())
                    .padding(Spacing.sm)
                    .accessibilityIdentifier("glasses.cameraOn")
            }
        }
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .listRowInsets(EdgeInsets(top: Spacing.sm, leading: Spacing.md, bottom: Spacing.sm, trailing: Spacing.md))
    }
}

/// The Profile entry: one status row that opens Settings → Glasses.
struct GlassesProfileSection: View {
    let glasses: any GlassesController
    let audioRoute: AudioRouteMonitor

    var body: some View {
        Section {
            NavigationLink {
                GlassesSettingsView(model: GlassesSettingsViewModel(glasses: glasses), audioRoute: audioRoute)
            } label: {
                LabeledContent {
                    Text(glasses.snapshot.statusText)
                } label: {
                    Label("Meta glasses", systemImage: "eyeglasses")
                }
            }
            .accessibilityIdentifier("profile.glasses")
        } header: {
            Text("Glasses")
        }
    }
}
