import SwiftUI
import UIKit

/// Editable list of free-text lines (cues, warnings, notes) as a Form section. Rows bind by the
/// line's stable id, never by index.
struct StringListSection: View {
    let title: String
    @Binding var items: [EditableLine]
    let placeholder: String
    let addLabel: String
    let problems: [DraftProblem]

    var body: some View {
        Section {
            ForEach($items) { $line in
                TextField(placeholder, text: $line.text, axis: .vertical)
                    .lineLimit(1...4)
                    .characterLimit($line.text, DraftLimits.line)
            }
            .onDelete { items.remove(atOffsets: $0) }
            Button {
                items.append(EditableLine(""))
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
                                    .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
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
                    .characterLimit($draft, DraftLimits.tag)
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
        DraftText.tags([text]).first
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

/// Numeric entry that writes through on every keystroke (not only on blur), so a value typed just
/// before Publish or Close is part of the form. Empty text means nil. Keeps its own text so a
/// half-typed decimal ("1.") is not reformatted under the cursor.
struct NumericTextField: View {
    let placeholder: String
    @Binding var value: Double?
    var allowsDecimal = true

    @State private var text = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(allowsDecimal ? .decimalPad : .numberPad)
            .onAppear { text = Self.format(value) }
            .onChange(of: text) { _, newText in
                let parsed = Self.parse(newText, allowsDecimal: allowsDecimal)
                if parsed != value { value = parsed }
            }
            .onChange(of: value) { _, newValue in
                // External change (e.g. form reset): reflect it unless the text already means it.
                if Self.parse(text, allowsDecimal: allowsDecimal) != newValue { text = Self.format(newValue) }
            }
    }

    static func parse(_ text: String, allowsDecimal: Bool) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty, let number = Double(cleaned), number.isFinite, number >= 0 else { return nil }
        return allowsDecimal ? number : number.rounded(.down)
    }

    static func format(_ value: Double?) -> String {
        guard let value else { return "" }
        return value == value.rounded() ? String(Int(value)) : String(value)
    }
}

extension Binding where Value == Int? {
    /// `Int?` ⇄ `Double?` for `NumericTextField` in whole-number mode.
    var asDouble: Binding<Double?> {
        Binding<Double?>(
            get: { wrappedValue.map(Double.init) },
            set: { wrappedValue = $0.map { Int($0) } }
        )
    }
}

@MainActor
enum KeyboardFocus {
    /// Commits whatever field is being edited before an action that reads the form.
    static func endEditing() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

extension View {
    /// Caps a text field at the backend's limit as the user types (paste included), so the limit is
    /// visible instead of surfacing later as a failed save.
    func characterLimit(_ text: Binding<String>, _ max: Int) -> some View {
        onChange(of: text.wrappedValue) { _, newValue in
            if newValue.count > max { text.wrappedValue = String(newValue.prefix(max)) }
        }
    }
}
