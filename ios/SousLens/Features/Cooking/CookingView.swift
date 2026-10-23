import SwiftUI
import UIKit

/// Full-screen cooking (PRD §6, §6.1, J4): one step at a time, large type, oversized controls.
/// Everything on screen is the server's Session; every button is one confirmed command.
struct CookingView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let presentation: CookingSessionStore.Presentation

    @State private var model: CookingViewModel?
    @State private var assistant: AssistantViewModel?
    @State private var showAssistant = false
    @State private var showSessionEnd = false
    @State private var confirmAbandon = false
    @State private var swapToRevert: SessionAdaptation?
    @State private var timerToCancel: TimerRow?
    @State private var previousIdleTimerSetting = false

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(SLColor.background.ignoresSafeArea())
        .onAppear {
            // The phone may be propped up across the kitchen: keep the screen on while cooking.
            previousIdleTimerSetting = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            model?.screenDidAppear()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerSetting
            model?.screenDidDisappear()
            assistant?.drawerDidDisappear()
        }
        .task {
            guard model == nil else { return }
            let created = CookingViewModel(
                sessionId: presentation.sessionId,
                initial: presentation.initial,
                startOnOpen: presentation.startOnOpen,
                service: environment.api,
                audio: environment.audio,
                loadCached: { [environment] in environment.cooking.cachedSession() },
                swapCautions: presentation.swapCautions
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
            if model.isOffline || model.isProvisional {
                OfflineBanner(model: model)
            }
            // The step scrolls on its own above the controls, whatever the text size.
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    StepContent(model: model, onRevert: { swapToRevert = $0 })
                    if let suggestion = model.timerSuggestion, model.canSendCommands {
                        TimerSuggestionCard(prompt: CookingFormatting.timerPrompt(suggestion),
                                            onStart: { Task { await model.startSuggestedTimer() } },
                                            onSkip: { model.skipSuggestedTimer() })
                    }
                    TimersList(model: model, onCancel: { timerToCancel = $0 })
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
        .onChange(of: model.toast) { _, toast in
            if let toast { AccessibilityNotification.Announcement(toast).post() }
        }
        .onChange(of: model.isEnded) { _, ended in
            if ended { environment.cooking.closeCookingScreen() }
        }
        .sheet(isPresented: $showAssistant) {
            if let assistant {
                AssistantDrawerView(model: assistant, cooking: model)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .onAppear { assistant.drawerDidAppear() }
                    .onDisappear { assistant.drawerDidDisappear() }
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
        .confirmationDialog("Cancel the \(timerToCancel?.label ?? "") timer?", isPresented: Binding(get: { timerToCancel != nil }, set: { if !$0 { timerToCancel = nil } }), titleVisibility: .visible) {
            Button("Cancel timer", role: .destructive) {
                if let timer = timerToCancel { Task { await model.cancelTimer(id: timer.id) } }
            }
            Button("Keep it running", role: .cancel) {}
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
        let layout = CookingLayout.forSize(dynamicTypeSize)
        return VStack(spacing: Spacing.md) {
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
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.sm), count: layout.toolColumns),
                      spacing: Spacing.sm) {
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
                SmallControl(title: "Look", systemImage: "camera.viewfinder", identifier: "cooking.look") {}
                    .disabled(true)
                    .accessibilityHint("Coming with camera help")
            }
            Text("Look is coming with camera help")
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityHidden(true)
            if layout.stacksNavigation {
                VStack(spacing: Spacing.sm) {
                    nextButton(model)
                    HStack(spacing: Spacing.sm) {
                        backButton(model)
                        pauseButton(model)
                    }
                }
            } else {
                HStack(spacing: Spacing.sm) {
                    backButton(model)
                    pauseButton(model).frame(maxWidth: 96)
                    nextButton(model)
                }
            }
        }
        .padding(.horizontal, Spacing.screen)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.lg)
        .background(SLColor.surface.ignoresSafeArea(edges: .bottom))
    }

    private func backButton(_ model: CookingViewModel) -> some View {
        Button {
            Task { await model.back() }
        } label: {
            Label("Back", systemImage: "chevron.left")
        }
        .buttonStyle(CookingButtonStyle(kind: .secondary))
        .disabled(!model.canGoBack)
        .accessibilityIdentifier("cooking.back")
    }

    @ViewBuilder
    private func pauseButton(_ model: CookingViewModel) -> some View {
        if !model.isPaused && !model.isNotStarted {
            Button {
                Task { await model.pause() }
            } label: {
                Image(systemName: "pause.fill")
            }
            .buttonStyle(CookingButtonStyle(kind: .secondary))
            .disabled(!model.canSendCommands)
            .accessibilityLabel("Pause")
            .accessibilityIdentifier("cooking.pause")
        }
    }

    private func nextButton(_ model: CookingViewModel) -> some View {
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

// MARK: - Step

private struct StepContent: View {
    let model: CookingViewModel
    let onRevert: (SessionAdaptation) -> Void

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
            ForEach(model.conflictingAdaptations) { swap in
                Button {
                    onRevert(swap)
                } label: {
                    Label("Conflicts with your allergies — revert?", systemImage: "exclamationmark.octagon.fill")
                        .font(SLFont.headline)
                        .foregroundStyle(Color.white)
                        .padding(Spacing.md)
                        .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget, alignment: .leading)
                        .background(SLColor.danger, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!model.canSendCommands)
                .accessibilityLabel("\(swap.replacement) conflicts with your allergies. Revert to \(swap.original)?")
                .accessibilityIdentifier("cooking.allergyConflict")
            }
            if let badge = model.adaptedBadgeText {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.sm) { badgeView(badge); Spacer(); originalToggle }
                    VStack(alignment: .leading, spacing: Spacing.sm) { badgeView(badge); originalToggle }
                }
                ForEach(model.adaptedCautionLines, id: \.self) { line in
                    Label(line, systemImage: "exclamationmark.circle")
                        .font(SLFont.callout)
                        .foregroundStyle(SLColor.warning)
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
                    // A cue is something to look for, not a verdict: neutral icon, not a green check.
                    Label {
                        Text(cue).font(SLFont.body)
                    } icon: {
                        Image(systemName: "eye")
                    }
                    .foregroundStyle(SLColor.textPrimary)
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

    private func badgeView(_ badge: String) -> some View {
        Label(badge, systemImage: "arrow.triangle.swap")
            .font(SLFont.caption)
            .padding(.horizontal, Spacing.sm + 2)
            .padding(.vertical, Spacing.xs + 1)
            .foregroundStyle(SLColor.accent)
            .background(SLColor.accentSoft, in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(badge)
            .accessibilityIdentifier("cooking.adaptedBadge")
    }

    private var originalToggle: some View {
        Button(model.showOriginal ? "Show adapted" : "Show original") {
            model.showOriginal.toggle()
        }
        .font(SLFont.callout.weight(.semibold))
        .frame(minHeight: Metrics.minTapTarget)
        .accessibilityIdentifier("cooking.showOriginal")
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
    let onCancel: (TimerRow) -> Void

    var body: some View {
        // Re-rendered every second from the absolute target times; nothing is counted locally.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let rows = model.timerRows(at: context.date)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if !rows.isEmpty {
                    Text("Timers")
                        .font(SLFont.headline)
                        .foregroundStyle(SLColor.textSecondary)
                }
                ForEach(rows) { row in
                    HStack {
                        HStack {
                            Image(systemName: row.isDone ? "bell.fill" : "timer")
                                .foregroundStyle(row.isDone ? SLColor.success : SLColor.accent)
                                .accessibilityHidden(true)
                            Text(row.label).font(SLFont.title3)
                            Spacer()
                            Text(row.countdownText)
                                .font(.system(.title, design: .rounded, weight: .bold).monospacedDigit())
                                .foregroundStyle(row.isDone ? SLColor.success : SLColor.textPrimary)
                        }
                        // The countdown is one element; the cancel button stays its own.
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(row.accessibilityLabel)
                        .accessibilityIdentifier("cooking.timer")
                        if !row.isDone {
                            Button {
                                onCancel(row)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title)
                                    .frame(width: 60, height: 60)
                                    .contentShape(Rectangle())
                            }
                            .disabled(!model.canSendCommands)
                            .accessibilityLabel("Cancel \(row.label) timer")
                            .accessibilityIdentifier("cooking.timer.cancel")
                        }
                    }
                    .padding(Spacing.md)
                    .background(SLColor.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .accessibilityElement(children: .contain)
                }
            }
            .onChange(of: context.date) { _, date in
                for finished in model.newlyFinishedTimers(at: date) {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    AccessibilityNotification.Announcement("\(finished.label) timer done").post()
                }
            }
        }
    }
}

