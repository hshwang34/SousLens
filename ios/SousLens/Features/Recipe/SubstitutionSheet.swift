import SwiftUI

/// "Find a swap" (J3 4–5). Each suggestion is qualified (amount, why, flavour/texture, confidence,
/// risks, allergy warning, label); **Use this swap** is the only way one is approved.
struct SubstitutionSheet: View {
    @State var model: SubstitutionSheetViewModel
    let onApprove: (ApprovedSwap) -> Void
    let onFindAnotherRecipe: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    Text("Instead of \(model.targetIngredient)")
                        .font(SLFont.title2)
                        .foregroundStyle(SLColor.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    if let notice = model.safetyNotice {
                        SafetyNoticeView(text: notice)
                    }
                    content
                }
                .padding(Spacing.screen)
            }
            .background(SLColor.background)
            .navigationTitle("Find a swap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("No thanks") { dismiss() }
                        .accessibilityIdentifier("swap.noThanks")
                }
            }
            .task { await model.load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Looking for swaps…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.xxl)
        case .error(let message):
            EmptyStateView(systemImage: "wifi.exclamationmark", title: "Couldn’t look for swaps", message: message,
                           primary: EmptyStateView.Action("Try again") { Task { await model.load() } },
                           secondary: EmptyStateView.Action("Keep it missing") { dismiss() })
        case .noSwap(let reason):
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Label("No suitable swap", systemImage: "xmark.octagon")
                    .font(SLFont.title3)
                    .foregroundStyle(SLColor.textPrimary)
                Text(reason)
                    .font(SLFont.body)
                    .foregroundStyle(SLColor.textPrimary)
                    .accessibilityIdentifier("swap.noSwapReason")
                Button("Keep it missing") { dismiss() }
                    .buttonStyle(SLButtonStyle(prominent: true))
                    .accessibilityIdentifier("swap.keepMissing")
                Button("Find another recipe") {
                    dismiss()
                    onFindAnotherRecipe()
                }
                .buttonStyle(SLButtonStyle(prominent: false))
                .accessibilityIdentifier("swap.findAnother")
            }
        case .suggestions(let suggestions):
            VStack(alignment: .leading, spacing: Spacing.lg) {
                ForEach(suggestions) { suggestion in
                    SuggestionCard(suggestion: suggestion) {
                        if let swap = model.approve(suggestionId: suggestion.id) {
                            onApprove(swap)
                            dismiss()
                        }
                    }
                }
                Text("Swaps change this cook only. The recipe itself stays as the creator wrote it, and you can undo a swap any time.")
                    .font(SLFont.footnote)
                    .foregroundStyle(SLColor.textSecondary)
            }
        }
    }
}

private struct SuggestionCard: View {
    let suggestion: SuggestionPresentation
    let onUse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.xs) {
                MetadataPill(text: suggestion.label,
                             systemImage: suggestion.label == SwapSource.rule.label ? "checkmark.seal" : "sparkles",
                             style: .accent, accessibilityLabel: suggestion.label)
                MetadataPill(text: suggestion.confidence, systemImage: "gauge.with.dots.needle.50percent")
            }
            Text(suggestion.candidate)
                .font(SLFont.title3)
                .foregroundStyle(SLColor.textPrimary)
            if let amount = suggestion.amount {
                Label(amount, systemImage: "scalemass")
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.accent)
            }
            if let why = suggestion.why {
                Text(why).font(SLFont.body).foregroundStyle(SLColor.textPrimary)
            }
            if let flavor = suggestion.flavor {
                detail("Flavour", flavor)
            }
            if let texture = suggestion.texture {
                detail("Texture", texture)
            }
            ForEach(suggestion.risks, id: \.self) { risk in
                Label(risk, systemImage: "exclamationmark.circle")
                    .font(SLFont.callout)
                    .foregroundStyle(SLColor.warning)
            }
            if let warning = suggestion.allergyWarning {
                SafetyNoticeView(text: warning)
                    .accessibilityIdentifier("swap.allergyWarning")
            }
            if suggestion.changesSteps > 0 {
                Text(suggestion.changesSteps == 1 ? "Adjusts 1 step for this cook" : "Adjusts \(suggestion.changesSteps) steps for this cook")
                    .font(SLFont.footnote)
                    .foregroundStyle(SLColor.textSecondary)
            }
            Button("Use this swap", action: onUse)
                .buttonStyle(SLButtonStyle(prominent: true))
                .accessibilityIdentifier("swap.use")
                .accessibilityHint("Adds this swap to your cook. You can undo it.")
        }
        .padding(Spacing.lg)
        .background(SLColor.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(suggestion.accessibilityLabel)
    }

    private func detail(_ title: String, _ text: String) -> some View {
        Text("\(Text("\(title):").bold()) \(text)")
            .font(SLFont.callout)
            .foregroundStyle(SLColor.textSecondary)
    }
}

/// Safety notice styling shared by swaps and the coach (PRD §13.1).
struct SafetyNoticeView: View {
    let text: String

    var body: some View {
        Label {
            Text(text).font(SLFont.callout.weight(.semibold))
        } icon: {
            Image(systemName: "exclamationmark.shield.fill")
        }
        .foregroundStyle(SLColor.danger)
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SLColor.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Safety notice: \(text)")
    }
}
