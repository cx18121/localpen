import SwiftUI

/// Renders TextDiff spans inline: equal = normal, insertions = accent, deletions =
/// muted + strikethrough — one AttributedString so it wraps like the normal result.
/// Selection is intentionally disabled: the deletions are real characters under their
/// strikethrough, so a drag-select would copy struck-out text mixed into the result.
/// The clean revised text stays reachable via ⌘C / Accept (which never read this view).
struct DiffText: View {
    let original: String
    let revised: String

    var body: some View {
        Text(attributed)
            .font(Typography.result)
            .lineSpacing(Spacing.s1)   // match the plain result renderer's line spacing
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        for span in TextDiff.spans(original: original, revised: revised) {
            switch span {
            case .equal(let s):
                var a = AttributedString(s); a.foregroundColor = Tokens.text; out += a
            case .insert(let s):
                var a = AttributedString(s); a.foregroundColor = Tokens.accent; out += a
            case .delete(let s):
                var a = AttributedString(s)
                a.foregroundColor = Tokens.textMute
                a.strikethroughStyle = .single
                out += a
            }
        }
        return out
    }
}
