import SwiftUI

/// "You have unfinished cooks" (409 on Start cooking): Resume one, or Abandon (confirmed) and
/// the start is retried.
struct UnfinishedCooksSheet: View {
    let starter: SessionStarter
    let onResume: (UUID) -> Void
    let onStarted: (CookingSession) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var toAbandon: SessionSummary?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(starter.unfinished) { summary in
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            Text(summary.title).font(SLFont.headline)
                            Text(stepText(summary))
                                .font(SLFont.subheadline)
                                .foregroundStyle(SLColor.textSecondary)
                            HStack(spacing: Spacing.sm) {
                                Button("Resume") {
                                    starter.dismissUnfinished()
                                    dismiss()
                                    onResume(summary.id)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(SLColor.accent)
                                .accessibilityIdentifier("unfinished.resume")
                                Button("Abandon", role: .destructive) { toAbandon = summary }
                                    .buttonStyle(.bordered)
                                    .disabled(starter.busySessionIds.contains(summary.id))
                                    .accessibilityIdentifier("unfinished.abandon")
                                if starter.busySessionIds.contains(summary.id) { ProgressView() }
                            }
                            .frame(minHeight: Metrics.minTapTarget)
                        }
                        .padding(.vertical, Spacing.xs)
                    }
                } footer: {
                    Text("You can have up to 3 cooks open. Resume one, or stop one to start this recipe.")
                }
                if let error = starter.errorMessage {
                    Section { Text(error).font(SLFont.footnote).foregroundStyle(SLColor.danger) }
                }
            }
            .navigationTitle("You have unfinished cooks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        starter.dismissUnfinished()
                        dismiss()
                    }
                }
            }
            .confirmationDialog("Stop “\(toAbandon?.title ?? "")”?", isPresented: Binding(get: { toAbandon != nil }, set: { if !$0 { toAbandon = nil } }), titleVisibility: .visible) {
                Button("Stop that cook", role: .destructive) {
                    if let summary = toAbandon {
                        Task {
                            if let session = await starter.abandon(summary) {
                                dismiss()
                                onStarted(session)
                            }
                        }
                    }
                }
                Button("Keep it", role: .cancel) {}
            } message: {
                Text("That session ends and its swaps aren’t saved. Then this recipe starts.")
            }
        }
    }

    private func stepText(_ summary: SessionSummary) -> String {
        if summary.status == .created { return "Not started" }
        let step = min(summary.stepIndex, max(summary.stepsCount - 1, 0)) + 1
        return "\(summary.status == .paused ? "Paused at" : "At") step \(step) of \(summary.stepsCount)"
    }
}
