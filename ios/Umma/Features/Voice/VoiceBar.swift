import SwiftUI

/// The persistent voice bar (brief 012): state, live captions for both sides, the honest input
/// name, and Pause / Stop. Not linked from any screen yet; voice screens adopt it in later PRs.
struct VoiceBar: View {
    let session: VoiceSession

    var body: some View {
        VoiceBarContent(
            presentation: VoiceBarPresentation(session: session),
            onPauseToggle: { session.state == .paused ? session.resume() : session.pause() },
            onStop: { session.stop() }
        )
    }
}

/// Stateless rendering of a presentation, so previews and snapshot tests need no session.
struct VoiceBarContent: View {
    let presentation: VoiceBarPresentation
    var onPauseToggle: () -> Void = {}
    var onStop: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            header
            if !presentation.lines.isEmpty { captions }
            if let notice = presentation.notice {
                Label(notice, systemImage: "info.circle")
                    .font(SLFont.footnote)
                    .foregroundStyle(SLColor.textSecondary)
            }
            controls
        }
        .padding(Spacing.lg)
        .background(SLColor.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(SLColor.separator))
        // Reduce Motion: every change is a plain crossfade.
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35), value: presentation)
        .onChange(of: presentation.mode) { _, _ in announce() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voice")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            StateGlyph(mode: presentation.mode, symbolName: presentation.symbolName, animates: !reduceMotion)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(presentation.endedText ?? presentation.statusText)
                    .font(SLFont.headline)
                    .foregroundStyle(SLColor.textPrimary)
                    .id(presentation.statusText)
                    .transition(.opacity)
                if let input = presentation.input {
                    Label(input.text, systemImage: input.symbolName)
                        .font(SLFont.footnote)
                        .foregroundStyle(SLColor.textSecondary)
                        .accessibilityLabel(input.accessibilityLabel)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var captions: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(presentation.lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                    Text(line.speakerLabel)
                        .font(SLFont.overline)
                        .foregroundStyle(line.speaker == .assistant ? SLColor.accent : SLColor.textSecondary)
                        .frame(minWidth: dynamicTypeSize.isAccessibilitySize ? nil : 44, alignment: .leading)
                    Text(line.text)
                        .font(line.speaker == .assistant ? SLFont.bodyEmphasis : SLFont.body)
                        .italic(line.isPartial)
                        .foregroundStyle(line.isPartial ? SLColor.textSecondary : SLColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(line.accessibilityLabel)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.md)
        .background(SLColor.background, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live captions")
    }

    @ViewBuilder
    private var controls: some View {
        if presentation.showsPauseToggle || presentation.showsStop {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: Spacing.sm))
                : AnyLayout(HStackLayout(spacing: Spacing.sm))
            layout {
                if presentation.showsPauseToggle {
                    Button(action: onPauseToggle) {
                        Label(presentation.pauseToggleTitle, systemImage: presentation.pauseToggleSymbol)
                            .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)
                    }
                    .buttonStyle(.bordered)
                    .tint(SLColor.accent)
                }
                if presentation.showsStop {
                    Button(action: onStop) {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SLColor.brand)
                    .foregroundStyle(SLColor.onBrand)
                    .accessibilityHint("Turns voice off")
                }
            }
            .font(SLFont.bodyEmphasis)
        }
    }

    /// Polite: queued behind whatever VoiceOver is already saying.
    private func announce() {
        var text = AttributedString(presentation.announcement)
        text.accessibilitySpeechAnnouncementPriority = .low
        AccessibilityNotification.Announcement(text).post()
    }
}

/// The state glyph on a persimmon wash. Calm motion only: a slow pulse or level sweep, and none
/// at all under Reduce Motion.
private struct StateGlyph: View {
    let mode: VoiceBarPresentation.Mode
    let symbolName: String
    let animates: Bool

    var body: some View {
        Image(systemName: symbolName)
            .font(SLFont.title3)
            .foregroundStyle(SLColor.tomato)
            .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .speed(0.5),
                          isActive: animates && (mode == .listening || mode == .hearing || mode == .speaking))
            .symbolEffect(.pulse, options: .speed(0.6), isActive: animates && (mode == .thinking || mode == .starting))
            .contentTransition(.opacity)
            .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
            .background(SLColor.brandSoft, in: Circle())
            .accessibilityHidden(true)
    }
}

// MARK: - Previews

private func previewSegment(_ id: Int, _ speaker: VoiceSpeaker, _ text: String, at ms: Int64) -> VoiceSegment {
    VoiceSegment(id: id, speaker: speaker, text: text, startMs: ms, endMs: ms + 1500, isFinal: true)
}

private func previewPresentation(_ state: VoiceState, partial: String? = nil, notice: String? = nil) -> VoiceBarPresentation {
    VoiceBarPresentation(
        state: state,
        userCaptions: [previewSegment(1, .user, "Now the kimchi, the old sour one.", at: 1000),
                       previewSegment(3, .user, "About fifteen minutes.", at: 9000)],
        assistantCaptions: [previewSegment(2, .assistant, "How long do you let it simmer?", at: 5000)],
        partial: partial.map { VoiceSegment(id: -1, speaker: .user, text: $0, startMs: 11_000, endMs: 11_500, isFinal: false) },
        inputLabel: "iPhone mic",
        notice: notice
    )
}

#Preview("States") {
    ScrollView {
        VStack(spacing: Spacing.lg) {
            VoiceBarContent(presentation: previewPresentation(.listening))
            VoiceBarContent(presentation: previewPresentation(.userSpeaking, partial: "then I add the"))
            VoiceBarContent(presentation: previewPresentation(.speaking, notice: PaidVoiceTransport.fallbackNotice))
            VoiceBarContent(presentation: previewPresentation(.paused))
            VoiceBarContent(presentation: previewPresentation(.ended(.silenceTimeout)))
        }
        .padding(Spacing.screen)
    }
    .background(SLColor.background)
}

#Preview("Dark, AX5") {
    VoiceBarContent(presentation: previewPresentation(.thinking))
        .padding(Spacing.screen)
        .background(SLColor.background)
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility5)
}

#Preview("Live session") {
    let transport = FakeVoiceTransport()
    let session = VoiceSession(transport: transport, clock: FakeVoiceClock())
    VoiceBar(session: session)
        .padding(Spacing.screen)
        .background(SLColor.background)
        .task {
            try? await session.start()
            transport.emit(.transcript(text: "I've got eggs, rice and spinach", isFinal: true))
            await session.say("Got three. Anything else?")
        }
}
