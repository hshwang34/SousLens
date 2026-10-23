import SwiftUI

/// One ingredient: name, quantity, unit, optional, preparation, notes.
struct IngredientEditor: View {
    @Bindable var model: DraftEditorViewModel
    let ingredientId: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool

    private var index: Int? { model.form.ingredients.firstIndex { $0.id == ingredientId } }

    var body: some View {
        if let index {
            form(index: index)
        } else {
            EmptyStateView(systemImage: "trash", title: "Ingredient removed", message: "This ingredient is no longer part of the draft.",
                           primary: EmptyStateView.Action("Back") { dismiss() })
                .background(SLColor.background)
        }
    }

    private func form(index: Int) -> some View {
        let ingredient = $model.form.ingredients[index]
        return Form {
            Section {
                TextField("Name (e.g. garlic)", text: ingredient.name)
                    .focused($nameFocused)
                    .accessibilityIdentifier("ingredient.name")
                problemRows(model.problems(in: "ingredients", row: index))
                HStack {
                    TextField("Quantity", value: ingredient.quantity, format: .number)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("ingredient.quantity")
                    Divider()
                    TextField("Unit (cup, g, clove…)", text: ingredient.unit)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("ingredient.unit")
                }
                Toggle("Optional", isOn: ingredient.optional)
                    .accessibilityIdentifier("ingredient.optional")
            } header: {
                Text("Ingredient")
            } footer: {
                Text("Leave quantity empty for “to taste”.")
            }
            Section {
                TextField("Preparation (e.g. minced)", text: ingredient.preparation, axis: .vertical)
                    .accessibilityIdentifier("ingredient.preparation")
                TextField("Notes (brand, substitutes, where to find it)", text: ingredient.notes, axis: .vertical)
                    .lineLimit(1...4)
                    .accessibilityIdentifier("ingredient.notes")
            } header: {
                Text("Details")
            }
            Section {
                Button(role: .destructive) {
                    model.form.removeIngredients(at: IndexSet(integer: index))
                    dismiss()
                } label: {
                    Label("Remove ingredient", systemImage: "trash")
                        .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)
                }
                .accessibilityIdentifier("ingredient.remove")
            }
        }
        .scrollContentBackground(.hidden)
        .background(SLColor.background)
        .navigationTitle(ingredient.wrappedValue.name.isEmpty ? "New ingredient" : ingredient.wrappedValue.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("ingredient.done")
            }
        }
        .onAppear { if ingredient.wrappedValue.name.isEmpty { nameFocused = true } }
    }

    @ViewBuilder
    private func problemRows(_ problems: [DraftProblem]) -> some View {
        ForEach(problems, id: \.self) { problem in
            Label(problem.message, systemImage: "exclamationmark.circle.fill")
                .font(SLFont.footnote)
                .foregroundStyle(SLColor.danger)
        }
    }
}
