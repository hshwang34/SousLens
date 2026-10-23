import SwiftUI

/// Session end (PRD §6): how it went, swaps used, private note, Save my changes, Done.
struct SessionEndView: View {
    @State private var model: SessionEndViewModel
    let onCancel: () -> Void

    init(cooking: CookingViewModel, onCancel: @escaping () -> Void) {
        _model = State(initialValue: SessionEndViewModel(cooking: cooking))
        self.onCancel = onCancel
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    if let summary = model.stepsSummary {
                        Text(summary).font(SLFont.body)
                    }
                } header: {
                    Text("You reached the last step")
                }

                Section("How did it go?") {
                    ForEach(OutcomeResult.allCases) { result in
                        Button {
                            model.result = result
                        } label: {
                            HStack {
                                Text(result.title)
                                    .font(SLFont.title3)
                                    .foregroundStyle(SLColor.textPrimary)
                                Spacer()
                                if model.result == result {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(SLColor.accent)
                                }
                            }
                            .frame(minHeight: 52)
                        }
                        .accessibilityAddTraits(model.result == result ? .isSelected : [])
                        .accessibilityIdentifier("end.outcome.\(result.rawValue)")
                    }
                }

                if model.showsSaveChanges {
                    Section {
                        ForEach(model.adaptations) { swap in
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text("\(swap.original) → \(swap.replacement)").font(SLFont.body)
                                Text(swap.displayLabel).font(SLFont.caption).foregroundStyle(SLColor.textSecondary)
                                if swap.conflictsWithAllergies {
                                    Label("Conflicts with your allergies", systemImage: "exclamationmark.octagon.fill")
                                        .font(SLFont.caption.weight(.semibold))
                                        .foregroundStyle(SLColor.danger)
                                }
                            }
                        }
                        if model.canSaveChanges {
                            Toggle("Save my changes", isOn: $model.saveChanges)
                                .frame(minHeight: Metrics.minTapTarget)
                                .accessibilityIdentifier("end.saveChanges")
                        }
                    } header: {
                        Text("Your swaps")
                    } footer: {
                        if model.hasAllergyConflict {
                            Text("A swap conflicts with your allergies, so these changes can’t be saved for next time. Undo it from the cooking menu first.")
                        } else {
                            Text("Saved privately for next time (“Use my changes from last time”). Nobody else sees them.")
                        }
                    }
                }

                Section {
                    TextField("What would you do differently? (optional)", text: $model.note, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("end.note")
                } header: {
                    Text("Private note")
                } footer: {
                    Text("Only you can see this note.")
                }

                if let error = model.errorMessage {
                    Section {
                        Text(error).font(SLFont.footnote).foregroundStyle(SLColor.danger)
                        if model.showsReconnect {
                            Button(model.isReconnecting ? "Reconnecting…" : "Reconnect") {
                                Task { await model.reconnect() }
                            }
                            .disabled(model.isReconnecting)
                            .frame(minHeight: Metrics.minTapTarget)
                            .accessibilityIdentifier("end.reconnect")
                        }
                    } footer: {
                        Text("Your outcome, note and choices are kept until this is sent.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(SLColor.background)
            .navigationTitle("Finish cooking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep cooking", action: onCancel)
                        .disabled(model.isFinishing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { _ = await model.finish() }
                    } label: {
                        if model.isFinishing { ProgressView() } else { Text("Done").bold() }
                    }
                    .disabled(!model.canFinish)
                    .accessibilityIdentifier("end.done")
                }
            }
        }
    }
}
