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
    @State private var showNotes = false
    @State private var confirmAbandon = false
    @State private var swapToRevert: SessionAdaptation?
    @State private var timerToCancel: TimerRow?
    /// The idle-timer setting from before this screen, captured once.
    @State private var previousIdleTimerSetting: Bool?

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
            if previousIdleTimerSetting == nil {
                previousIdleTimerSetting = UIApplication.shared.isIdleTimerDisabled
            }
            UIApplication.shared.isIdleTimerDisabled = true
            model?.screenDidAppear()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerSetting ?? false
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
            created.onSessionGone = { [environment] id in environment.cooking.sessionGone(id, epoch: epoch) }
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
        case .gone(let message):
            EmptyStateView(
                systemImage: "tray",
                title: message,
                message: "It may have been finished or stopped on another device.",
                primary: EmptyStateView.Action("Close") { environment.cooking.closeCookingScreen() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("cooking.gone")
        case .ready:
            ready(model)
        }
    }

    /// One layout language in portrait and landscape (brief 013 Part C): a slim header, the step
    /// as the first content with its safety line right under it, and a pinned control bar. The
    /// scroll view ends above the bar, so step text never runs underneath the controls.
    private func ready(_ model: CookingViewModel) -> some View {
        let layout = CookingLayout.forSize(dynamicTypeSize)
        let notices = model.notices
        return VStack(spacing: 0) {
            topBar(model)
                .dynamicTypeSize(...CookingLayout.chromeSizeLimit)
                .accessibilitySortPriority(1)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    StepPager(model: model)
                    SafetyNotices(model: model, notices: notices, onRevert: { swapToRevert = $0 })
                    if notices.notesChipText != nil || model.adaptedIndicator != nil {
                        NotesChip(notices: notices, adapted: model.adaptedIndicator != nil) { showNotes = true }
                    }
                    if let suggestion = model.timerSuggestion, model.canSendCommands {
                        TimerSuggestionCard(prompt: CookingFormatting.timerPrompt(suggestion),
                                            onStart: { Task { await model.startSuggestedTimer() } },
                                            onSkip: { model.skipSuggestedTimer() })
                    }
                    TimersList(model: model, onCancel: { timerToCancel = $0 })
                    if let error = model.errorMessage, !model.isOffline {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(SLFont.callout)
                            .foregroundStyle(SLColor.danger)
                            .padding(Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(SLColor.dangerSurface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                            .accessibilityIdentifier("cooking.error")
                    }
                }
                .frame(maxWidth: CookingLayout.readableWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Spacing.screen)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.lg)
            }
            .scrollBounceBehavior(.basedOnSize)
            .accessibilitySortPriority(3)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // The inset is the bar's measured height, so the step's last line always scrolls
                // fully above it; the scrim keeps text from reading through the glass.
                controls(model, layout: layout)
                    .dynamicTypeSize(...CookingLayout.chromeSizeLimit)
                    .bottomBarScrim()
                    .accessibilitySortPriority(2)
            }
        }
        // A light tap only once the server has confirmed the new step (the index is the server's).
        .sensoryFeedback(trigger: model.session?.stepIndex) { old, new in
            guard let old, let new, old != new else { return nil }
            return .impact(weight: .light)
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
        .sheet(isPresented: $showNotes) {
            CookingNotesSheet(model: model) { showNotes = false }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
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
        VStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.md) {
                Button {
                    model.stopSpeaking()
                    environment.cooking.closeCookingScreen()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.title3.weight(.semibold))
                        .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                        .adaptiveGlass(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Leave cooking screen")
                .accessibilityHint("The session stays open; continue it from the banner")
                .accessibilityIdentifier("cooking.close")

                VStack(alignment: .leading, spacing: 0) {
                    Text(model.session?.recipe.title ?? "Cooking")
                        .font(SLFont.headline)
                        .lineLimit(1)
                    HStack(spacing: Spacing.sm) {
                        if let counter = model.stepCounterText {
                            Text(counter)
                                .font(SLFont.stepCounter)
                                .foregroundStyle(SLColor.textSecondary)
                                .lineLimit(1)
                                .contentTransition(.numericText())
                                .accessibilityIdentifier("cooking.stepCounter")
                        }
                        if let adapted = model.adaptedIndicator {
                            AdaptedPill(indicator: adapted)
                        }
                    }
                }
                Spacer()
                Menu {
                    Toggle("Read steps aloud", isOn: Binding(get: { model.readAloudEnabled }, set: { model.readAloudEnabled = $0 }))
                    if let adapted = model.adaptedIndicator {
                        Button(adapted.menuToggleTitle, systemImage: "arrow.triangle.swap") {
                            model.showOriginal.toggle()
                        }
                        .accessibilityIdentifier("cooking.showOriginal")
                    }
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
                    Image(systemName: "ellipsis")
                        .font(.title3.weight(.semibold))
                        .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                        .adaptiveGlass(in: Circle(), interactive: true)
                }
                .accessibilityLabel("Cooking options")
                .accessibilityIdentifier("cooking.menu")
            }
            if let session = model.session, session.stepsCount > 0 {
                StepProgress(index: session.stepIndex, count: session.stepsCount)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
        .foregroundStyle(SLColor.textPrimary)
    }

    // MARK: Controls

    /// The pinned bar: an optional status line (offline, paused, not started), then one row of
    /// Tools, Back, Pause and Next. Start / Resume take Back, Pause and Next's place while the
    /// session is not running. Only this layer is glass; the status line is solid.
    private func controls(_ model: CookingViewModel, layout: CookingLayout) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if model.isOffline || model.isProvisional {
                OfflineBanner(model: model, showsDetail: layout.showsOfflineDetail)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            }
            if model.isPaused {
                Label("Paused — your step and timers are kept", systemImage: "pause.circle.fill")
                    .font(SLFont.subheadline.weight(.semibold))
                    .foregroundStyle(SLColor.warning)
                    .accessibilityIdentifier("cooking.pausedBanner")
            } else if model.isNotStarted {
                Text("Ready when you are. Tap Start to begin with step 1.")
                    .font(SLFont.subheadline)
                    .foregroundStyle(SLColor.textSecondary)
            }
            AdaptiveGlassContainer(spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    toolsButton(model)
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
                    } else {
                        backButton(model, iconOnly: layout.backIsIconOnly)
                            .frame(maxWidth: layout.backIsIconOnly ? Metrics.cookingControl : 116)
                        pauseButton(model).frame(maxWidth: Metrics.cookingControl)
                        nextButton(model)
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.screen)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.sm)
        .frame(maxWidth: CookingLayout.readableWidth)
        .frame(maxWidth: .infinity)
    }

    /// Repeat, Slower, Ask and Look in one glass menu: one tap to open, one to choose.
    private func toolsButton(_ model: CookingViewModel) -> some View {
        let stepToolsOff = model.currentStep == nil || model.isNotStarted
        return Menu {
            Button {
                Task { await model.repeatStep() }
            } label: {
                Label("Repeat", systemImage: "arrow.counterclockwise")
            }
            .disabled(stepToolsOff)
            .accessibilityIdentifier("cooking.repeat")
            Button {
                Task { await model.slower() }
            } label: {
                Label("Slower", systemImage: "tortoise")
            }
            .disabled(stepToolsOff)
            .accessibilityIdentifier("cooking.slower")
            Button {
                showAssistant = true
            } label: {
                Label("Ask", systemImage: "bubble.left.and.text.bubble.right")
            }
            .disabled(model.session == nil)
            .accessibilityIdentifier("cooking.ask")
            Button {} label: {
                Text("Look")
                Text("Coming with camera help")
                Image(systemName: "camera.viewfinder")
            }
            .disabled(true)
            .accessibilityIdentifier("cooking.look")
        } label: {
            Image(systemName: "square.grid.2x2")
                .font(.title3.weight(.semibold))
                .foregroundStyle(SLColor.accent)
                .frame(width: Metrics.cookingControl, height: Metrics.cookingControl)
                .contentShape(Circle())
                .adaptiveGlass(in: Circle(), interactive: true)
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Step tools")
        .accessibilityHint("Repeat, Slower, Ask or Look")
        .accessibilityIdentifier("cooking.tools")
    }

    private func backButton(_ model: CookingViewModel, iconOnly: Bool) -> some View {
        Button {
            Task { await model.back() }
        } label: {
            if iconOnly {
                Image(systemName: "chevron.left")
            } else {
                Label("Back", systemImage: "chevron.left")
            }
        }
        .buttonStyle(CookingButtonStyle(kind: .glass))
        .disabled(!model.canGoBack)
        .accessibilityLabel("Back")
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
            .buttonStyle(CookingButtonStyle(kind: .glass))
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
                ProgressView().tint(SLColor.onAccent)
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

/// The step, keyed by the server's index: Next pushes the new step in from the trailing edge,
/// Back from the leading edge. Under Reduce Motion it crossfades. The index only ever changes
/// when the server says so, so nothing is shown as done before it is. Only the step text moves:
/// the safety line under it is outside the transition, so it is never slid away.
private struct StepPager: View {
    let model: CookingViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The index from the previous render: tells Next from Back.
    @State private var shownIndex: Int?

    var body: some View {
        let index = model.session?.stepIndex ?? 0
        let forward = index >= (shownIndex ?? index)
        ZStack(alignment: .topLeading) {
            if let text = model.instructionText {
                Text(text)
                    .font(SLFont.stepText)
                    .foregroundStyle(SLColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("cooking.instruction")
                    .id(index)
                    .transition(.misePush(from: forward ? .trailing : .leading, reduceMotion: reduceMotion))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .animation(.mise(reduceMotion: reduceMotion), value: index)
        .onAppear { shownIndex = index }
        .onChange(of: index) { old, new in
            shownIndex = new
            // The step-done line no longer sits above the step; VoiceOver still hears it.
            if new > old, !model.isNotStarted {
                AccessibilityNotification.Announcement("Step \(new) done. Nice and steady.").post()
            }
        }
    }
}

/// Safety and allergy notices for this step, directly under the step text: always visible,
/// always solid (never glass), never auto-dismissed. An allergy conflict keeps its own row with
/// its revert action; every other notice shares one compact row that shows the most important
/// notice in full and expands to the rest. The row lives outside the step transition.
private struct SafetyNotices: View {
    let model: CookingViewModel
    let notices: CookingNotices
    let onRevert: (SessionAdaptation) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(model.conflictingAdaptations) { swap in
                Button {
                    onRevert(swap)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text("Conflicts with your allergies — revert?")
                                .font(SLFont.headline)
                            Text("\(swap.replacement) is on your allergy list. Undo it before you go on.")
                                .font(SLFont.callout)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.octagon.fill")
                    }
                    .foregroundStyle(SLColor.onDanger)
                    .padding(Spacing.md)
                    .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget, alignment: .leading)
                    .background(SLColor.danger, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!model.canSendCommands)
                .accessibilityLabel("\(swap.replacement) conflicts with your allergies. Revert to \(swap.original)?")
                .accessibilityIdentifier("cooking.allergyConflict")
            }
            if let lead = notices.leadNotice {
                noticeRow(lead: lead)
            }
        }
        .onChange(of: model.session?.stepIndex) { _, _ in expanded = false }
    }

    private func noticeRow(lead: CookingNotices.Notice) -> some View {
        let tint = notices.leadsWithAllergy ? SLColor.danger : SLColor.warning
        let surface = notices.leadsWithAllergy ? SLColor.dangerSurface : SLColor.warningSurface
        let shown = expanded ? notices.inline : [lead]
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(shown) { notice in
                Label {
                    Text(notice.text)
                        .font(SLFont.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: notice.kind == .allergy ? "allergens" : "exclamationmark.triangle.fill")
                }
                .foregroundStyle(tint)
            }
            if let more = notices.moreText {
                Button {
                    withAnimation(.mise(reduceMotion: reduceMotion)) { expanded.toggle() }
                } label: {
                    Text(expanded ? "Show less" : more)
                        .font(SLFont.footnote.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(minHeight: Metrics.minTapTarget / 1.5, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
                .accessibilityIdentifier("cooking.safetyMore")
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        // VoiceOver hears every notice whether or not the row is expanded.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(notices.accessibilityLabel ?? lead.text)
        .accessibilityIdentifier("cooking.safetyNotice")
    }
}

/// "2 notes": the swap tips, the creator's note and what to look for, one tap away.
private struct NotesChip: View {
    let notices: CookingNotices
    let adapted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(notices.notesChipText ?? "About this swap", systemImage: "note.text")
                .font(SLFont.subheadline.weight(.semibold))
                .foregroundStyle(SLColor.textSecondary)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs + 2)
                .frame(minHeight: Metrics.minTapTarget)
                .background(SLColor.surface, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Swap tips, the creator's note and what to look for")
        .accessibilityIdentifier("cooking.notes")
    }
}

/// The small "Adapted" pill in the header. The full source ("Common swap") is in its VoiceOver
/// label and in the notes sheet; the label check, if any, is in the safety row.
private struct AdaptedPill: View {
    let indicator: AdaptedIndicator

    var body: some View {
        Label(indicator.text, systemImage: "arrow.triangle.swap")
            .font(SLFont.caption)
            .lineLimit(1)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xxs)
            .foregroundStyle(SLColor.accent)
            .background(SLColor.accentSoft, in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(indicator.accessibilityLabel)
            .accessibilityIdentifier("cooking.adaptedBadge")
    }
}

/// Everything folded out of the step, plus the step's safety notices again so the sheet is
/// complete on its own. Content only: solid surfaces, no glass.
private struct CookingNotesSheet: View {
    let model: CookingViewModel
    let onDone: () -> Void

    var body: some View {
        let notices = model.notices
        NavigationStack {
            List {
                if !notices.inline.isEmpty {
                    Section("Safety") {
                        ForEach(notices.inline) { notice in
                            Label(notice.text, systemImage: notice.kind == .allergy ? "allergens" : "exclamationmark.triangle.fill")
                                .foregroundStyle(notice.kind == .allergy ? SLColor.danger : SLColor.warning)
                        }
                    }
                }
                if !model.currentAdaptations.isEmpty {
                    Section("Your swap on this step") {
                        ForEach(model.currentAdaptations) { swap in
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text("\(swap.original) → \(swap.replacement)").font(SLFont.bodyEmphasis)
                                if let amount = swap.ratioOrAmount { Text(amount).font(SLFont.callout) }
                                Text(swap.displayLabel).font(SLFont.caption).foregroundStyle(SLColor.textSecondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                section("Swap notes", kind: .swapTip, icon: "info.circle", notices: notices)
                section("From the creator", kind: .creatorNote, icon: "person.text.rectangle", notices: notices)
                section("Look for", kind: .lookFor, icon: "eye", notices: notices)
                if let step = model.currentRecipeStep {
                    Section {
                        // Clips arrive with Slice 5; say so instead of showing an empty player.
                        Label(step.sourceClipId == nil ? "No clip for this step" : "Clip playback is coming soon", systemImage: "film")
                            .font(SLFont.footnote)
                            .foregroundStyle(SLColor.textSecondary)
                    }
                }
            }
            .navigationTitle(model.stepCounterText ?? "Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone).accessibilityIdentifier("cooking.notes.done")
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, kind: CookingNotices.Note.Kind, icon: String, notices: CookingNotices) -> some View {
        let notes = notices.notes.filter { $0.kind == kind }
        if !notes.isEmpty {
            Section(title) {
                ForEach(notes) { note in
                    Label(note.text, systemImage: icon)
                        .foregroundStyle(SLColor.textPrimary)
                        .accessibilityLabel(kind == .lookFor ? "Look for: \(note.text)" : note.text)
                }
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
                    HStack(spacing: Spacing.md) {
                        HStack(spacing: Spacing.md) {
                            TimerRing(fraction: fraction(for: row), isDone: row.isDone)
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text(row.countdownText)
                                    .font(SLFont.timer)
                                    .foregroundStyle(row.isDone ? SLColor.success : SLColor.textPrimary)
                                    .contentTransition(.numericText(countsDown: true))
                                Text(row.label)
                                    .font(SLFont.callout)
                                    .foregroundStyle(SLColor.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
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
                                    .foregroundStyle(SLColor.textSecondary)
                                    .frame(width: 60, height: 60)
                                    .contentShape(Rectangle())
                            }
                            .disabled(!model.canSendCommands)
                            .accessibilityLabel("Cancel \(row.label) timer")
                            .accessibilityIdentifier("cooking.timer.cancel")
                        }
                    }
                    .padding(Spacing.md)
                    .background(SLColor.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
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

    /// Remaining share of the timer's length, when its length is known: timers start from the
    /// step's suggested timer, so that is the total. Unknown → a full ring.
    private func fraction(for row: TimerRow) -> Double? {
        guard let session = model.session,
              let timer = session.timers.first(where: { $0.id == row.id }),
              let index = timer.stepIndex, session.steps.indices.contains(index),
              let total = session.steps[index].suggestedTimer?.durationSeconds, total > 0,
              row.remainingSeconds <= total
        else { return nil }
        return Double(row.remainingSeconds) / Double(total)
    }
}

/// Countdown ring in herb green; turns to a bell and pulses once at zero (no pulse under Reduce Motion).
private struct TimerRing: View {
    let fraction: Double?
    let isDone: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title) private var size: CGFloat = 52
    @State private var pulses = 0

    var body: some View {
        let diameter = min(size, 96)
        ZStack {
            Circle().stroke(SLColor.separator, lineWidth: 5)
            Circle()
                .trim(from: 0, to: isDone ? 1 : (fraction ?? 1))
                .stroke(isDone ? SLColor.success : SLColor.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .linear(duration: 1), value: fraction)
            Image(systemName: isDone ? "bell.fill" : "timer")
                .font(SLFont.headline)
                .foregroundStyle(isDone ? SLColor.success : SLColor.accent)
        }
        .frame(width: diameter, height: diameter)
        .phaseAnimator([1.0, 1.18, 1.0], trigger: pulses) { content, scale in
            content.scaleEffect(scale)
        } animation: { _ in .spring(response: 0.28, dampingFraction: 0.55) }
        .onChange(of: isDone) { _, done in
            if done, !reduceMotion { pulses += 1 }
        }
        .accessibilityHidden(true)
    }
}

/// Segmented progress: one segment per step, filled through the current one.
private struct StepProgress: View {
    let index: Int
    let count: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { segment in
                Capsule()
                    .fill(segment <= index ? SLColor.accent : SLColor.separator)
                    .frame(height: 4)
            }
        }
        .animation(.mise(reduceMotion: reduceMotion), value: index)
        .accessibilityHidden(true)
    }
}

// MARK: - Small pieces

private struct OfflineBanner: View {
    let model: CookingViewModel
    var showsDetail = true

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
                    if showsDetail {
                        Text("Showing your last saved step. Nothing moves until the server answers.")
                            .font(SLFont.footnote)
                    }
                }
                Spacer()
                if model.isOffline, !model.asksToResendStaleTap {
                    Button(model.isSending ? "…" : "Reconnect") { Task { await model.reconnect() } }
                        .buttonStyle(.borderedProminent)
                        .tint(SLColor.accent)
                        .foregroundStyle(SLColor.onAccent)
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
                        .foregroundStyle(SLColor.onAccent)
                    Button("Discard") { Task { await model.discardStaleTap() } }
                        .buttonStyle(.bordered)
                }
                .frame(minHeight: Metrics.minTapTarget)
            }
        }
        .foregroundStyle(SLColor.textPrimary)
        .padding(Spacing.md)
        .background(SLColor.warningSurface)
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
                .foregroundStyle(SLColor.onAccent)
                .background(SLColor.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("cooking.toast")
    }
}

/// Oversized cooking controls (PRD §6.1: the phone may be propped at a distance).
/// `.primary` is a solid herb-green capsule (Next, Start, Resume); `.glass` sits on glass.
struct CookingButtonStyle: ButtonStyle {
    enum Kind { case primary, glass }
    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.system(.title3, design: .default, weight: .bold))
            // "Back" must never break mid-word at accessibility sizes.
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, minHeight: Metrics.cookingControl)
            .padding(.horizontal, Spacing.md)
            .contentShape(Capsule())
        return Group {
            switch kind {
            case .primary:
                label
                    .foregroundStyle(SLColor.onAccent)
                    .background(SLColor.accent, in: Capsule())
                    .shadow(color: SLColor.accent.opacity(isEnabled ? 0.35 : 0), radius: 12, y: 6)
            case .glass:
                label
                    .foregroundStyle(SLColor.accent)
                    .adaptiveGlass(interactive: true)
            }
        }
        .opacity(isEnabled ? 1 : 0.4)
        .scaleEffect(configuration.isPressed ? 0.97 : 1)
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
