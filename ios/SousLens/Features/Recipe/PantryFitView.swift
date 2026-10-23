import SwiftUI

/// Pantry fit (PRD §6, J3): Available / Uncertain / Missing / Optional with a reason per line.
struct PantryFitView: View {
    @Environment(AppEnvironment.self) private var environment
    let recipeVersionId: UUID
    let recipeTitle: String

    @State private var model: PantryFitViewModel?
    @State private var editor: PantryItemEditorModel?
    @State private var swapSheet: SwapTarget?

    /// The ingredient line a "Find a swap" sheet is open for.
    private struct SwapTarget: Identifiable {
        let ingredientRef: String
        let name: String
        var id: String { ingredientRef }
    }

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(SLColor.background)
        .navigationTitle("Pantry fit")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: environment.pantryRevision) {
            let model = self.model ?? makeModel()
            self.model = model
            await model.load()
            await model.loadVariation()
        }
        .sheet(item: $swapSheet) { target in
            SubstitutionSheet(
                model: SubstitutionSheetViewModel(recipeVersionId: recipeVersionId, ingredientRef: target.ingredientRef,
                                                  ingredientName: target.name, service: environment.api),
                onApprove: { swap in model?.approve(swap) },
                onFindAnotherRecipe: { environment.showExplore() }
            )
        }
        .sheet(item: $editor) { editor in
            PantryItemEditorView(model: editor) { _ in
                // The revision bump re-runs the fit.
                environment.notePantryChanged()
            }
        }
    }

    private func makeModel() -> PantryFitViewModel {
        let model = PantryFitViewModel(recipeVersionId: recipeVersionId, recipeTitle: recipeTitle,
                                       service: environment.api, cooking: environment.api)
        model.onPantryChanged = { [environment] in environment.notePantryChanged() }
        return model
    }

    @ViewBuilder
    private func content(_ model: PantryFitViewModel) -> some View {
        switch model.phase {
        case .loading:
            ProgressView("Checking your pantry…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            EmptyStateView(
                systemImage: "wifi.exclamationmark",
                title: "Couldn’t check your pantry",
                message: message,
                primary: EmptyStateView.Action("Try again") { Task { await model.load() } }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            loaded(model)
        }
    }

    private func loaded(_ model: PantryFitViewModel) -> some View {
        List {
            Section {
                header(model)
                    .listRowBackground(Color.clear)
            }
            if let error = model.actionError {
                Section {
                    Text(error).font(SLFont.footnote).foregroundStyle(SLColor.danger)
                }
            }
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        FitRowView(
                            row: row,
                            identifier: "fit.\(section.kind.rawValue)",
                            isBusy: row.pantryItemId.map(model.busyItemIds.contains) ?? false,
                            onAdd: {
                                editor = PantryItemEditorModel(mode: .add, form: model.addForm(for: row), service: environment.api)
                            },
                            onStillHave: {
                                if let id = row.pantryItemId { Task { await model.confirmStillHave(pantryItemId: id) } }
                            },
                            onFixAmount: {
                                if let item = model.pantryItem(for: row) {
                                    editor = PantryItemEditorModel(mode: .edit(item), service: environment.api)
                                }
                            },
                            onFindSwap: { swapSheet = SwapTarget(ingredientRef: row.id, name: row.name) },
                            onUndoSwap: { model.revertSwap(ingredientRef: row.id) }
                        )
                    }
                } header: {
                    Label("\(section.kind.title) · \(section.rows.count)", systemImage: section.kind.systemImage)
                        .foregroundStyle(color(for: section.kind))
                        .accessibilityLabel("\(section.kind.title), \(section.rows.count)")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await model.load() }
        .safeAreaInset(edge: .bottom) {
            startBar(model)
        }
    }

    /// Adaptations preview + Start cooking (J3 step 6).
    private func startBar(_ model: PantryFitViewModel) -> some View {
        VStack(spacing: Spacing.sm) {
            if model.canUseVariation {
                Button {
                    model.useVariation()
                } label: {
                    Label("Use my changes from last time", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(SLButtonStyle(prominent: false))
                .accessibilityIdentifier("fit.useVariation")
            }
            if !model.approvedSwapList.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Your swaps for this cook")
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                    ForEach(model.approvedSwapList) { swap in
                        Text("\(swap.ingredientName) → \(swap.candidate) · \(swap.label)")
                            .font(SLFont.footnote)
                            .foregroundStyle(SLColor.textPrimary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("fit.swapSummary")
            }
            if let error = model.startError {
                Text(error).font(SLFont.footnote).foregroundStyle(SLColor.danger)
            }
            Button {
                Task {
                    let epoch = environment.cooking.epoch
                    if let session = await model.startCooking() {
                        environment.cooking.present(newSession: session, epoch: epoch)
                    }
                }
            } label: {
                if model.isStarting {
                    ProgressView().tint(.white)
                } else {
                    Label("Start cooking", systemImage: "flame")
                }
            }
            .buttonStyle(SLButtonStyle(prominent: true))
            .disabled(model.isStarting || model.fit == nil)
            .accessibilityIdentifier("fit.startCooking")
            .accessibilityHint(model.approvedSwapList.isEmpty ? "Starts the recipe as written" : "Starts the recipe with your swaps")
        }
        .padding(.horizontal, Spacing.screen)
        .padding(.vertical, Spacing.sm)
        .background(.regularMaterial)
    }

    private func header(_ model: PantryFitViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(model.recipeTitle)
                .font(SLFont.subheadline)
                .foregroundStyle(SLColor.textSecondary)
            if let headline = model.headline {
                Text(headline)
                    .font(SLFont.title)
                    .foregroundStyle(model.canMake ? SLColor.success : SLColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("fit.headline")
            }
            if let sub = model.subheadline {
                Text(sub).font(SLFont.title3).foregroundStyle(SLColor.textPrimary)
            }
            if let coverage = model.coverageText {
                Text(coverage)
                    .font(SLFont.callout.monospacedDigit())
                    .foregroundStyle(SLColor.textSecondary)
                    .accessibilityLabel(model.coverageAccessibilityLabel ?? coverage)
                    .accessibilityIdentifier("fit.coverage")
            }
            Text("Based on what’s in your pantry. Amounts you haven’t entered count as “check”.")
                .font(SLFont.footnote)
                .foregroundStyle(SLColor.textSecondary)
        }
        .padding(.vertical, Spacing.sm)
    }

    private func color(for kind: FitSection.Kind) -> Color {
        switch kind {
        case .available: return SLColor.success
        case .uncertain: return SLColor.warning
        case .missing: return SLColor.danger
        case .optional: return SLColor.textSecondary
        }
    }
}

private struct FitRowView: View {
    let row: FitRowPresentation
    /// On the summary element only ("fit.missing"), so the buttons keep their own identifiers.
    let identifier: String
    let isBusy: Bool
    let onAdd: () -> Void
    let onStillHave: () -> Void
    let onFixAmount: () -> Void
    let onFindSwap: () -> Void
    let onUndoSwap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            summary
                .accessibilityElement(children: .combine)
                .accessibilityLabel(row.accessibilityLabel)
                .accessibilityIdentifier(identifier)
            if !row.actions.isEmpty {
                HStack(spacing: Spacing.sm) {
                    ForEach(row.actions, id: \.self) { action in
                        Button(action.title) { perform(action) }
                            .buttonStyle(.bordered)
                            .tint(SLColor.accent)
                            .frame(minHeight: Metrics.minTapTarget)
                            .disabled(action == .stillHaveIt && isBusy)
                            .accessibilityLabel(row.name.isEmpty ? action.title : "\(action.title): \(row.name)")
                            .accessibilityIdentifier("fit.action.\(action.rawValue)")
                    }
                }
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.name)
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)
                Spacer()
                if let required = row.requiredText {
                    Text(required)
                        .font(SLFont.callout.monospacedDigit())
                        .foregroundStyle(SLColor.textSecondary)
                }
            }
            Text(row.reason)
                .font(SLFont.callout)
                .foregroundStyle(SLColor.textSecondary)
            if let note = row.conversionNote {
                Text(note)
                    .font(SLFont.footnote)
                    .italic()
                    .foregroundStyle(SLColor.textSecondary)
            }
            if let swap = row.swap {
                Label {
                    Text("Swap: \(swap.candidate)\(swap.ratioOrAmount.map { " (\($0))" } ?? "") · \(swap.label)")
                } icon: {
                    Image(systemName: "arrow.triangle.swap")
                }
                .font(SLFont.callout.weight(.semibold))
                .foregroundStyle(SLColor.accent)
            }
        }
    }

    private func perform(_ action: FitRowPresentation.Action) {
        switch action {
        case .findSwap: onFindSwap()
        case .undoSwap: onUndoSwap()
        case .addToPantry: onAdd()
        case .stillHaveIt: if !isBusy { onStillHave() }
        case .fixAmount: onFixAmount()
        }
    }
}
