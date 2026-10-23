import SwiftUI

/// Full-screen cooking (PRD §6, §6.1, J4): one step at a time, large type, oversized controls.
/// Everything on screen is the server's Session; every button is one confirmed command.
struct CookingView: View {
    @Environment(AppEnvironment.self) private var environment
    let presentation: CookingSessionStore.Presentation

    @State private var model: CookingViewModel?
    @State private var assistant: AssistantViewModel?
    @State private var showAssistant = false
    @State private var showSessionEnd = false
    @State private var confirmAbandon = false
    @State private var swapToRevert: SessionAdaptation?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(SLColor.background.ignoresSafeArea())
        .task {
            guard model == nil else { return }
            let created = CookingViewModel(
                sessionId: presentation.sessionId,
                initial: presentation.initial,
                startOnOpen: presentation.startOnOpen,
                service: environment.api,
                audio: environment.audio,
                loadCached: { [environment] in environment.cooking.cachedSession() }
            )
            // Stamped with the epoch this screen opened under: after a sign-out it reports nothing.
            let epoch = environment.cooking.epoch
            created.onSessionChanged = { [environment] session in environment.cooking.sessionChanged(session, epoch: epoch) }
            environment.cooking.attach(created)
            let drawer = AssistantViewModel(sessionId: presentation.sessionId, service: environment.api,
                                            audio: environment.audio, currentSession: { [weak created] in created?.session })
            drawer.onProposal = { [weak created] action in await created?.perform(action) ?? false }
            model = created
            assistant = drawer
            await created.load()
        }
    }

    @ViewBuilder
    private func content(_ model: CookingViewModel) -> some View {
        switch model.phase {
        case .loading:
            VStack(spacing: Spacing.lg) {
                ProgressView()
                Text("Opening your cooking session…").font(SLFont.body)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            EmptyStateView(
                systemImage: "wifi.exclamationmark",
                title: "Couldn’t open the session",
                message: message,
                primary: EmptyStateView.Action("Try again") { Task { await model.refresh() } },
                secondary: EmptyStateView.Action("Close") { environment.cooking.closeCookingScreen() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            ready(model)
        }
    }

    private func ready(_ model: CookingViewModel) -> some View {
        VStack(spacing: 0) {
            topBar(model)
            if model.isOffline {
                OfflineBanner(isBusy: model.isSending) { Task { await model.reconnect() } }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    StepContent(model: model)
                    if let suggestion = model.timerSuggestion, model.canSendCommands {
                        TimerSuggestionCard(prompt: CookingFormatting.timerPrompt(suggestion),
                                            onStart: { Task { await model.startSuggestedTimer() } },
                                            onSkip: { model.skipSuggestedTimer() })
                    }
                    TimersList(model: model)
                    if let error = model.errorMessage, !model.isOffline {
                        Text(error)
                            .font(SLFont.callout)
                            .foregroundStyle(SLColor.danger)
                            .accessibilityIdentifier("cooking.error")
                    }
                }
                .padding(.horizontal, Spacing.screen)
                .padding(.vertical, Spacing.lg)
            }
            controls(model)
        }
        .overlay(alignment: .top) {
            if let toast = model.toast {
                ToastView(text: toast) { model.dismissToast() }
                    .padding(.top, 72)
                    .task(id: toast) {
                        try? await Task.sleep(for: .seconds(4))
                        model.dismissToast()
                    }
            }
        }
        .onChange(of: model.isEnded) { _, ended in
            if ended { environment.cooking.closeCookingScreen() }
        }
        .sheet(isPresented: $showAssistant) {
            if let assistant {
                AssistantDrawerView(model: assistant, cooking: model)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showSessionEnd) {
            SessionEndView(cooking: model) {
                showSessionEnd = false
            }
            .interactiveDismissDisabled(model.isSending)
        }
        .confirmationDialog("Stop cooking?", isPresented: $confirmAbandon, titleVisibility: .visible) {
            Button("Stop cooking", role: .destructive) { Task { await model.abandon() } }
            Button("Keep cooking", role: .cancel) {}
        } message: {
            Text("This ends the session. Your swaps for this cook are not saved.")
        }
        .confirmationDialog("Undo this swap?", isPresented: Binding(get: { swapToRevert != nil }, set: { if !$0 { swapToRevert = nil } }), titleVisibility: .visible) {
            Button("Use the original \(swapToRevert?.original ?? "ingredient")") {
                if let swap = swapToRevert { Task { await model.revertAdaptation(id: swap.id) } }
            }
            Button("Keep the swap", role: .cancel) {}
        } message: {
            Text("The steps go back to the recipe as written.")
        }
    }

    // MARK: Top bar

    private func topBar(_ model: CookingViewModel) -> some View {
        HStack(spacing: Spacing.md) {
            Button {
                model.stopSpeaking()
                environment.cooking.closeCookingScreen()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
            }
            .accessibilityLabel("Leave cooking screen")
            .accessibilityHint("The session stays open; continue it from the banner")
            .accessibilityIdentifier("cooking.close")

            VStack(alignment: .leading, spacing: 0) {
                Text(model.session?.recipe.title ?? "Cooking")
                    .font(SLFont.headline)
                    .lineLimit(1)
                if let counter = model.stepCounterText {
                    Text(counter)
                        .font(SLFont.subheadline.monospacedDigit())
                        .foregroundStyle(SLColor.textSecondary)
                        .accessibilityIdentifier("cooking.stepCounter")
                }
            }
            Spacer()
            Menu {
                Toggle("Read steps aloud", isOn: Binding(get: { model.readAloudEnabled }, set: { model.readAloudEnabled = $0 }))
                if let adaptations = model.session?.adaptations, !adaptations.isEmpty {
                    Section("Your swaps") {
                        ForEach(adaptations) { swap in
                            Button("Undo: \(swap.original) → \(swap.replacement)") { swapToRevert = swap }
                                .disabled(!model.canSendCommands)
                        }
                    }
                }
                Button("Stop cooking…", systemImage: "xmark.octagon", role: .destructive) { confirmAbandon = true }
                    .disabled(!model.canSendCommands)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title2)
                    .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
            }
            .accessibilityLabel("Cooking options")
            .accessibilityIdentifier("cooking.menu")
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
        .foregroundStyle(SLColor.textPrimary)
    }

    // MARK: Controls

    private func controls(_ model: CookingViewModel) -> some View {
        VStack(spacing: Spacing.md) {
            if model.isNotStarted {
                Button {
                    Task { await model.start() }
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(CookingButtonStyle(kind: .primary))
                .disabled(!model.canSendCommands)
                .accessibilityIdentifier("cooking.start")
            } else if model.isPaused {
                Button {
                    Task { await model.resume() }
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(CookingButtonStyle(kind: .primary))
                .disabled(!model.canSendCommands)
                .accessibilityIdentifier("cooking.resume")
            }
            HStack(spacing: Spacing.sm) {
                SmallControl(title: "Repeat", systemImage: "arrow.counterclockwise", identifier: "cooking.repeat") {
                    Task { await model.repeatStep() }
                }
                .disabled(model.currentStep == nil || model.isNotStarted)
                SmallControl(title: "Slower", systemImage: "tortoise", identifier: "cooking.slower") {
                    Task { await model.slower() }
                }
                .disabled(model.currentStep == nil || model.isNotStarted)
                SmallControl(title: "Ask", systemImage: "bubble.left.and.text.bubble.right", identifier: "cooking.ask") {
                    showAssistant = true
                }
                .disabled(model.session == nil)
                VStack(spacing: Spacing.xxs) {
                    SmallControl(title: "Look", systemImage: "camera.viewfinder", identifier: "cooking.look") {}
                        .disabled(true)
                        .accessibilityHint("Coming with camera help")
                }
            }
            Text("Look is coming with camera help")
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityHidden(true)
            HStack(spacing: Spacing.sm) {
                Button {
                    Task { await model.back() }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(CookingButtonStyle(kind: .secondary))
                .disabled(!model.canGoBack)
                .accessibilityIdentifier("cooking.back")

                if !model.isPaused && !model.isNotStarted {
                    Button {
                        Task { await model.pause() }
                    } label: {
                        Image(systemName: "pause.fill")
                    }
                    .buttonStyle(CookingButtonStyle(kind: .secondary))
                    .frame(maxWidth: 96)
                    .disabled(!model.canSendCommands)
                    .accessibilityLabel("Pause")
                    .accessibilityIdentifier("cooking.pause")
                }

                Button {
                    if model.isLastStep {
                        model.stopSpeaking()
                        showSessionEnd = true
                    } else {
                        Task { await model.next() }
                    }
                } label: {
                    if model.isSending {
                        ProgressView().tint(.white)
                    } else {
                        Label(model.nextTitle, systemImage: model.isLastStep ? "flag.checkered" : "chevron.right")
                            .labelStyle(TrailingIconLabelStyle())
                    }
                }
                .buttonStyle(CookingButtonStyle(kind: .primary))
                .disabled(!model.canGoNext)
                .accessibilityLabel(model.nextTitle)
                .accessibilityIdentifier("cooking.next")
            }
        }
        .padding(.horizontal, Spacing.screen)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.lg)
        .background(SLColor.surface.ignoresSafeArea(edges: .bottom))
    }
}

// MARK: - Step

private struct StepContent: View {
    let model: CookingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            if model.isPaused {
                Label("Paused — your step and timers are kept", systemImage: "pause.circle.fill")
                    .font(SLFont.headline)
                    .foregroundStyle(SLColor.warning)
                    .accessibilityIdentifier("cooking.pausedBanner")
            }
            if model.isNotStarted {
                Text("Ready when you are. Tap Start to begin with step 1.")
                    .font(SLFont.title3)
                    .foregroundStyle(SLColor.textSecondary)
            }
            if let badge = model.adaptedBadgeText {
                HStack(spacing: Spacing.sm) {
                    MetadataPill(text: badge, systemImage: "arrow.triangle.swap", style: .accent,
                                 accessibilityLabel: badge)
                        .accessibilityIdentifier("cooking.adaptedBadge")
                    Spacer()
                    Button(model.showOriginal ? "Show adapted" : "Show original") {
                        model.showOriginal.toggle()
                    }
                    .font(SLFont.callout.weight(.semibold))
                    .frame(minHeight: Metrics.minTapTarget)
                    .accessibilityIdentifier("cooking.showOriginal")
                }
                if model.showOriginal {
                    Text("Original recipe text")
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                }
            }
            if let text = model.instructionText {
                Text(text)
                    .font(.system(.title, design: .default, weight: .semibold))
                    .foregroundStyle(SLColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cooking.instruction")
            }
            if let recipeStep = model.currentRecipeStep {
                ForEach(recipeStep.warnings, id: \.self) { warning in
                    Label {
                        Text(warning).font(SLFont.title3)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(SLColor.warning)
                    .padding(Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SLColor.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Safety warning: \(warning)")
                }
                ForEach(recipeStep.successCues, id: \.self) { cue in
                    Label {
                        Text(cue).font(SLFont.body)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    .foregroundStyle(SLColor.success)
                    .accessibilityLabel("Look for: \(cue)")
                }
                if let note = recipeStep.creatorNote, !note.isEmpty {
                    Label {
                        Text(note).font(SLFont.callout).italic()
                    } icon: {
                        Image(systemName: "person.text.rectangle")
                    }
                    .foregroundStyle(SLColor.textSecondary)
                    .accessibilityLabel("Creator note: \(note)")
                }
                // Clips arrive with Slice 5; say so instead of showing an empty player.
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "film")
                        .accessibilityHidden(true)
                    Text(recipeStep.sourceClipId == nil ? "No clip for this step" : "Clip playback is coming soon")
                }
                .font(SLFont.footnote)
                .foregroundStyle(SLColor.textSecondary)
                .padding(Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SLColor.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - Timers

private struct TimerSuggestionCard: View {
    let prompt: String
    let onStart: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Label(prompt, systemImage: "timer")
                .font(SLFont.title3)
                .foregroundStyle(SLColor.textPrimary)
            HStack(spacing: Spacing.sm) {
                Button("Start", action: onStart)
                    .buttonStyle(SLButtonStyle(prominent: true))
                    .accessibilityIdentifier("cooking.timer.start")
                Button("Skip", action: onSkip)
                    .buttonStyle(SLButtonStyle(prominent: false))
                    .accessibilityIdentifier("cooking.timer.skip")
            }
        }
        .padding(Spacing.lg)
        .background(SLColor.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

private struct TimersList: View {
    let model: CookingViewModel

    var body: some View {
        // Re-rendered every second from the absolute target times; nothing is counted locally.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let rows = model.timerRows(at: context.date)
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Timers")
                        .font(SLFont.headline)
                        .foregroundStyle(SLColor.textSecondary)
                    ForEach(rows) { row in
                        HStack {
                            Image(systemName: row.isDone ? "bell.fill" : "timer")
                                .foregroundStyle(row.isDone ? SLColor.success : SLColor.accent)
                                .accessibilityHidden(true)
                            Text(row.label).font(SLFont.title3)
                            Spacer()
                            Text(row.countdownText)
                                .font(.system(.title, design: .rounded, weight: .bold).monospacedDigit())
                                .foregroundStyle(row.isDone ? SLColor.success : SLColor.textPrimary)
                            if !row.isDone {
                                Button {
                                    Task { await model.cancelTimer(id: row.id) }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.title2)
                                        .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                                }
                                .disabled(!model.canSendCommands)
                                .accessibilityLabel("Cancel \(row.label) timer")
                            }
                        }
                        .padding(Spacing.md)
                        .background(SLColor.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(row.accessibilityLabel)
                        .accessibilityIdentifier("cooking.timer")
                    }
                }
            }
        }
    }
}

// MARK: - Small pieces

private struct OfflineBanner: View {
    let isBusy: Bool
    let onReconnect: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "wifi.slash").accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Reconnect to continue").font(SLFont.headline)
                Text("Showing your last saved step. Nothing moves until the server answers.")
                    .font(SLFont.footnote)
            }
            Spacer()
            Button(isBusy ? "…" : "Reconnect", action: onReconnect)
                .buttonStyle(.borderedProminent)
                .tint(SLColor.warning)
                .disabled(isBusy)
                .accessibilityIdentifier("cooking.reconnect")
        }
        .foregroundStyle(SLColor.textPrimary)
        .padding(Spacing.md)
        .background(SLColor.surfaceRaised)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cooking.offline")
    }
}

struct ToastView: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onDismiss) {
            Label(text, systemImage: "arrow.triangle.2.circlepath")
                .font(SLFont.callout.weight(.semibold))
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.md)
                .foregroundStyle(Color.white)
                .background(SLColor.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("cooking.toast")
        .accessibilityAddTraits(.updatesFrequently)
    }
}

private struct SmallControl: View {
    let title: String
    let systemImage: String
    let identifier: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.xs) {
                Image(systemName: systemImage).font(.title2)
                Text(title).font(SLFont.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
            .foregroundStyle(SLColor.accent)
            .background(SLColor.accentSoft, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

/// Oversized cooking controls (PRD §6.1: the phone may be propped at a distance).
struct CookingButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.title2, design: .default, weight: .bold))
            .frame(maxWidth: .infinity, minHeight: 72)
            .foregroundStyle(kind == .primary ? Color.white : SLColor.accent)
            .background(kind == .primary ? SLColor.accent : SLColor.accentSoft,
                        in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Spacing.sm) {
            configuration.title
            configuration.icon
        }
    }
}
