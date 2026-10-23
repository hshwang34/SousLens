import SwiftUI

/// Explicit confirmation before a publish (CLAUDE.md: no silent state changes). Shows progress
/// while publishing and the server's reason if it refused.
struct PublishConfirmationSheet: View {
    @Bindable var model: DraftEditorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Capsule()
                .fill(SLColor.separator)
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            Text(model.publishConfirmationTitle)
                .font(SLFont.title2)
                .foregroundStyle(SLColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(DraftEditorViewModel.publishConfirmationMessage)
                .font(SLFont.body)
                .foregroundStyle(SLColor.textSecondary)
            if case .failed(let message) = model.publishPhase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(SLFont.footnote)
                    .foregroundStyle(SLColor.danger)
                    .accessibilityLabel("Publish failed: \(message)")
            }
            Spacer(minLength: 0)
            switch model.publishPhase {
            case .publishing:
                ProgressView("Publishing…")
                    .frame(maxWidth: .infinity)
            case .failed:
                Button("Back to editor") { model.cancelPublish() }
                    .buttonStyle(SLButtonStyle(prominent: true))
            default:
                Button {
                    Task { await model.confirmPublish() }
                } label: {
                    Label("Publish", systemImage: "paperplane.fill")
                }
                .buttonStyle(SLButtonStyle(prominent: true))
                .accessibilityIdentifier("publish.confirm")
                Button("Not yet") { model.cancelPublish() }
                    .buttonStyle(SLButtonStyle(prominent: false))
                    .accessibilityIdentifier("publish.cancel")
            }
        }
        .padding(Spacing.screen)
        .background(SLColor.background)
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(model.publishPhase == .publishing)
    }
}

/// Success screen: version, share link, share sheet.
struct PublishedView: View {
    /// Honest about the universal-link stub (brief 003): souslens.app serves no pages yet.
    static let linkCaveat = "Link pages aren’t live yet; the link opens the app if SousLens is installed."

    let result: PublishResult
    let title: String
    let done: () -> Void

    var body: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(SLColor.success)
                .accessibilityHidden(true)
            VStack(spacing: Spacing.sm) {
                Text("Published version \(result.versionNumber)")
                    .font(SLFont.title)
                    .foregroundStyle(SLColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("published.title")
                Text(title.isEmpty ? "Your recipe is live in Explore." : "“\(title)” is live in Explore.")
                    .font(SLFont.body)
                    .foregroundStyle(SLColor.textSecondary)
                Text("This version can’t change. Editing creates version \(result.versionNumber + 1).")
                    .font(SLFont.footnote)
                    .foregroundStyle(SLColor.textSecondary)
            }
            .multilineTextAlignment(.center)
            VStack(spacing: Spacing.sm) {
                // Built from the recipe id, never from the server's `share_url`.
                Text(result.shareURL.absoluteString)
                    .font(SLFont.footnote.monospaced())
                    .foregroundStyle(SLColor.textSecondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel("Share link \(result.shareURL.absoluteString)")
                    .accessibilityIdentifier("published.link")
                Text(PublishedView.linkCaveat)
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                ShareLink(item: result.shareURL, subject: Text(title), message: Text("\(title) on SousLens")) {
                    Label("Share link", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(SLButtonStyle(prominent: true))
                .accessibilityIdentifier("published.share")
                Button("Done", action: done)
                    .buttonStyle(SLButtonStyle(prominent: false))
                    .accessibilityIdentifier("published.done")
            }
            Spacer()
        }
        .padding(Spacing.screen)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SLColor.background)
        .navigationTitle("Published")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
    }
}

/// The draft rendered through the real detail layout, under an honest banner.
struct DraftPreviewView: View {
    let detail: RecipeDetail
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.section) {
                    banner
                    RecipeHeaderView(
                        title: detail.title,
                        creatorName: detail.creator.displayName,
                        versionNumber: detail.versionNumber,
                        summary: detail.summary,
                        prepMinutes: detail.prepMinutes,
                        cookMinutes: detail.cookMinutes,
                        servings: detail.servings,
                        coverImageURL: detail.coverImageURL
                    )
                    RecipeDetailContent(detail: detail)
                }
                .padding(.horizontal, Spacing.screen)
                .padding(.bottom, Spacing.xxl)
            }
            .background(SLColor.background)
            .navigationTitle("Draft preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("preview.done")
                }
            }
        }
    }

    private var banner: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "eye")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Draft preview")
                    .font(SLFont.headline)
                Text("Not published. This is how version \(detail.versionNumber) will look once you publish it.")
                    .font(SLFont.footnote)
            }
        }
        .foregroundStyle(SLColor.warning)
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SLColor.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("preview.banner")
    }
}
