import SwiftUI

/// Two-step dev sign-in: email → the backend logs a 6-digit code → code → token.
struct SignInView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var email = ""
    @State private var code = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showServerSettings = false
    @State private var serverStatus: ServerStatus = .checking
    @FocusState private var focus: Field?

    private enum Field { case email, code }

    private enum ServerStatus: Equatable {
        case checking
        case reachable(HealthResponse)
        case unreachable(String)
    }

    private var isValidEmail: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") && trimmed.count >= 3
    }

    private var isValidCode: Bool {
        code.count == 6 && code.allSatisfy(\.isNumber)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    brand
                    if let challenge = environment.auth.pendingChallenge {
                        codeStep(challenge)
                    } else {
                        emailStep
                    }
                    serverFooter
                }
                .padding(Spacing.screen)
            }
            .background(SLColor.background)
            .scrollDismissesKeyboard(.interactively)
            .sheet(isPresented: $showServerSettings, onDismiss: { Task { await probeServer() } }) {
                NavigationStack { ServerSettingsView() }
            }
        }
        .task { await probeServer() }
    }

    private var brand: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("SousLens")
                .font(SLFont.display)
                .foregroundStyle(SLColor.textPrimary)
            Text("Record a recipe once. Teach anyone to cook it, with the ingredients they actually have.")
                .font(SLFont.body)
                .foregroundStyle(SLColor.textSecondary)
        }
        .padding(.top, Spacing.xxl)
    }

    // MARK: - Step 1: email

    private var emailStep: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Sign in with your email")
                .font(SLFont.headline)
                .foregroundStyle(SLColor.textPrimary)
            TextField("you@example.com", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($focus, equals: .email)
                .onSubmit { requestCode() }
                .modifier(SignInFieldStyle(isError: errorMessage != nil))
                .accessibilityLabel("Email address")

            inlineError

            Button {
                requestCode()
            } label: {
                if isSubmitting {
                    ProgressView().tint(.white)
                } else {
                    Text("Continue")
                }
            }
            .buttonStyle(SLButtonStyle(prominent: true))
            .disabled(!isValidEmail || isSubmitting)
            .slDisabledAppearance(!isValidEmail)

            Text("Dev sign-in: any email works. The server prints a one-time code to its log instead of sending mail.")
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
        }
    }

    // MARK: - Step 2: code

    private func codeStep(_ challenge: DevLoginChallenge) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Enter the 6-digit code from the server log")
                .font(SLFont.headline)
                .foregroundStyle(SLColor.textPrimary)
            if let email = environment.auth.pendingEmail {
                Text("Signing in as \(email)")
                    .font(SLFont.footnote)
                    .foregroundStyle(SLColor.textSecondary)
            }
            TextField("123456", text: $code)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .font(SLFont.title2.monospacedDigit())
                .focused($focus, equals: .code)
                .onChange(of: code) { _, newValue in
                    let digits = newValue.filter(\.isNumber)
                    if digits.count > 6 || digits != newValue { code = String(digits.prefix(6)) }
                }
                .modifier(SignInFieldStyle(isError: errorMessage != nil))
                .accessibilityLabel("Six digit sign-in code")

            inlineError

            expiryNote(challenge)

            Button {
                verify(challenge)
            } label: {
                if isSubmitting {
                    ProgressView().tint(.white)
                } else {
                    Text("Verify")
                }
            }
            .buttonStyle(SLButtonStyle(prominent: true))
            .disabled(!isValidCode || isSubmitting)
            .slDisabledAppearance(!isValidCode)

            Button("Use a different email") {
                errorMessage = nil
                code = ""
                environment.auth.cancelPendingChallenge()
                focus = .email
            }
            .font(SLFont.bodyEmphasis)
            .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)

            if let hint = challenge.hint, !hint.isEmpty {
                Text(hint)
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
            }
        }
        .onAppear { focus = .code }
    }

    private func expiryNote(_ challenge: DevLoginChallenge) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if context.date < challenge.expiresAt {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "clock").accessibilityHidden(true)
                    Text("Code expires in ")
                    + Text(timerInterval: context.date...challenge.expiresAt, countsDown: true)
                }
                .font(SLFont.footnote)
                .foregroundStyle(SLColor.textSecondary)
            } else {
                Label("This code has expired. Use a different email to request a new one.", systemImage: "clock.badge.exclamationmark")
                    .font(SLFont.footnote)
                    .foregroundStyle(SLColor.warning)
            }
        }
    }

    // MARK: - Shared

    @ViewBuilder
    private var inlineError: some View {
        if let message = errorMessage ?? environment.auth.banner {
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(SLFont.footnote)
                .foregroundStyle(SLColor.danger)
                .accessibilityLabel("Error: \(message)")
        }
    }

    private var serverFooter: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "server.rack")
                    .foregroundStyle(SLColor.textSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Server")
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                    Text(environment.serverSettings.isConfigured ? environment.serverSettings.effectiveBaseURLString : "Not set")
                        .font(SLFont.footnote.monospaced())
                        .foregroundStyle(SLColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Change") { showServerSettings = true }
                    .font(SLFont.bodyEmphasis)
                    .frame(minHeight: Metrics.minTapTarget)
                    .accessibilityLabel("Change server address")
            }
            serverStatusLine
        }
        .padding(Spacing.md)
        .background(SLColor.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }

    @ViewBuilder
    private var serverStatusLine: some View {
        switch serverStatus {
        case .checking:
            Label("Checking server…", systemImage: "ellipsis.circle")
                .font(SLFont.footnote)
                .foregroundStyle(SLColor.textSecondary)
        case .reachable(let health):
            Label("Connected · v\(health.version) · AI \(health.aiProvider)", systemImage: "checkmark.circle.fill")
                .font(SLFont.footnote)
                .foregroundStyle(SLColor.success)
        case .unreachable(let message):
            Label(message, systemImage: "wifi.exclamationmark")
                .font(SLFont.footnote)
                .foregroundStyle(SLColor.danger)
                .accessibilityLabel("Server unreachable: \(message)")
        }
    }

    // MARK: - Actions

    private func requestCode() {
        guard isValidEmail, !isSubmitting else { return }
        run {
            try await environment.auth.requestCode(email: email)
            code = ""
        }
    }

    private func verify(_ challenge: DevLoginChallenge) {
        guard isValidCode, !isSubmitting else { return }
        run {
            try await environment.auth.verify(challengeId: challenge.challengeId, code: code)
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        errorMessage = nil
        isSubmitting = true
        focus = nil
        Task {
            defer { isSubmitting = false }
            do {
                try await action()
            } catch let error as APIError {
                errorMessage = error.userMessage
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Reachability shown under the server address so a wrong URL is obvious before sign-in.
    private func probeServer() async {
        serverStatus = .checking
        do {
            serverStatus = .reachable(try await environment.api.health())
        } catch let error as APIError {
            serverStatus = .unreachable(error.userMessage)
        } catch {
            serverStatus = .unreachable(error.localizedDescription)
        }
    }
}

private struct SignInFieldStyle: ViewModifier {
    let isError: Bool

    func body(content: Content) -> some View {
        content
            .padding(Spacing.md)
            .frame(minHeight: Metrics.minTapTarget)
            .background(SLColor.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(isError ? SLColor.danger : SLColor.separator, lineWidth: 1)
            )
    }
}

#Preview {
    SignInView().environment(AppEnvironment.preview(signedIn: false))
}
