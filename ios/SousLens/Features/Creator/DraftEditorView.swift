import SwiftUI

/// Recipe create/edit (PRD §6, REC-03/04/06): metadata, ingredients, steps, notes, warnings;
/// autosaves as a draft, previews through the real detail screen, publishes only after an
/// explicit confirmation.
struct DraftEditorView: View {
    @Bindable var model: DraftEditorViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showPreview = false
    @State private var showCloseConfirmation = false
    @State private var isClosing = false
    @State private var path: [Route] = []
    @State private var editMode: EditMode = .inactive

    private enum Route: Hashable {
        case ingredient(String)
        case step(String)
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let result = model.publishResult {
                    PublishedView(result: result, title: model.form.title) { dismiss() }
                } else {
                    editor
                }
            }
            .background(SLColor.background)
        }
        .interactiveDismissDisabled()
        .task { await model.resolveNextVersionNumber() }
    }

    // MARK: - Editor

    private var editor: some View {
        Form {
            if model.isPublishedReadOnly {
                Section {
                    Label("This draft was published and is read-only. Open the recipe and tap Edit to start a new version.", systemImage: "lock.fill")
                        .font(SLFont.footnote)
                        .foregroundStyle(SLColor.warning)
                }
            }
            metadataSection
            ingredientsSection
            stepsSection
            StringListSection(
                title: "Creator notes",
                items: $model.form.creatorNotes,
                placeholder: "A tip for whoever cooks this",
                addLabel: "Add note",
                problems: model.problems(for: "creator_notes")
            )
            StringListSection(
                title: "Dietary warnings",
                items: $model.form.dietaryWarnings,
                placeholder: "Contains peanuts",
                addLabel: "Add warning",
                problems: model.problems(for: "dietary_warnings")
            )
        }
        .disabled(model.isPublishedReadOnly)
        .environment(\.editMode, $editMode)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(model.draft.recipeId == nil ? "New recipe" : "Edit recipe")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Route.self) { route in
            switch route {
            case .ingredient(let id): IngredientEditor(model: model, ingredientId: id)
            case .step(let id): StepEditor(model: model, stepId: id)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") { close() }
                    .disabled(isClosing)
                    .accessibilityIdentifier("draft.close")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if model.form.ingredients.count + model.form.steps.count > 1, !model.isPublishedReadOnly {
                    // One control for the whole form: SwiftUI's edit mode is per-list anyway.
                    Button(editMode == .active ? "Done" : "Reorder") {
                        withAnimation { editMode = editMode == .active ? .inactive : .active }
                    }
                    .frame(minWidth: Metrics.minTapTarget, minHeight: Metrics.minTapTarget)
                    .accessibilityLabel(editMode == .active ? "Done reordering" : "Reorder ingredients and steps")
                    .accessibilityIdentifier("draft.reorder")
                }
                Button("Preview") {
                    KeyboardFocus.endEditing()
                    showPreview = true
                }
                .frame(minWidth: Metrics.minTapTarget, minHeight: Metrics.minTapTarget)
                .accessibilityIdentifier("draft.preview")
            }
        }
        .safeAreaInset(edge: .bottom) { publishBar }
        .sheet(isPresented: $showPreview) {
            DraftPreviewView(detail: model.previewDetail())
        }
        .sheet(isPresented: publishSheetBinding) {
            PublishConfirmationSheet(model: model)
        }
        .confirmationDialog("Your latest changes haven’t been saved.", isPresented: $showCloseConfirmation, titleVisibility: .visible) {
            Button("Retry saving") { Task { await model.retrySave() } }
            Button("Discard unsaved changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("The draft on the server still has what was saved last time.")
        }
    }

    private var publishSheetBinding: Binding<Bool> {
        Binding(
            get: {
                switch model.publishPhase {
                case .confirming, .publishing, .failed: return true
                case .idle, .published: return false
                }
            },
            set: { shown in if !shown { model.cancelPublish() } }
        )
    }

    private func close() {
        KeyboardFocus.endEditing()
        // Nothing in a read-only (already published) draft can be saved, so there is nothing to ask.
        if model.isPublishedReadOnly {
            dismiss()
            return
        }
        isClosing = true
        Task {
            await model.flush()
            isClosing = false
            if model.saveStatus.isFailure {
                showCloseConfirmation = true
            } else {
                dismiss()
            }
        }
    }

    // MARK: - Sections

    private var metadataSection: some View {
        Section {
            TextField("Title", text: $model.form.title, axis: .vertical)
                .font(SLFont.title3)
                .characterLimit($model.form.title, DraftLimits.title)
                .accessibilityIdentifier("draft.title")
            problemRows(model.problems(for: "title"))
            TextField("Summary — what makes this dish worth cooking?", text: $model.form.summary, axis: .vertical)
                .lineLimit(2...5)
                .characterLimit($model.form.summary, DraftLimits.summary)
                .accessibilityIdentifier("draft.summary")
            problemRows(model.problems(for: "summary"))
            TagChipsEditor(tags: $model.form.tags)
            problemRows(model.problems(for: "tags"))
            Stepper(value: $model.form.servings, in: 1...99) {
                LabeledContent("Servings", value: String(model.form.servings))
            }
            .accessibilityIdentifier("draft.servings")
            problemRows(model.problems(for: "servings"))
            MinutesField(label: "Prep time", value: $model.form.prepMinutes)
            problemRows(model.problems(for: "prep_minutes"))
            MinutesField(label: "Cook time", value: $model.form.cookMinutes)
            problemRows(model.problems(for: "cook_minutes"))
        } header: {
            Text("Recipe")
        }
    }

    private var ingredientsSection: some View {
        Section {
            ForEach(Array(model.form.ingredients.enumerated()), id: \.element.id) { index, ingredient in
                NavigationLink(value: Route.ingredient(ingredient.id)) {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        HStack(spacing: Spacing.xs) {
                            Text(ingredient.displayLine)
                                .foregroundStyle(SLColor.textPrimary)
                            if ingredient.optional {
                                Text("optional")
                                    .font(SLFont.caption)
                                    .foregroundStyle(SLColor.textSecondary)
                            }
                        }
                        inlineProblems(model.problems(in: "ingredients", row: index))
                    }
                }
                .accessibilityIdentifier("draft.ingredient.\(index)")
            }
            .onDelete { model.form.removeIngredients(at: $0) }
            .onMove { model.form.moveIngredients(from: $0, to: $1) }
            Button {
                let added = model.form.addIngredient()
                path.append(.ingredient(added.id))
            } label: {
                Label("Add ingredient", systemImage: "plus.circle.fill")
            }
            .accessibilityIdentifier("draft.addIngredient")
            problemRows(model.sectionProblems("ingredients"))
        } header: {
            Text("Ingredients")
        } footer: {
            Text("Swipe to delete. Tap Reorder (top right) to move ingredients and steps.")
        }
    }

    private var stepsSection: some View {
        Section {
            ForEach(Array(model.form.steps.enumerated()), id: \.element.id) { index, step in
                NavigationLink(value: Route.step(step.id)) {
                    HStack(alignment: .top, spacing: Spacing.md) {
                        Text(String(index + 1))
                            .font(SLFont.numeral)
                            .foregroundStyle(Color.white)
                            .frame(width: 28, height: 28)
                            .background(SLColor.accent, in: Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(step.displayLine)
                                .lineLimit(2)
                                .foregroundStyle(SLColor.textPrimary)
                            stepMeta(step)
                            inlineProblems(model.problems(in: "steps", row: index))
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Step \(index + 1): \(step.displayLine)")
                }
                .accessibilityIdentifier("draft.step.\(index)")
            }
            .onDelete { model.form.removeSteps(at: $0) }
            .onMove { model.form.moveSteps(from: $0, to: $1) }
            Button {
                let added = model.form.addStep()
                path.append(.step(added.id))
            } label: {
                Label("Add step", systemImage: "plus.circle.fill")
            }
            .accessibilityIdentifier("draft.addStep")
            problemRows(model.sectionProblems("steps"))
        } header: {
            Text("Steps")
        } footer: {
            Text("Steps are numbered in the order shown. Everything here is labelled “Creator instructions”.")
        }
    }

    @ViewBuilder
    private func stepMeta(_ step: EditableStep) -> some View {
        let parts: [String] = [
            step.estimatedMinutes.map { "About \(RecipeFormatting.minutes($0))" },
            step.successCues.isEmpty ? nil : "\(step.successCues.count) cue\(step.successCues.count == 1 ? "" : "s")",
            step.warnings.isEmpty ? nil : "\(step.warnings.count) warning\(step.warnings.count == 1 ? "" : "s")",
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
        }
    }

    // MARK: - Publish bar

    private var publishBar: some View {
        VStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                SaveStatusLabel(status: model.saveStatus) { Task { await model.retrySave() } }
                Spacer()
                Button {
                    KeyboardFocus.endEditing()
                    model.requestPublish()
                } label: {
                    Label("Publish", systemImage: "paperplane.fill")
                        .padding(.horizontal, Spacing.sm)
                }
                .buttonStyle(SLButtonStyle(prominent: true))
                .fixedSize()
                .disabled(!model.canPublish)
                .slDisabledAppearance(!model.canPublish)
                .accessibilityIdentifier("draft.publish")
                .accessibilityHint(model.canPublish ? "Asks for confirmation before publishing" : publishBlockedHint)
            }
            if !model.canPublish, !model.problems.isEmpty {
                Text(publishBlockedHint)
                    .font(SLFont.footnote)
                    .foregroundStyle(SLColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Spacing.screen)
        .padding(.vertical, Spacing.md)
        .background(.bar)
    }

    private var publishBlockedHint: String {
        let count = model.problems.count
        if count == 0 { return "Save the draft to check whether it can be published." }
        return count == 1 ? "Fix 1 problem to publish." : "Fix \(count) problems to publish."
    }

    // MARK: - Problem rows

    @ViewBuilder
    private func problemRows(_ problems: [DraftProblem]) -> some View {
        ForEach(problems, id: \.self) { problem in
            Label(problem.message, systemImage: "exclamationmark.circle.fill")
                .font(SLFont.footnote)
                .foregroundStyle(SLColor.danger)
                .accessibilityLabel("Problem: \(problem.message)")
        }
    }

    @ViewBuilder
    private func inlineProblems(_ problems: [DraftProblem]) -> some View {
        ForEach(problems, id: \.self) { problem in
            Text(problem.message)
                .font(SLFont.caption)
                .foregroundStyle(SLColor.danger)
        }
    }
}

/// "Saving… / Saved / Couldn’t save · Retry" — the autosave state, always visible.
struct SaveStatusLabel: View {
    let status: DraftEditorViewModel.SaveStatus
    let retry: () -> Void

    var body: some View {
        HStack(spacing: Spacing.xs) {
            switch status {
            case .saved:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(SLColor.success)
                Text("Saved")
            case .pending, .saving:
                ProgressView().controlSize(.small)
                Text("Saving…")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(SLColor.danger)
                Text("Couldn’t save")
                Button("Retry", action: retry)
                    .font(SLFont.bodyEmphasis)
                    .accessibilityIdentifier("draft.retrySave")
            case .rejected:
                // Retrying the same content can't help; the next edit saves again automatically.
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(SLColor.danger)
                Text(status.label)
                    .foregroundStyle(SLColor.danger)
                    .lineLimit(3)
            }
        }
        .font(SLFont.footnote)
        .foregroundStyle(SLColor.textSecondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("draft.saveStatus")
    }
}

/// Optional minutes entry; empty means "not specified".
struct MinutesField: View {
    let label: String
    @Binding var value: Int?

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            NumericTextField(placeholder: "—", value: $value.asDouble, allowsDecimal: false)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 80)
                .accessibilityLabel("\(label) in minutes")
            Text("min")
                .foregroundStyle(SLColor.textSecondary)
                .accessibilityHidden(true)
        }
    }
}

#Preview {
    DraftEditorView(model: DraftEditorViewModel(
        draft: Draft(id: UUID(), recipeId: nil, status: .draft, title: "Garlic pasta", summary: nil, tags: ["pasta"],
                     coverImageUrl: nil, servings: 2, prepMinutes: 5, cookMinutes: 15, ingredients: [], steps: [],
                     creatorNotes: [], dietaryWarnings: [],
                     validation: DraftValidation(publishable: false, problems: [DraftProblem(field: "ingredients", message: "Add at least one ingredient")]),
                     createdAt: Date(), updatedAt: Date()),
        service: AppEnvironment.preview().api,
        creator: Creator(id: UUID(), displayName: "Preview")
    ))
}
