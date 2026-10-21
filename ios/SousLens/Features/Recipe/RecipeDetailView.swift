import SwiftUI

struct RecipeDetailView: View {
    @Environment(AppEnvironment.self) private var environment

    let card: RecipeCard

    private enum Phase {
        case loading
        case loaded(RecipeDetail)
        case error(String, retryable: Bool)
    }

    @State private var phase: Phase = .loading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                hero
                header
                switch phase {
                case .loading:
                    ProgressView("Loading recipe…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.xxl)
                case .loaded(let detail):
                    RecipeDetailBody(detail: detail)
                case .error(let message, let retryable):
                    EmptyStateView(
                        systemImage: "wifi.exclamationmark",
                        title: "Couldn’t load the recipe",
                        message: message,
                        primary: retryable ? EmptyStateView.Action("Try again") { Task { await load() } } : nil
                    )
                }
                actions
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.bottom, Spacing.xxl)
        }
        .background(SLColor.background)
        .navigationTitle(card.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        phase = .loading
        do {
            let detail = try await environment.api.recipe(id: card.recipeId)
            phase = .loaded(detail)
        } catch let error as APIError {
            if error == .cancelled { return }
            phase = .error(error.userMessage, retryable: error.isRetryable)
        } catch {
            phase = .error(error.localizedDescription, retryable: true)
        }
    }

    private var hero: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .fill(SLColor.accentSoft)
            if let url = card.coverImageURL {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        heroPlaceholder
                    }
                }
            } else {
                heroPlaceholder
            }
        }
        .aspectRatio(Metrics.heroAspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .accessibilityLabel(card.coverImageURL == nil ? "No photo yet" : "Recipe photo")
    }

    private var heroPlaceholder: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "fork.knife")
                .font(.system(size: 48, weight: .light))
            Text("No photo yet")
                .font(SLFont.caption)
        }
        .foregroundStyle(SLColor.accent)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(card.title)
                .font(SLFont.title)
                .foregroundStyle(SLColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: Spacing.sm) {
                Text("by \(card.creator.displayName)")
                    .font(SLFont.subheadline)
                    .foregroundStyle(SLColor.textSecondary)
                Text("v\(card.versionNumber)")
                    .font(SLFont.caption)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xxs)
                    .background(SLColor.surfaceRaised, in: Capsule())
                    .foregroundStyle(SLColor.textSecondary)
                    .accessibilityLabel("Version \(card.versionNumber)")
            }
            if let summary = card.summary, !summary.isEmpty {
                Text(summary)
                    .font(SLFont.body)
                    .foregroundStyle(SLColor.textPrimary)
            }
            HStack(spacing: Spacing.sm) {
                if let prep = card.prepMinutes {
                    MetadataPill(text: "Prep \(RecipeFormatting.minutes(prep))", systemImage: "knife")
                }
                if let cook = card.cookMinutes {
                    MetadataPill(text: "Cook \(RecipeFormatting.minutes(cook))", systemImage: "flame")
                }
                MetadataPill(text: "Serves \(card.servings)", systemImage: "person.2")
            }
        }
    }

    private var actions: some View {
        VStack(spacing: Spacing.sm) {
            Button("Save") {}
                .buttonStyle(SLButtonStyle(prominent: false))
                .disabled(true)
                .slDisabledAppearance(true)
            Button("Check my pantry") {}
                .buttonStyle(SLButtonStyle(prominent: false))
                .disabled(true)
                .slDisabledAppearance(true)
            Button("Start cooking") {}
                .buttonStyle(SLButtonStyle(prominent: true))
                .disabled(true)
                .slDisabledAppearance(true)
            Text("Coming in a later build")
                .font(SLFont.footnote)
                .foregroundStyle(SLColor.textSecondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint("Save, Check my pantry, and Start cooking are coming in a later build.")
    }
}

/// Ingredients, steps, and notes — everything that needs the full `RecipeDetail`.
private struct RecipeDetailBody: View {
    let detail: RecipeDetail

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            if !detail.dietaryWarnings.isEmpty {
                warningBlock(title: "Dietary warnings", items: detail.dietaryWarnings)
            }
            ingredients
            steps
            if !detail.creatorNotes.isEmpty {
                notes
            }
        }
    }

    private var ingredients: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionTitle("Ingredients")
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(detail.ingredients) { ingredient in
                    IngredientRow(ingredient: ingredient)
                }
            }
            .padding(Spacing.lg)
            .background(SLColor.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("Steps")
                Spacer()
                transparencyLabel
            }
            VStack(alignment: .leading, spacing: Spacing.lg) {
                ForEach(Array(detail.orderedSteps.enumerated()), id: \.element.id) { index, step in
                    StepRow(number: index + 1, step: step)
                }
            }
        }
    }

    /// PRD §13.4 — label the provenance of the instructions.
    private var transparencyLabel: some View {
        let pill = StepsHeaderPresentation(detail: detail).provenancePill
        return MetadataPill(text: pill, systemImage: "person.text.rectangle", style: .accent,
                            accessibilityLabel: "Source: \(pill)")
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionTitle("Creator notes")
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(detail.creatorNotes, id: \.self) { note in
                    Text(note)
                        .font(SLFont.body)
                        .foregroundStyle(SLColor.textPrimary)
                }
            }
            .padding(Spacing.lg)
            .background(SLColor.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        }
    }

    private func warningBlock(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(SLFont.headline)
            ForEach(items, id: \.self) { item in
                Text(item).font(SLFont.body)
            }
        }
        .foregroundStyle(SLColor.warning)
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SLColor.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(SLFont.title2)
            .foregroundStyle(SLColor.textPrimary)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct IngredientRow: View {
    let ingredient: Ingredient

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
            Text(RecipeFormatting.quantity(ingredient.quantity, unit: ingredient.unit) ?? "—")
                .font(SLFont.bodyEmphasis.monospacedDigit())
                .foregroundStyle(SLColor.accent)
                .frame(minWidth: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.xs) {
                    Text(ingredient.name)
                        .font(SLFont.body)
                        .foregroundStyle(SLColor.textPrimary)
                    if ingredient.optional {
                        Text("optional")
                            .font(SLFont.caption)
                            .foregroundStyle(SLColor.textSecondary)
                            .italic()
                    }
                }
                if let preparation = ingredient.preparation, !preparation.isEmpty {
                    Text(preparation)
                        .font(SLFont.footnote)
                        .foregroundStyle(SLColor.textSecondary)
                }
                if let notes = ingredient.notes, !notes.isEmpty {
                    Text(notes)
                        .font(SLFont.footnote)
                        .foregroundStyle(SLColor.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: Metrics.minTapTarget)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if let qty = RecipeFormatting.quantity(ingredient.quantity, unit: ingredient.unit) { parts.append(qty) }
        parts.append(ingredient.name)
        if ingredient.optional { parts.append("optional") }
        if let preparation = ingredient.preparation { parts.append(preparation) }
        return parts.joined(separator: ", ")
    }
}

