import SwiftUI

/// Drives the `[[`/`@` mention dropdown (W2). Owned by `GrowingField`; the NSTextView updates
/// it on every edit (active token + filtered titles), SwiftUI renders the list, and arrow/
/// Return/Esc are routed back through the text view's key handling. A custom list rather than
/// AppKit's `complete()` because the notch panel is a non-key window where the native
/// completion popup never renders.
@MainActor
final class MentionCompletionModel: ObservableObject {
    @Published private(set) var suggestions: [String] = []
    @Published var selected: Int = 0
    /// The token being completed (its range is what acceptance replaces). Set with `suggestions`.
    private(set) var token: MentionAutocomplete.Token?

    var isActive: Bool { !suggestions.isEmpty }
    var current: String? { isActive && suggestions.indices.contains(selected) ? suggestions[selected] : nil }

    /// Recompute from the live text + caret. Clears when no active token or no matches.
    func update(text: NSString, caret: Int, titles: [String]) {
        guard let t = MentionAutocomplete.activeToken(in: text, caret: caret) else { clear(); return }
        let s = MentionAutocomplete.filter(titles, query: t.query, limit: 8)
        guard !s.isEmpty else { clear(); return }
        token = t
        suggestions = s
        if selected >= s.count { selected = 0 }
    }

    func moveUp()   { if isActive { selected = (selected - 1 + suggestions.count) % suggestions.count } }
    func moveDown() { if isActive { selected = (selected + 1) % suggestions.count } }
    func clear()    { token = nil; suggestions = []; selected = 0 }
}

/// The dropdown list of brain titles under the ask field. Tappable; the highlighted row tracks
/// `model.selected` (arrow keys).
struct MentionSuggestionList: View {
    @ObservedObject var model: MentionCompletionModel
    /// Insert the title at `index` (mouse click). Keyboard Return routes through the text view.
    let onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.suggestions.enumerated()), id: \.offset) { idx, title in
                HStack(spacing: Spacing.s2) {
                    Image(systemName: "book.closed")
                        .font(Typography.microGlyph)
                        .foregroundStyle(Tokens.accent)
                    Text(title)
                        .font(Typography.subhead)
                        .foregroundStyle(Tokens.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Spacing.s3)
                .padding(.vertical, Spacing.s2)
                .background(
                    RoundedRectangle(cornerRadius: Spacing.innerRadius, style: .continuous)
                        .fill(idx == model.selected ? Tokens.rowHighlight : .clear)
                )
                .contentShape(Rectangle())
                .onTapGesture { onPick(idx) }
            }
        }
        .padding(Spacing.s1)
        .background(
            RoundedRectangle(cornerRadius: Spacing.innerRadius, style: .continuous)
                .fill(Tokens.chromeTint)
                .overlay(
                    RoundedRectangle(cornerRadius: Spacing.innerRadius, style: .continuous)
                        .stroke(Tokens.panelBorder, lineWidth: 0.75)
                )
        )
    }
}
