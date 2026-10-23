import SwiftUI

/// Manual add / edit sheet (PAN-01). Used from the Pantry tab and from Pantry fit ("Add to pantry").
struct PantryItemEditorView: View {
    @Bindable var model: PantryItemEditorModel
    let onSaved: ([PantryItem]) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. gochujang", text: $model.form.name)
                        .textInputAutocapitalization(.never)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .accessibilityIdentifier("pantryItem.name")
                } header: {
                    Text("Ingredient")
                }
                Section {
                    TextField("Quantity (optional)", text: $model.form.quantityText)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("pantryItem.quantity")
                    Picker("Unit", selection: $model.form.unit) {
                        Text("None").tag(String?.none)
                        ForEach(PantryUnits.all, id: \.self) { unit in
                            Text(PantryUnits.label(unit)).tag(Optional(unit))
                        }
                    }
                    .accessibilityIdentifier("pantryItem.unit")
                } header: {
                    Text("Amount")
                } footer: {
                    Text("Leave it blank if you’re not sure; recipes will ask you to check.")
                }
                Section {
                    Picker("Location", selection: $model.form.location) {
                        Text("Not set").tag(StorageLocation?.none)
                        ForEach(locationChoices) { location in
                            Text(location.label).tag(Optional(location))
                        }
                    }
                    TextField("Note (optional)", text: $model.form.note, axis: .vertical)
                        .lineLimit(1...4)
                        .accessibilityIdentifier("pantryItem.note")
                }
                if let message = model.error ?? (model.form.name.isEmpty ? nil : model.form.validationMessage) {
                    Section {
                        Text(message)
                            .font(SLFont.footnote)
                            .foregroundStyle(SLColor.danger)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(SLColor.background)
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task {
                                if let saved = await model.save() {
                                    onSaved(saved)
                                    dismiss()
                                }
                            }
                        }
                        .disabled(!model.canSave)
                        .accessibilityIdentifier("pantryItem.save")
                    }
                }
            }
            .confirmationDialog(
                "You already have \(model.conflict?.rawLabel ?? "this")",
                isPresented: Binding(get: { model.conflict != nil }, set: { if !$0 { model.cancelConflict() } }),
                titleVisibility: .visible
            ) {
                Button("Merge") { resolve(.merge) }
                Button("Keep both") { resolve(.keepBoth) }
                Button("Cancel", role: .cancel) { model.cancelConflict() }
            } message: {
                Text(DuplicateChoice.hint)
            }
            .onAppear {
                if case .add = model.mode, model.form.name.isEmpty { nameFocused = true }
            }
        }
    }

    /// The known locations, plus the item's own value when this build doesn't recognise it.
    private var locationChoices: [StorageLocation] {
        if let current = model.form.location, !StorageLocation.known.contains(current) {
            return StorageLocation.known + [current]
        }
        return StorageLocation.known
    }

    private func resolve(_ choice: DuplicateChoice) {
        Task {
            if let saved = await model.resolve(choice) {
                onSaved(saved)
                dismiss()
            }
        }
    }
}
