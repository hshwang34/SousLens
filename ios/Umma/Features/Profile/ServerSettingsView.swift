import SwiftUI

/// Base URL override. Reached from the gear on Profile and from the sign-in screen.
struct ServerSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    private enum Probe: Equatable {
        case idle
        case running
        case ok(HealthResponse)
        case failed(String)
    }

    @State private var probe: Probe = .idle
    /// Edited locally; committed to `ServerSettings` on Save so a half-typed URL never signs the
    /// user out mid-keystroke.
    @State private var draft = ""

    private var draftIsValid: Bool { ServerSettings.validate(ServerSettings.effective(draft)) != nil }
    private var draftIsConfigured: Bool { !ServerSettings.effective(draft).isEmpty }
    private var hasUnsavedChanges: Bool { draft != environment.serverSettings.baseURLText }

    var body: some View {
        List {
            Section {
                TextField("http://192.168.1.20:8000", text: $draft)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { save() }
                    .font(SLFont.body.monospaced())
                    .frame(minHeight: Metrics.minTapTarget - 12)
                    .accessibilityLabel("Server base URL")
                if !draftIsValid {
                    Label(draftIsConfigured ? "Enter an http:// or https:// address with a host." : "No server set. Enter your Mac’s LAN address, e.g. http://192.168.1.20:8000.",
                          systemImage: "exclamationmark.circle")
                        .font(SLFont.footnote)
                        .foregroundStyle(SLColor.danger)
                }
            } header: {
                Text("Base URL")
            } footer: {
                Text(footerText)
            }

            Section {
                Button {
                    save()
                } label: {
                    Text("Save")
                        .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget - 12)
                }
                .disabled(!draftIsValid || !hasUnsavedChanges)

                Button {
                    Task { await runProbe() }
                } label: {
                    HStack {
                        Text("Test connection")
                        Spacer()
                        if probe == .running { ProgressView() }
                    }
                    .frame(minHeight: Metrics.minTapTarget - 12)
                }
                .disabled(!environment.serverSettings.isValid || probe == .running || hasUnsavedChanges)

                switch probe {
                case .idle, .running:
                    EmptyView()
                case .ok(let health):
                    Label("Connected · v\(health.version) · AI \(health.aiProvider)",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(SLColor.success)
                        .font(SLFont.footnote)
                case .failed(let message):
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(SLColor.danger)
                        .font(SLFont.footnote)
                }

                Button("Reset to default") {
                    draft = ServerSettings.platformDefault
                    save()
                }
                .disabled(environment.serverSettings.baseURLText == ServerSettings.platformDefault && draft == ServerSettings.platformDefault)
            } footer: {
                if environment.auth.isSignedIn {
                    Text("Saving a different server signs you out, because your session and cached recipes belong to the current one.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(SLColor.background)
        .navigationTitle("Server settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { draft = environment.serverSettings.baseURLText }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    if draftIsValid, hasUnsavedChanges { save() }
                    dismiss()
                }
            }
        }
    }

    private func save() {
        guard draftIsValid else { return }
        environment.serverSettings.baseURLText = draft
        probe = .idle
    }

    private var footerText: String {
        #if targetEnvironment(simulator)
        return "The simulator shares the Mac’s network, so http://localhost:8000 reaches `make backend-dev`."
        #else
        return "A physical iPhone must use the Mac’s LAN IP (System Settings → Wi‑Fi → Details), on the same network as the backend."
        #endif
    }

    private func runProbe() async {
        probe = .running
        do {
            let health = try await environment.api.health()
            probe = .ok(health)
        } catch let error as APIError {
            probe = .failed(error.userMessage)
        } catch {
            probe = .failed(error.localizedDescription)
        }
    }
}

#Preview {
    NavigationStack { ServerSettingsView() }.environment(AppEnvironment.preview())
}
