import SwiftUI

/// Profile (PRD §6): my recipes, my drafts, account, device state, server, sign out.
struct ProfileView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: MyRecipesViewModel?
    @State private var editor: DraftEditorViewModel?
    @State private var isOpeningEditor = false
    @State private var openError: String?
    @State private var recipeToUnpublish: MyRecipe?
    @State private var draftToDelete: DraftSummary?

    var body: some View {
        NavigationStack {
            List {
                myRecipesSection
                draftsSection
                accountSection
                deviceSection
                Section {
                    Button(role: .destructive) {
                        environment.auth.signOut()
                    } label: {
                        Text("Sign out")
                            .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(SLColor.background)
            .navigationTitle("Profile")
            .navigationDestination(for: RecipeRoute.self) { route in
                switch route {
                case .recipe(let id, let card):
                    RecipeDetailView(recipeId: id, card: card)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        ServerSettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                            .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                    }
                    .accessibilityLabel("Server settings")
                }
            }
            .refreshable { await model?.refresh() }
            .confirmationDialog("Unpublish “\(recipeToUnpublish?.card.title ?? "")”?", isPresented: Binding(get: { recipeToUnpublish != nil }, set: { if !$0 { recipeToUnpublish = nil } }), titleVisibility: .visible) {
                Button("Unpublish", role: .destructive) {
                    if let recipe = recipeToUnpublish { Task { await model?.unpublish(recipeId: recipe.id) } }
                }
                Button("Keep published", role: .cancel) {}
            } message: {
                Text("It disappears from Explore and search. Existing links and pinned cooking sessions keep this version.")
            }
            .confirmationDialog("Delete “\(draftToDelete?.displayTitle ?? "")”?", isPresented: Binding(get: { draftToDelete != nil }, set: { if !$0 { draftToDelete = nil } }), titleVisibility: .visible) {
                Button("Delete draft", role: .destructive) {
                    if let draft = draftToDelete { Task { await model?.deleteDraft(id: draft.id) } }
                }
                Button("Keep draft", role: .cancel) {}
            } message: {
                Text("Only the draft is deleted. Anything already published stays published.")
            }
        }
        .task {
            if model == nil {
                let created = MyRecipesViewModel(service: environment.api)
                model = created
                await created.load()
            } else {
                await model?.refresh()
            }
        }
        .fullScreenCover(item: $editor, onDismiss: { Task { await model?.refresh() } }) { editor in
            DraftEditorView(model: editor)
        }
    }

    // MARK: - My recipes

    @ViewBuilder
    private var myRecipesSection: some View {
        Section {
            Button {
                Task { await createRecipe() }
            } label: {
                HStack {
                    Label("Create recipe", systemImage: "plus.circle.fill")
                    Spacer()
                    if isOpeningEditor { ProgressView() }
                }
                .frame(minHeight: Metrics.minTapTarget)
            }
            .disabled(isOpeningEditor)
            .accessibilityIdentifier("profile.createRecipe")
            if let openError {
                Text(openError)
                    .font(SLFont.footnote)
                    .foregroundStyle(SLColor.danger)
            }
            if let error = model?.actionError {
                Text(error)
                    .font(SLFont.footnote)
                    .foregroundStyle(SLColor.danger)
            }
            switch model?.phase {
            case .none, .idle, .loading:
                HStack(spacing: Spacing.sm) {
                    ProgressView()
                    Text("Loading your recipes…")
                        .font(SLFont.footnote)
                        .foregroundStyle(SLColor.textSecondary)
                }
            case .error(let message, _):
                Label(message, systemImage: "wifi.exclamationmark")
                    .font(SLFont.footnote)
                    .foregroundStyle(SLColor.warning)
            case .loaded:
                if let model, model.recipes.isEmpty {
                    Text("Nothing published yet. Create a recipe, add ingredients and steps, then publish it.")
                        .font(SLFont.footnote)
                        .foregroundStyle(SLColor.textSecondary)
                } else if let model {
                    ForEach(model.recipes) { recipe in
                        NavigationLink(value: RecipeRoute.card(recipe.card)) {
                            MyRecipeRow(recipe: recipe, isBusy: model.busyRecipeIds.contains(recipe.id))
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if recipe.visibility == .public {
                                Button("Unpublish") { recipeToUnpublish = recipe }
                                    .tint(SLColor.warning)
                            }
                        }
                        .contextMenu {
                            if recipe.visibility == .public {
                                Button("Unpublish…", systemImage: "eye.slash") { recipeToUnpublish = recipe }
                            }
                        }
                    }
                }
            }
        } header: {
            Text("My recipes")
        } footer: {
            if let model, !model.recipes.isEmpty {
                Text("Swipe a recipe to unpublish it. Published versions are never changed in place; Edit on the recipe creates a new draft.")
            }
        }
    }

    // MARK: - Drafts

    @ViewBuilder
    private var draftsSection: some View {
        if let model, model.phase == .loaded {
            Section {
                if model.drafts.isEmpty {
                    Text("No drafts in progress.")
                        .font(SLFont.footnote)
                        .foregroundStyle(SLColor.textSecondary)
                } else {
                    ForEach(model.drafts) { draft in
                        Button {
                            Task { await continueDraft(draft) }
                        } label: {
                            DraftRow(draft: draft, isBusy: model.busyDraftIds.contains(draft.id) || isOpeningEditor)
                        }
                        .disabled(isOpeningEditor)
                        .accessibilityIdentifier("profile.draft.\(draft.id.uuidString.lowercased())")
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", role: .destructive) { draftToDelete = draft }
                        }
                        .contextMenu {
                            Button("Continue editing", systemImage: "pencil") { Task { await continueDraft(draft) } }
                            Button("Delete draft…", systemImage: "trash", role: .destructive) { draftToDelete = draft }
                        }
                    }
                }
            } header: {
                Text("Drafts")
            } footer: {
                if !model.drafts.isEmpty { Text("Tap to continue. Swipe to delete.") }
            }
        }
    }

    // MARK: - Account / device (Slice 0)

    @ViewBuilder
    private var accountSection: some View {
        if let user = environment.auth.user {
            Section {
                HStack(spacing: Spacing.md) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(SLColor.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(user.displayName)
                            .font(SLFont.title3)
                            .foregroundStyle(SLColor.textPrimary)
                        Text("Member since \(user.createdAt, format: .dateTime.month(.wide).year())")
                            .font(SLFont.footnote)
                            .foregroundStyle(SLColor.textSecondary)
                    }
                }
                .padding(.vertical, Spacing.xs)
                .accessibilityElement(children: .combine)
                LabeledContent("Units", value: user.preferenceUnits.displayName)
            } header: {
                Text("Account")
            }
        }
    }

    private var deviceSection: some View {
        Section {
            LabeledContent("Server") {
                Text(environment.serverSettings.effectiveBaseURLString.isEmpty ? "Not set" : environment.serverSettings.effectiveBaseURLString)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            LabeledContent("Camera", value: environment.camera.isAvailable ? "Available (\(environment.camera.kind.displayName))" : "Unavailable")
            LabeledContent("Microphone", value: environment.speech.isAvailable ? "Available (\(environment.speech.kind.displayName))" : "Unavailable")
            LabeledContent("Speech output", value: environment.audio.isAvailable ? "Available" : "Unavailable")
        } header: {
            Text("Device")
        } footer: {
            Text("Capture inputs are checked on launch; the simulator reports camera and microphone as unavailable.")
        }
    }

    // MARK: - Actions

    private var creator: Creator? {
        environment.auth.user.map { Creator(id: $0.id, displayName: $0.displayName) }
    }

    private func createRecipe() async {
        guard let creator else { return }
        isOpeningEditor = true
        openError = nil
        defer { isOpeningEditor = false }
        do {
            editor = try await DraftEditorViewModel.createNew(service: environment.api, creator: creator)
        } catch {
            openError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func continueDraft(_ draft: DraftSummary) async {
        guard let creator else { return }
        isOpeningEditor = true
        openError = nil
        defer { isOpeningEditor = false }
        do {
            editor = try await DraftEditorViewModel.open(draftId: draft.id, service: environment.api, creator: creator)
        } catch {
            openError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }
}

private struct MyRecipeRow: View {
    let recipe: MyRecipe
    let isBusy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(recipe.card.title)
                .font(SLFont.headline)
                .foregroundStyle(SLColor.textPrimary)
            HStack(spacing: Spacing.xs) {
                MetadataPill(
                    text: recipe.visibility.label,
                    systemImage: recipe.visibility == .public ? "globe" : "lock",
                    style: recipe.visibility == .public ? .accent : .neutral,
                    accessibilityLabel: "Visibility: \(recipe.visibility.label)"
                )
                MetadataPill(text: "v\(recipe.card.versionNumber)", accessibilityLabel: "Version \(recipe.card.versionNumber)")
                if recipe.hasOpenDraft {
                    MetadataPill(text: "Draft in progress", systemImage: "pencil")
                }
                if isBusy { ProgressView().controlSize(.small) }
            }
        }
        .padding(.vertical, Spacing.xxs)
    }
}

private struct DraftRow: View {
    let draft: DraftSummary
    let isBusy: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(draft.displayTitle)
                    .font(SLFont.headline)
                    .foregroundStyle(SLColor.textPrimary)
                HStack(spacing: Spacing.xs) {
                    Text("\(draft.ingredientCount) ingredient\(draft.ingredientCount == 1 ? "" : "s") · \(draft.stepCount) step\(draft.stepCount == 1 ? "" : "s")")
                    Text("·")
                    Text("Edited \(draft.updatedAt, style: .relative) ago")
                }
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
                if draft.recipeId != nil {
                    MetadataPill(text: "New version of a published recipe", systemImage: "arrow.triangle.branch")
                }
            }
            Spacer()
            if isBusy {
                ProgressView()
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SLColor.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Continues editing this draft")
    }
}

#Preview {
    ProfileView().environment(AppEnvironment.preview())
}