// MARK: - Small pieces

private struct OfflineBanner: View {
    let model: CookingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.md) {
                Image(systemName: "wifi.slash").accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(model.isOffline ? "Reconnect to continue" : "Checking with the server…").font(SLFont.headline)
                    if let pending = model.pendingTapText {
                        Text(pending).font(SLFont.footnote.weight(.semibold))
                            .accessibilityIdentifier("cooking.pendingTap")
                    }
                    Text("Showing your last saved step. Nothing moves until the server answers.")
                        .font(SLFont.footnote)
                }
                Spacer()
                if model.isOffline, !model.asksToResendStaleTap {
                    Button(model.isSending ? "…" : "Reconnect") { Task { await model.reconnect() } }
                        .buttonStyle(.borderedProminent)
                        .tint(SLColor.warning)
                        .disabled(model.isSending)
                        .accessibilityIdentifier("cooking.reconnect")
                }
            }
            if model.asksToResendStaleTap {
                Text("That tap is more than 2 minutes old. Send it again?")
                    .font(SLFont.callout)
                HStack(spacing: Spacing.sm) {
                    Button("Send it again") { Task { await model.resendStaleTap() } }
                        .buttonStyle(.borderedProminent)
                        .tint(SLColor.accent)
                    Button("Discard") { Task { await model.discardStaleTap() } }
                        .buttonStyle(.bordered)
                }
                .frame(minHeight: Metrics.minTapTarget)
            }
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
