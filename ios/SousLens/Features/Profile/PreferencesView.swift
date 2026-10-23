import SwiftUI

/// Profile → "Allergies & foods to avoid" (SUB-02).
struct PreferencesView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: PreferencesViewModel?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(SLColor.background)
        .navigationTitle("Allergies & foods to avoid")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard model == nil else { return }
            let created = PreferencesViewModel(service: environment.api)
            model = created
            await created.load()
        }
    }

    @ViewBuilder
    private func content(_ model: PreferencesViewModel) -> some View {
        switch model.phase {
        case .loading:
            ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            EmptyStateView(systemImage: "wifi.exclamationmark", title: "Couldn’t load your preferences", message: message,
                           primary: EmptyStateView.Action("Try again") { Task { await model.load() } })
        case .loaded:
            List {
                ForEach(PreferencesViewModel.Kind.allCases) { kind in
                    PreferenceSection(model: model, kind: kind)
                }
                if let error = model.saveError {
                    Section {
                        Text(error).font(SLFont.footnote).foregroundStyle(SLColor.danger)
                    }
                }
                Section {
                    Label {
                        Text(PreferencesViewModel.disclaimer).font(SLFont.footnote)
                    } icon: {
                        Image(systemName: "exclamationmark.shield")
                    }
                    .foregroundStyle(SLColor.textSecondary)
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
}

private struct PreferenceSection: View {
    let model: PreferencesViewModel
    let kind: PreferencesViewModel.Kind

    var body: some View {
        Section {
            let entries = model.entries(kind)
            if entries.isEmpty {
                Text("None yet")
                    .font(SLFont.footnote)
                    .foregroundStyle(SLColor.textSecondary)
            } else {
                ChipFlow(entries: entries) { index in
                    Task { await model.remove(kind, at: index) }
                }
                .disabled(model.isSaving)
            }
            HStack(spacing: Spacing.sm) {
                TextField(kind.placeholder, text: Binding(get: { model.draft(kind) }, set: { model.setDraft(kind, $0) }))
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit { Task { await model.add(kind) } }
                    .accessibilityLabel("Add to \(kind.title.lowercased())")
                    .accessibilityIdentifier("preferences.\(kind.rawValue).field")
                Button("Add") { Task { await model.add(kind) } }
                    .disabled(!model.canAdd(kind))
                    .frame(minHeight: Metrics.minTapTarget)
                    .accessibilityIdentifier("preferences.\(kind.rawValue).add")
            }
        } header: {
            Text(kind.title)
        } footer: {
            Text(kind.explanation)
        }
    }
}

/// Removable chips, wrapping onto new lines.
private struct ChipFlow: View {
    let entries: [String]
    let onRemove: (Int) -> Void

    var body: some View {
        FlowLayout(spacing: Spacing.sm) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                Button {
                    onRemove(index)
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Text(entry).font(SLFont.callout)
                        Image(systemName: "xmark.circle.fill").font(.caption)
                    }
                    .padding(.horizontal, Spacing.md)
                    .frame(minHeight: Metrics.minTapTarget)
                    .foregroundStyle(SLColor.accent)
                    .background(SLColor.accentSoft, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(entry). Remove")
            }
        }
        .padding(.vertical, Spacing.xs)
    }
}
