import SwiftUI

/// Recipe detail (PRD §6): hero, attribution + version, ingredients, steps with cues/warnings and
/// the §13.4 provenance label, then the actions. Opened from a card (Explore, Saved, Profile) or
/// from a share link with only the id.
struct RecipeDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let recipeId: UUID
    var card: RecipeCard? = nil

    @State private var model: RecipeDetailViewModel?
    @State private var editor: DraftEditorViewModel?
    @State private var isOpeningEditor = false
    @State private var showUnpublishConfirmation = false

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(SLColor.background)
        .navigationTitle(model?.title ?? card?.title ?? "Recipe")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil {
                let created = RecipeDetailViewModel(recipeId: recipeId, card: card, service: environment.api)
                model = created
                await created.load()
            }
        }
        .fullScreenCover(item: $editor, onDismiss: { Task { await model?.load() } }) { editor in
            DraftEditorView(model: editor)
        }
    }

    private func content(_ model: RecipeDetailViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                if let visibility = model.unpublishedVisibility {
                    unpublishedBanner(visibility)
                }
                RecipeHeaderView(
                    title: model.title,
                    creatorName: model.creatorName,
                    versionNumber: model.versionNumber,
                    summary: model.summary,
                    prepMinutes: model.prepMinutes,
                    cookMinutes: model.cookMinutes,
                    servings: model.servings,
                    coverImageURL: model.coverImageURL
                )
                switch model.phase {
                case .loading:
                    ProgressView("Loading recipe…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.xxl)
                case .loaded(let detail):
                    RecipeDetailContent(detail: detail)
                case .error(let message, let retryable):
                    EmptyStateView(
                        systemImage: "wifi.exclamationmark",
                        title: "Couldn’t load the recipe",
                        message: message,
                        primary: retryable ? EmptyStateView.Action("Try again") { Task { await model.load() } } : nil
                    )
                }
                actions(model)
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.bottom, Spacing.xxl)
        }
        .confirmationDialog("Unpublish this recipe?", isPresented: $showUnpublishConfirmation, titleVisibility: .visible) {
            Button("Unpublish", role: .destructive) {
                Task { await model.unpublish() }
            }
            Button("Keep published", role: .cancel) {}
        } message: {
            Text("It disappears from Explore and search. Anyone who already has the link, and any cooking session pinned to this version, keeps it.")
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func actions(_ model: RecipeDetailViewModel) -> some View {
        let loaded = model.detail != nil
        let isOwner = model.isOwner(userId: environment.auth.user?.id)
        VStack(spacing: Spacing.sm) {
            if let error = model.saveError {
                Text(error)
                    .font(SLFont.footnote)
                    .foregroundStyle(SLColor.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Save failed: \(error)")
            }
            Button {
                Task { await model.toggleSave() }
            } label: {
                Label(model.isSaved ? "Unsave" : "Save", systemImage: model.isSaved ? "bookmark.fill" : "bookmark")
            }
            .buttonStyle(SLButtonStyle(prominent: false))
            .disabled(!loaded || model.isTogglingSave)
            .slDisabledAppearance(!loaded)
            .accessibilityIdentifier("recipe.save")
            .accessibilityHint(model.isSaved ? "Removes this recipe from Saved" : "Adds this recipe to Saved")

            ShareLink(item: model.shareURL, subject: Text(model.title), message: Text("\(model.title) on SousLens")) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(SLButtonStyle(prominent: false))
            .accessibilityIdentifier("recipe.share")

            if isOwner {
                ownerActions(model)
            }

            Button("Check my pantry") {}
                .buttonStyle(SLButtonStyle(prominent: false))
                .disabled(true)
                .slDisabledAppearance(true)
            Button("Start cooking") {}
                .buttonStyle(SLButtonStyle(prominent: true))
                .disabled(true)
                .slDisabledAppearance(true)
            Text("Check my pantry and Start cooking are coming in a later build")
                .font(SLFont.footnote)
                .foregroundStyle(SLColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func ownerActions(_ model: RecipeDetailViewModel) -> some View {
        if let error = model.actionError {
            Text(error)
                .font(SLFont.footnote)
                .foregroundStyle(SLColor.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        Button {
            Task { await openEditor(model) }
        } label: {
            if isOpeningEditor {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                Label("Edit", systemImage: "pencil")
            }
        }
        .buttonStyle(SLButtonStyle(prominent: false))
        .disabled(isOpeningEditor)
        .accessibilityIdentifier("recipe.edit")
        .accessibilityHint("Opens a new draft; the published version stays as it is until you publish again")

        if model.unpublishedVisibility == nil {
            Button {
                showUnpublishConfirmation = true
            } label: {
                if model.isUnpublishing {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Label("Unpublish", systemImage: "eye.slash")
                }
            }
            .buttonStyle(SLButtonStyle(prominent: false))
            .disabled(model.isUnpublishing)
            .accessibilityIdentifier("recipe.unpublish")
        }
    }

    private func openEditor(_ model: RecipeDetailViewModel) async {
        guard let user = environment.auth.user else { return }
        isOpeningEditor = true
        defer { isOpeningEditor = false }
        do {
            editor = try await DraftEditorViewModel.forEditing(
                recipeId: recipeId,
                latestVersionNumber: model.versionNumber,
                service: environment.api,
                creator: Creator(id: user.id, displayName: user.displayName)
            )
        } catch {
            model.setActionError((error as? APIError)?.userMessage ?? error.localizedDescription)
        }
    }

    private func unpublishedBanner(_ visibility: RecipeVisibility) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "eye.slash")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Unpublished")
                    .font(SLFont.headline)
                Text("Visibility is now \(visibility.label.lowercased()). It no longer appears in Explore; existing links and pinned sessions keep this version.")
                    .font(SLFont.footnote)
            }
        }
        .foregroundStyle(SLColor.warning)
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SLColor.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Hero + title block shared by the live detail and the draft preview.
struct RecipeHeaderView: View {
    let title: String
    let creatorName: String?
    let versionNumber: Int?
    let summary: String?
    let prepMinutes: Int?
    let cookMinutes: Int?
    let servings: Int?
    let coverImageURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            hero
            header
        }
    }

    private var hero: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .fill(SLColor.accentSoft)
            if let url = coverImageURL {
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
        .accessibilityLabel(coverImageURL == nil ? "No photo yet" : "Recipe photo")
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
            Text(title)
                .font(SLFont.title)
                .foregroundStyle(SLColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: Spacing.sm) {
                if let creatorName {
                    Text("by \(creatorName)")
                        .font(SLFont.subheadline)
                        .foregroundStyle(SLColor.textSecondary)
                }
                if let versionNumber {
                    Text("v\(versionNumber)")
                        .font(SLFont.caption)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xxs)
                        .background(SLColor.surfaceRaised, in: Capsule())
                        .foregroundStyle(SLColor.textSecondary)
                        .accessibilityLabel("Version \(versionNumber)")
                }
            }
            if let summary, !summary.isEmpty {
                Text(summary)
                    .font(SLFont.body)
                    .foregroundStyle(SLColor.textPrimary)
            }
            HStack(spacing: Spacing.sm) {
                if let prep = prepMinutes {
                    MetadataPill(text: "Prep \(RecipeFormatting.minutes(prep))", systemImage: "knife")
                }
                if let cook = cookMinutes {
                    MetadataPill(text: "Cook \(RecipeFormatting.minutes(cook))", systemImage: "flame")
                }
                if let servings {
                    MetadataPill(text: "Serves \(servings)", systemImage: "person.2")
                }
            }
        }
    }
}

/// Ingredients, steps, and notes — everything that needs the full `RecipeDetail`.
struct RecipeDetailContent: View {
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
