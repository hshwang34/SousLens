import SwiftUI

/// My Pantry (PRD §6): confirmed items with provenance and freshness, plus Add / Speak / Scan.
struct PantryView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var model: PantryViewModel?
    @State private var editor: PantryItemEditorModel?
    @State private var capture: PantryCaptureKind?
    @State private var pendingDelete: PantryItem?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(SLColor.background)
            .navigationTitle("Pantry")
            .toolbar { toolbar }
        }
        .task(id: environment.pantryRevision) {
            let model = self.model ?? makeModel()
            self.model = model
            await model.load()
        }
        .sheet(item: $editor) { editor in
            PantryItemEditorView(model: editor) { saved in
                model?.apply(saved)
                environment.notePantryChanged()
            }
        }
        .sheet(item: $capture) { kind in
            PantryCaptureSheet(kind: kind, existingItems: model?.items ?? []) { added in
                model?.apply(added)
                environment.notePantryChanged()
            }
        }
    }

    private func makeModel() -> PantryViewModel {
        let model = PantryViewModel(service: environment.api)
        model.onChanged = { [environment] in environment.notePantryChanged() }
        return model
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { capture = .speak } label: {
                Label("Speak", systemImage: "mic")
            }
            .accessibilityIdentifier("pantry.speak")
            .accessibilityHint("Say or type what you have; you review every item before it’s added")
            Button { capture = .scan } label: {
                Label("Scan", systemImage: "camera")
            }
            .accessibilityIdentifier("pantry.scan")
            .accessibilityHint("Take or choose one photo; you review every item before it’s added")
            Button { openAdd() } label: {
                Label("Add", systemImage: "plus")
            }
            .accessibilityIdentifier("pantry.add")
        }
    }

    private func openAdd(prefill: PantryItemForm? = nil) {
        editor = PantryItemEditorModel(mode: .add, form: prefill, service: environment.api)
    }

    @ViewBuilder
    private func content(_ model: PantryViewModel) -> some View {
        switch model.phase {
        case .loading:
            ProgressView("Loading your pantry…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            EmptyStateView(
                systemImage: "wifi.exclamationmark",
                title: "Couldn’t load your pantry",
                message: message,
                primary: EmptyStateView.Action("Try again") { Task { await model.load() } }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded where model.items.isEmpty:
            ScrollView {
                EmptyStateView(
                    systemImage: "basket",
                    title: "Your pantry is empty",
                    message: "Add what you have, say it, or scan a shelf. SousLens then tells you what a recipe still needs.",
                    primary: EmptyStateView.Action("Add pantry item") { openAdd() },
                    secondary: EmptyStateView.Action("Try the demo recipe") {
                        environment.selectedTab = .explore
                    }
                )
                .padding(.top, Spacing.xxl)
            }
            .refreshable { await model.load() }
        case .loaded:
            list(model)
        }
    }

    private func list(_ model: PantryViewModel) -> some View {
        List {
            if let error = model.actionError {
                Section {
                    Text(error)
                        .font(SLFont.footnote)
                        .foregroundStyle(SLColor.danger)
                }
            }
            Section {
                ForEach(model.rows) { row in
                    PantryRowView(
                        row: row,
                        isBusy: model.busyItemIds.contains(row.id),
                        onStillHave: { Task { await model.confirmStillHave(id: row.id) } }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let item = model.item(id: row.id) {
                            editor = PantryItemEditorModel(mode: .edit(item), service: environment.api)
                        }
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Opens the editor")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            pendingDelete = model.item(id: row.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(SLColor.danger)
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            Task { await model.confirmStillHave(id: row.id) }
                        } label: {
                            Label("Still have it", systemImage: "checkmark")
                        }
                        .tint(SLColor.success)
                    }
                    .accessibilityAction(named: "Delete") { pendingDelete = model.item(id: row.id) }
                    .accessibilityAction(named: "Still have it") { Task { await model.confirmStillHave(id: row.id) } }
                }
            } footer: {
                Text("Tap an item to edit it. Swipe left to delete, right for “Still have it”.")
                    .font(SLFont.footnote)
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await model.load() }
        .confirmationDialog(
            "Delete \(pendingDelete?.rawLabel ?? "this item")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { item in
            Button("Delete", role: .destructive) {
                Task { await model.delete(id: item.id) }
            }
            Button("Keep", role: .cancel) {}
        } message: { _ in
            Text("It’s removed from your pantry. Recipes will no longer count it.")
        }
    }
}

