import SwiftUI

/// Pantry fit (PRD §6, J3): Available / Uncertain / Missing / Optional with a reason per line.
struct PantryFitView: View {
    @Environment(AppEnvironment.self) private var environment
    let recipeVersionId: UUID
    let recipeTitle: String

    @State private var model: PantryFitViewModel?
    @State private var editor: PantryItemEditorModel?

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
        }
        .sheet(item: $editor) { editor in
            PantryItemEditorView(model: editor) { _ in
                // The revision bump re-runs the fit.
                environment.notePantryChanged()
            }
        }
    }

    private func makeModel() -> PantryFitViewModel {
        let model = PantryFitViewModel(recipeVersionId: recipeVersionId, recipeTitle: recipeTitle, service: environment.api)
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
                            isBusy: row.pantryItemId.map(model.busyItemIds.contains) ?? false,
                            onAdd: {
                                editor = PantryItemEditorModel(mode: .add, form: model.addForm(for: row), service: environment.api)
                            },
                            onStillHave: {
                                if let id = row.pantryItemId { Task { await model.confirmStillHave(pantryItemId: id) } }
                            }
                        )
                        .accessibilityIdentifier("fit.\(section.kind.rawValue)")
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
    let isBusy: Bool
    let onAdd: () -> Void
    let onStillHave: () -> Void

    var body: some View {
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
            if !row.actions.isEmpty {
                HStack(spacing: Spacing.sm) {
                    ForEach(row.actions, id: \.self) { action in
                        Button(action.title) { perform(action) }
                            .buttonStyle(.bordered)
                            .tint(SLColor.accent)
                            .frame(minHeight: Metrics.minTapTarget)
                            .disabled(action == .stillHaveIt && isBusy)
                    }
                }
            }
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilityLabel)
        // The combined element swallows the buttons; expose each one as a named action.
        .modifier(FitRowActions(row: row, perform: perform))
    }

    private func perform(_ action: FitRowPresentation.Action) {
        switch action {
        case .addToPantry: onAdd()
        case .stillHaveIt: if !isBusy { onStillHave() }
        }
    }
}

private struct FitRowActions: ViewModifier {
    let row: FitRowPresentation
    let perform: (FitRowPresentation.Action) -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityActions {
                ForEach(row.actions, id: \.self) { action in
                    Button(row.name.isEmpty ? action.title : "\(action.title): \(row.name)") { perform(action) }
                }
            }
    }
}
