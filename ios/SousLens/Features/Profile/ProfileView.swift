import SwiftUI

struct ProfileView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        NavigationStack {
            List {
                if let user = environment.auth.user {
                    Section {
                        HStack(spacing: Spacing.md) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(SLColor.accent)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text(user.displayName)
                                    .font(SLFont.title3)
                                    .foregroundStyle(SLColor.textPrimary)
                                Text("Member since \(user.createdAt, format: .dateTime.month(.wide).year())")
                                    .font(SLFont.footnote)
                                    .foregroundStyle(SLColor.textSecondary)
                            }
                        }
                        .padding(.vertical, Spacing.xs)
                        .accessibilityElement(children: .combine)
                        LabeledContent("Units", value: user.preferenceUnits.displayName)
                    } header: {
                        Text("Account")
                    }
                }

                Section {
                    LabeledContent("Server") {
                        Text(environment.serverSettings.effectiveBaseURLString.isEmpty ? "Not set" : environment.serverSettings.effectiveBaseURLString)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Camera", value: environment.camera.isAvailable ? "Available (\(environment.camera.kind.displayName))" : "Unavailable")
                    LabeledContent("Microphone", value: environment.speech.isAvailable ? "Available (\(environment.speech.kind.displayName))" : "Unavailable")
                    LabeledContent("Speech output", value: environment.audio.isAvailable ? "Available" : "Unavailable")
                } header: {
                    Text("Device")
                } footer: {
                    Text("Capture inputs are checked on launch; the simulator reports camera and microphone as unavailable.")
                }

                Section {
                    Button(role: .destructive) {
                        environment.auth.signOut()
                    } label: {
                        Text("Sign out")
                            .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(SLColor.background)
            .navigationTitle("Profile")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        ServerSettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                            .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                    }
                    .accessibilityLabel("Server settings")
                }
            }
        }
    }
}

#Preview {
    ProfileView().environment(AppEnvironment.preview())
}
