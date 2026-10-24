import SwiftUI

/// Assistant drawer (PRD §6): grounded conversation, source-step badges, warnings.
struct AssistantDrawerView: View {
    @Bindable var model: AssistantViewModel
    let cooking: CookingViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var queryFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                            if model.turns.isEmpty {
                                Text("Ask about this step — what a word means, what to look for, what to do if something goes wrong. Answers come from the recipe as published.")
                                    .font(SLFont.body)
                                    .foregroundStyle(SLColor.textSecondary)
                            }
                            ForEach(model.turns) { turn in
                                TurnView(model: model, turn: turn, cookingBusy: !cooking.canSendCommands)
                                    .id(turn.id)
                            }
                            if let error = model.errorMessage {
                                Text(error)
                                    .font(SLFont.callout)
                                    .foregroundStyle(SLColor.danger)
                                    .accessibilityIdentifier("assistant.error")
                            }
                        }
                        .padding(Spacing.screen)
                    }
                    .onChange(of: model.turns.count) { _, _ in
                        if let last = model.turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .top) } }
                    }
                }
                inputBar
            }
            .background(SLColor.background)
            .navigationTitle("Ask the coach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("assistant.dismiss")
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: Spacing.sm) {
            TextField("Type a question", text: $model.query, axis: .vertical)
                .lineLimit(1...4)
                .font(SLFont.body)
                .padding(Spacing.md)
                .background(SLColor.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .focused($queryFocused)
                .submitLabel(.send)
                .onSubmit { Task { await model.ask() } }
                .accessibilityIdentifier("assistant.query")
            Button {
                Task { await model.ask() }
            } label: {
                if model.isAsking {
                    ProgressView().frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 36))
                        .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                }
            }
            .disabled(!model.canAsk)
            .accessibilityLabel("Ask")
            .accessibilityIdentifier("assistant.send")
        }
        .padding(Spacing.md)
        .background(SLColor.surfaceRaised)
    }
}

private struct TurnView: View {
    let model: AssistantViewModel
    let turn: AssistantViewModel.Turn
    let cookingBusy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(turn.query)
                .font(SLFont.bodyEmphasis)
                .foregroundStyle(SLColor.textPrimary)
                .padding(Spacing.md)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .background(SLColor.accentSoft, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .accessibilityLabel("You asked: \(turn.query)")

            VStack(alignment: .leading, spacing: Spacing.sm) {
                // Safety first: shown (and read) before the answer.
                if let notice = turn.response.safetyNotice, !notice.isEmpty {
                    Label {
                        Text(notice).font(SLFont.callout.weight(.semibold))
                    } icon: {
                        Image(systemName: "exclamationmark.shield.fill")
                    }
                    .foregroundStyle(SLColor.warning)
                    .padding(Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SLColor.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Safety notice: \(notice)")
                    .accessibilityIdentifier("assistant.safety")
                }
                if model.isStale(turn) {
                    MetadataPill(text: "Based on previous step", systemImage: "clock.arrow.circlepath")
                        .accessibilityIdentifier("assistant.stale")
                }
                ForEach(turn.segments) { segment in
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        if let heading = segment.heading {
                            Text(heading).font(SLFont.headline)
                        }
                        Text(segment.text).font(SLFont.title3.weight(.regular))
                    }
                }
                FlowBadges(badges: model.badges(for: turn), uncertainty: turn.response.uncertainty.uncertaintyText)
                HStack(spacing: Spacing.sm) {
                    Button {
                        Task { await model.readAloud(turnId: turn.id) }
                    } label: {
                        Label("Read aloud", systemImage: "speaker.wave.2")
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: Metrics.minTapTarget)
                    .accessibilityIdentifier("assistant.readAloud")
                    if let title = model.proposalTitle(for: turn) {
                        Button(title) {
                            Task { await model.acceptProposal(turnId: turn.id) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(SLColor.accent)
                        .frame(minHeight: Metrics.minTapTarget)
                        .disabled(cookingBusy)
                        .accessibilityHint("Nothing changes unless you tap")
                        .accessibilityIdentifier("assistant.proposal")
                    }
                }
            }
            .padding(Spacing.md)
            .background(SLColor.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("assistant.answer")
        }
    }
}

private struct FlowBadges: View {
    let badges: [GroundingBadge]
    let uncertainty: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.xs) { content }
            VStack(alignment: .leading, spacing: Spacing.xs) { content }
        }
    }

    @ViewBuilder
    private var content: some View {
        ForEach(badges) { badge in
            MetadataPill(text: badge.text, systemImage: badge.systemImage, style: .accent,
                         accessibilityLabel: "Source: \(badge.text)")
                .accessibilityIdentifier("assistant.badge")
        }
        MetadataPill(text: uncertainty, systemImage: "gauge.with.dots.needle.33percent")
    }
}
