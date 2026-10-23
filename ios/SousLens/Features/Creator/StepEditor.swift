import SwiftUI

/// One step: instruction, time estimate, ingredients used, success cues, warnings, creator note.
struct StepEditor: View {
    @Bindable var model: DraftEditorViewModel
    let stepId: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var instructionFocused: Bool

    private var index: Int? { model.form.steps.firstIndex { $0.id == stepId } }

    var body: some View {
        if let index {
            form(index: index)
        } else {
            EmptyStateView(systemImage: "trash", title: "Step removed", message: "This step is no longer part of the draft.",
                           primary: EmptyStateView.Action("Back") { dismiss() })
                .background(SLColor.background)
        }
    }

    private func form(index: Int) -> some View {
        let step = $model.form.steps[index]
        return Form {
            Section {
                TextField("What to do (e.g. Sear the thighs skin-side down until deeply browned)", text: step.instruction, axis: .vertical)
                    .characterLimit(step.instruction, DraftLimits.instruction)
                    .lineLimit(3...8)
                    .focused($instructionFocused)
                    .accessibilityIdentifier("step.instruction")
                problemRows(model.problems(in: "steps", row: index))
                MinutesField(label: "Takes about", value: step.estimatedMinutes)
            } header: {
                Text("Step \(index + 1)")
            }

            Section {
                if model.form.ingredients.isEmpty {
                    Text("Add ingredients to the recipe first, then link them here.")
                        .font(SLFont.footnote)
                        .foregroundStyle(SLColor.textSecondary)
                } else {
                    ForEach(model.form.ingredients) { ingredient in
                        let isOn = step.wrappedValue.ingredientRefs.contains(ingredient.id)
                        Button {
                            toggle(ingredient.id, in: step)
                        } label: {
                            HStack {
                                Text(ingredient.displayLine)
                                    .foregroundStyle(SLColor.textPrimary)
                                Spacer()
                                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isOn ? SLColor.accent : SLColor.textSecondary)
                            }
                            .frame(minHeight: Metrics.minTapTarget)
                        }
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                        .accessibilityLabel("\(ingredient.displayLine), \(isOn ? "used in this step" : "not used in this step")")
                    }
                }
            } header: {
                Text("Ingredients used")
            }

            StringListSection(
                title: "Success cues",
                items: step.successCues,
                placeholder: "What tells you it worked (e.g. edges are crisp)",
                addLabel: "Add cue",
                problems: []
            )
            StringListSection(
                title: "Warnings",
                items: step.warnings,
                placeholder: "What can go wrong (e.g. the sauce burns fast)",
                addLabel: "Add warning",
                problems: []
            )

            Section {
                TextField("A personal tip for this step", text: step.creatorNote, axis: .vertical)
                    .characterLimit(step.creatorNote, DraftLimits.creatorNote)
                    .lineLimit(1...4)
                    .accessibilityIdentifier("step.creatorNote")
            } header: {
                Text("Creator note")
            }

            Section {
                Button(role: .destructive) {
                    model.form.removeSteps(at: IndexSet(integer: index))
                    dismiss()
                } label: {
                    Label("Remove step", systemImage: "trash")
                        .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)
                }
                .accessibilityIdentifier("step.remove")
            }
        }
        .scrollContentBackground(.hidden)
        .background(SLColor.background)
        .navigationTitle("Step \(index + 1)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("step.done")
            }
        }
        .onAppear { if step.wrappedValue.instruction.isEmpty { instructionFocused = true } }
    }

    private func toggle(_ ingredientId: String, in step: Binding<EditableStep>) {
        if let at = step.wrappedValue.ingredientRefs.firstIndex(of: ingredientId) {
            step.wrappedValue.ingredientRefs.remove(at: at)
        } else {
            step.wrappedValue.ingredientRefs.append(ingredientId)
        }
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