private struct StepRow: View {
    let presentation: StepRowPresentation

    init(number: Int, step: RecipeStep) {
        presentation = StepRowPresentation(number: number, step: step)
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Text(presentation.numberText)
                .font(SLFont.numeral)
                .foregroundStyle(Color.white)
                .frame(width: 36, height: 36)
                .background(SLColor.accent, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(presentation.instruction)
                    .font(SLFont.body)
                    .foregroundStyle(SLColor.textPrimary)
                if presentation.timePill != nil || presentation.provenancePill != nil {
                    HStack(spacing: Spacing.xs) {
                        if let time = presentation.timePill {
                            MetadataPill(text: time, systemImage: "timer")
                        }
                        // PRD §13.4: any step that is not the creator's own words says so, in place.
                        if let provenance = presentation.provenancePill {
                            MetadataPill(text: provenance, systemImage: "sparkles", style: .accent,
                                         accessibilityLabel: "Source: \(provenance)")
                        }
                    }
                }
                ForEach(presentation.successCues, id: \.self) { cue in
                    Label {
                        Text(cue).font(SLFont.callout)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    .foregroundStyle(SLColor.success)
                    .accessibilityLabel("Success cue: \(cue)")
                }
                ForEach(presentation.warnings, id: \.self) { warning in
                    Label {
                        Text(warning).font(SLFont.callout.weight(.semibold))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(SLColor.warning)
                    .accessibilityLabel("Warning: \(warning)")
                }
                if let note = presentation.creatorNoteText {
                    Text(note)
                        .font(SLFont.footnote)
                        .italic()
                        .foregroundStyle(SLColor.textSecondary)
                }
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SLColor.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.accessibilityLabel)
    }
}
