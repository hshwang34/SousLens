import SwiftUI

/// Scan review (PRD §6): one editable row per candidate, confidence shown as an estimate, an
/// "Unknowns" section, and explicit duplicate choices. Only "Add N items" writes to the pantry.
struct ScanReviewView: View {
    @Bindable var model: ScanReviewViewModel
    let onAdded: ([PantryItem]) -> Void

    var body: some View {
        List {
            if model.showsDemoBanner {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text("Demo mode — not a real detection")
                                .font(SLFont.headline)
                            Text("These items come from a fixed sample, not from your photo, so none are ticked. Tick only what you really have.")
                                .font(SLFont.footnote)
                        }
                    } icon: {
                        Image(systemName: "theatermasks")
                    }
                    .foregroundStyle(SLColor.warning)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("review.demoBanner")
                }
            }

            Section {
                if model.rows.isEmpty {
                    Text("Nothing recognisable was found. Try again, or add items by hand.")
                        .font(SLFont.callout)
                        .foregroundStyle(SLColor.textSecondary)
                }
                ForEach($model.rows) { $row in
                    ReviewRowView(row: $row, onChoose: { choice in model.choose(row.id, choice) })
                }
            } header: {
                Text(model.sourceLabel)
            } footer: {
                Text("“Likely”, “Maybe” and “Not sure” are rough estimates, not guarantees. Untick anything that’s wrong; unticked items are not added.")
            }

            if !model.unknowns.isEmpty {
                Section {
                    ForEach(model.unknowns, id: \.self) { unknown in
                        Label(unknown, systemImage: "questionmark.square.dashed")
                            .font(SLFont.callout)
                            .foregroundStyle(SLColor.textSecondary)
                    }
                } header: {
                    Text("Unknowns")
                } footer: {
                    Text("Couldn’t tell what these are. Add them by hand if you know.")
                }
            }

            Section {
                if let message = model.conflictMessage {
                    Text(message)
                        .font(SLFont.footnote)
                        .foregroundStyle(SLColor.warning)
                        .accessibilityIdentifier("review.conflictMessage")
                }
                if let error = model.error {
                    Text(error)
                        .font(SLFont.footnote)
                        .foregroundStyle(SLColor.danger)
                }
                Button {
                    Task {
                        if let added = await model.confirm() { onAdded(added) }
                    }
                } label: {
                    if model.isConfirming {
                        ProgressView().tint(.white).frame(maxWidth: .infinity)
                    } else {
                        Text(model.confirmTitle)
                    }
                }
                .buttonStyle(SLButtonStyle(prominent: true))
                .disabled(!model.canConfirm)
                .slDisabledAppearance(!model.canConfirm)
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("review.confirm")
                if let blocking = model.blockingMessage {
                    Text(blocking)
                        .font(SLFont.footnote)
                        .foregroundStyle(SLColor.textSecondary)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(SLColor.background)
        .navigationTitle("Review items")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ReviewRowView: View {
    @Binding var row: ReviewRow
    let onChoose: (DuplicateChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                Toggle(isOn: $row.accepted) {
                    EmptyView()
                }
                .labelsHidden()
                .toggleStyle(CheckboxToggleStyle())
                .accessibilityLabel(row.accepted ? "Add \(row.cleanName)" : "Don’t add \(row.cleanName)")
                .accessibilityIdentifier("review.accept")

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    TextField("Name", text: $row.name)
                        .font(SLFont.bodyEmphasis)
                        .textInputAutocapitalization(.never)
                        .accessibilityLabel("Name")
                        .accessibilityIdentifier("review.name")
                    HStack(spacing: Spacing.sm) {
                        TextField("Qty", text: $row.quantityText)
                            .keyboardType(.decimalPad)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(minWidth: Metrics.minTapTarget, alignment: .leading)
                            .accessibilityLabel("Quantity")
                        Picker("Unit", selection: $row.unit) {
                            Text("no unit").tag(String?.none)
                            ForEach(PantryUnits.all, id: \.self) { unit in
                                Text(PantryUnits.label(unit)).tag(Optional(unit))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        if row.isEstimate {
                            Text("estimate")
                                .font(SLFont.caption)
                                .italic()
                                .foregroundStyle(SLColor.textSecondary)
                        }
                    }
                    HStack(spacing: Spacing.sm) {
                        MetadataPill(text: row.confidenceText, systemImage: binImage,
                                     accessibilityLabel: "Confidence: \(row.candidate.confidenceBin.label), an estimate")
                        if let evidence = row.evidenceText {
                            Text(evidence)
                                .font(SLFont.footnote)
                                .foregroundStyle(SLColor.textSecondary)
                                .lineLimit(2)
                        }
                    }
                }
            }

            if let duplicate = row.duplicateText {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Label(duplicate, systemImage: "square.on.square")
                        .font(SLFont.callout.weight(.semibold))
                        .foregroundStyle(SLColor.warning)
                    HStack(spacing: Spacing.sm) {
                        ForEach(DuplicateChoice.allCases, id: \.self) { choice in
                            Button {
                                onChoose(choice)
                            } label: {
                                Label(choice.label, systemImage: row.duplicateChoice == choice ? "largecircle.fill.circle" : "circle")
                                    .font(SLFont.callout)
                                    .frame(minHeight: Metrics.minTapTarget)
                            }
                            .buttonStyle(.bordered)
                            .tint(row.duplicateChoice == choice ? SLColor.accent : SLColor.textSecondary)
                            .accessibilityAddTraits(row.duplicateChoice == choice ? .isSelected : [])
                            .accessibilityIdentifier(choice == .merge ? "review.merge" : "review.keepBoth")
                        }
                    }
                    Text(DuplicateChoice.hint)
                        .font(SLFont.footnote)
                        .foregroundStyle(SLColor.textSecondary)
                    if row.needsDuplicateChoice {
                        Text("Choose one to continue.")
                            .font(SLFont.footnote)
                            .foregroundStyle(SLColor.textSecondary)
                    }
                }
                .padding(.leading, 36)
            }

            if let problem = row.problem {
                Text(problem)
                    .font(SLFont.footnote)
                    .foregroundStyle(SLColor.danger)
                    .padding(.leading, 36)
            }
        }
        .padding(.vertical, Spacing.xs)
        .opacity(row.accepted ? 1 : 0.6)
    }

    private var binImage: String {
        switch row.candidate.confidenceBin {
        case .high: return "circle.fill"
        case .medium: return "circle.lefthalf.filled"
        case .unknown: return "circle.dotted"
        }
    }
}

/// Square checkbox with a 44pt target.
struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                .font(.title2)
                .foregroundStyle(configuration.isOn ? SLColor.accent : SLColor.textSecondary)
                .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? [.isButton, .isSelected] : .isButton)
    }
}
