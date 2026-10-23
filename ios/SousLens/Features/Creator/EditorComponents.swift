import SwiftUI

/// Editable list of free-text lines (cues, warnings, notes) as a Form section.
struct StringListSection: View {
    let title: String
    @Binding var items: [String]
    let placeholder: String
    let addLabel: String
    let problems: [DraftProblem]

    var body: some View {
        Section {
            ForEach(items.indices, id: \.self) { index in
                TextField(placeholder, text: $items[index], axis: .vertical)
                    .lineLimit(1...4)
            }
            .onDelete { items.remove(atOffsets: $0) }
            Button {
                items.append("")
            } label: {
                Label(addLabel, systemImage: "plus.circle.fill")
            }
            ForEach(problems, id: \.self) { problem in
                Label(problem.message, systemImage: "exclamationmark.circle.fill")
                    .font(SLFont.footnote)
                    .foregroundStyle(SLColor.danger)
            }
        } header: {
            Text(title)
        }
    }
}

/// Tags as removable chips plus an entry field. Tags are lower-cased, trimmed and unique.
struct TagChipsEditor: View {
    @Binding var tags: [String]
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if !tags.isEmpty {
                FlowLayout(spacing: Spacing.xs) {
                    ForEach(tags, id: \.self) { tag in
                        HStack(spacing: Spacing.xs) {
                            Text(tag).font(SLFont.caption)
                            Button {
                                tags.removeAll { $0 == tag }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .frame(width: 28, height: 28)
                            }
                            .accessibilityLabel("Remove tag \(tag)")
                        }
                        .padding(.leading, Spacing.sm + 2)
                        .foregroundStyle(SLColor.accent)
                        .background(SLColor.accentSoft, in: Capsule())
                    }
                }
            }
            HStack {
                TextField("Add a tag (weeknight, korean…)", text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(commit)
                    .accessibilityIdentifier("draft.tagEntry")
                Button("Add", action: commit)
                    .disabled(normalized(draft) == nil)
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    private func commit() {
        guard let tag = normalized(draft) else { return }
        if !tags.contains(tag) { tags.append(tag) }
        draft = ""
    }

    private func normalized(_ text: String) -> String? {
        let tag = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return tag.isEmpty ? nil : tag
    }
}

/// Minimal wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        return arrange(width: width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placement = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in placement.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}
