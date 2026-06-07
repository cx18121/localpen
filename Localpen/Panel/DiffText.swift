import SwiftUI

/// Renders TextDiff spans inline: equal = normal, insertions = accent, deletions =
/// muted + strikethrough. One AttributedString so it wraps/selects like normal text.
struct DiffText: View {
    let original: String
    let revised: String

    var body: some View {
        Text(attributed)
            .font(Typography.result)
            .textSelection(.enabled)
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