private struct PantryRowView: View {
    let row: PantryRowPresentation
    let isBusy: Bool
    let onStillHave: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.sm) {
                    Text(row.name)
                        .font(SLFont.bodyEmphasis)
                        .foregroundStyle(SLColor.textPrimary)
                    MetadataPill(text: row.badge, systemImage: row.badgeSystemImage)
                }
                HStack(spacing: Spacing.sm) {
                    if let quantity = row.quantityText {
                        Text(quantity)
                            .font(SLFont.callout.monospacedDigit())
                            .foregroundStyle(SLColor.textPrimary)
                        if row.isEstimate {
                            Text("estimate")
                                .font(SLFont.caption)
                                .italic()
                                .foregroundStyle(SLColor.textSecondary)
                        }
                    }
                    if let location = row.locationText {
                        Label(location, systemImage: "shippingbox")
                            .font(SLFont.footnote)
                            .foregroundStyle(SLColor.textSecondary)
                    }
                }
                HStack(spacing: Spacing.sm) {
                    if row.isStale {
                        Label("Check this", systemImage: "exclamationmark.circle")
                            .font(SLFont.caption)
                            .foregroundStyle(SLColor.warning)
                    }
                    Text(row.freshnessText)
                        .font(SLFont.footnote)
                        .foregroundStyle(SLColor.textSecondary)
                }
                if let note = row.note {
                    Text(note)
                        .font(SLFont.footnote)
                        .foregroundStyle(SLColor.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if row.isStale {
                Button("Still have it", action: onStillHave)
                    .font(SLFont.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(SLColor.accent)
                    .frame(minHeight: Metrics.minTapTarget)
                    .disabled(isBusy)
                    .accessibilityIdentifier("pantry.stillHave")
            }
        }
        .padding(.vertical, Spacing.xs)
        .frame(minHeight: Metrics.minTapTarget)
        .opacity(isBusy ? 0.5 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityIdentifier("pantry.row")
    }
}

enum PantryCaptureKind: String, Identifiable {
    case speak, scan
    var id: String { rawValue }
}

/// Speak or Scan, then Scan review, in one sheet. Closing it at any point adds nothing.
struct PantryCaptureSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let kind: PantryCaptureKind
    let existingItems: [PantryItem]
    let onAdded: ([PantryItem]) -> Void

    @State private var speak: SpeakCaptureViewModel?
    @State private var scan: ScanCaptureViewModel?
    @State private var review: ScanReviewViewModel?

    var body: some View {
        NavigationStack {
            Group {
                switch kind {
                case .speak:
                    if let speak { SpeakCaptureView(model: speak, onObservation: showReview) }
                case .scan:
                    if let scan { ScanCaptureView(model: scan, onObservation: showReview) }
                }
            }
            .background(SLColor.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("capture.cancel")
                }
            }
            .navigationDestination(item: $review) { review in
                ScanReviewView(model: review) { added in
                    onAdded(added)
                    dismiss()
                }
            }
        }
        .onAppear {
            switch kind {
            case .speak where speak == nil:
                speak = SpeakCaptureViewModel(speech: environment.speech, service: environment.api)
            case .scan where scan == nil:
                scan = ScanCaptureViewModel(camera: environment.camera, service: environment.api,
                                            fixture: environment.pantryPhotoFixture)
            default:
                break
            }
        }
        .onDisappear {
            speak?.endListening()
            if let scan { Task { await scan.tearDown() } }
        }
    }

    private func showReview(_ observation: PantryObservation) {
        // Typed text is `manual`, dictated text `voice`, photos `photo` (DECISIONS).
        let source: PantrySource? = kind == .speak ? speak?.observationSource : nil
        review = ScanReviewViewModel(observation: observation, existingItems: existingItems, service: environment.api, source: source)
    }
}

extension ScanReviewViewModel: Hashable {
    nonisolated static func == (lhs: ScanReviewViewModel, rhs: ScanReviewViewModel) -> Bool { lhs === rhs }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
