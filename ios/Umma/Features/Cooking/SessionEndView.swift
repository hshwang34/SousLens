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
                    VStack(spacing: Spacing.md) {
                        DrawnCheck()
                        Text("You reached the last step")
                            .font(SLFont.title2)
                            .foregroundStyle(SLColor.textPrimary)
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        if let summary = model.stepsSummary {
                            Text(summary)
                                .font(SLFont.body)
                                .foregroundStyle(SLColor.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.md)
                    .listRowBackground(Color.clear)
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
                        .disabled(model.editsLocked)
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
                                .disabled(model.editsLocked)
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
                        .disabled(model.editsLocked)
                        .accessibilityIdentifier("end.note")
                } header: {
                    Text("Private note")
                } footer: {
                    Text("Only you can see this note.")
                }

                if model.errorMessage != nil || model.showsReconnect || model.editsLocked {
                    Section {
                        if let error = model.errorMessage {
                            Text(error).font(SLFont.footnote).foregroundStyle(SLColor.danger)
                        }
                        if let pending = model.pendingTapText {
                            Text(pending).font(SLFont.footnote.weight(.semibold))
                        }
                        if model.editsLocked {
                            Text(SessionEndViewModel.lockedMessage)
                                .font(SLFont.footnote)
                                .accessibilityIdentifier("end.locked")
                        }
                        if model.asksToResendStaleTap {
                            Text("That tap is more than 2 minutes old. Send it again?").font(SLFont.callout)
                            Button("Send it again") { Task { await model.resendStaleTap() } }
                                .frame(minHeight: Metrics.minTapTarget)
                                .accessibilityIdentifier("end.resend")
                            Button("Discard", role: .destructive) { Task { await model.discardStaleTap() } }
                                .frame(minHeight: Metrics.minTapTarget)
                                .accessibilityIdentifier("end.discard")
                        } else if model.showsReconnect {
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

/// A check mark that draws itself in (brief 006). Under Reduce Motion it fades in, already drawn.
struct DrawnCheck: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 64
    @State private var progress: CGFloat = 0
    @State private var visible = false

    var body: some View {
        ZStack {
            Circle()
                .fill(SLColor.accentSoft)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(SLColor.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            CheckShape()
                .trim(from: 0, to: progress)
                .stroke(SLColor.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                .padding(size * 0.28)
        }
        .frame(width: min(size, 120), height: min(size, 120))
        .opacity(visible ? 1 : 0)
        .onAppear {
            if reduceMotion {
                progress = 1
                withAnimation(.easeInOut(duration: 0.25)) { visible = true }
            } else {
                visible = true
                withAnimation(.easeOut(duration: 0.7).delay(0.15)) { progress = 1 }
            }
        }
        .accessibilityHidden(true)
    }

    private struct CheckShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.1))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.12))
            return path
        }
    }
}
