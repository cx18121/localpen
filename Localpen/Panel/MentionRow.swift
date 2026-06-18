import SwiftUI

/// The pre-generation mention chip row (W2): the people/projects a request will ground on,
/// each removable before you submit. Shared by the Ask and the Custom/Respond compose surfaces
/// (one row, not a copy per surface). Hidden when nothing is detected (or every chip dropped).
struct MentionRow: View {
    let mentions: [DetectedMention]
    let onRemove: (String) -> Void

    var body: some View {
        if !mentions.isEmpty {
            HStack(spacing: Spacing.s2) {
                Image(systemName: "book.closed")
                    .font(Typography.microGlyph)
                    .foregroundStyle(Tokens.accent)
                ForEach(mentions, id: \.title) { m in
                    MentionChip(title: m.title, isPerson: m.type == .person) { onRemove(m.title) }
                }
                Spacer()
            }
        }
    }
}

/// A detected brain entity that will ground the request (W2). Accent-tinted (KB-derived, like the
/// Source/calendar chips) with a person/project glyph and a × to drop it from grounding.
struct MentionChip: View {
    let title: String
    let isPerson: Bool
    let onRemove: () -> Void
    var body: some View {
        HStack(spacing: Spacing.s1) {
            Image(systemName: isPerson ? "person.fill" : "folder.fill")
                .font(Typography.microGlyph)
            Text(title)
                .font(Typography.subhead)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 160, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(Typography.microGlyph)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Tokens.accent)
        .padding(.horizontal, Spacing.s3)
        .padding(.vertical, Spacing.s1)
        .background(
            RoundedRectangle(cornerRadius: Spacing.innerRadius, style: .continuous)
                .fill(Tokens.accentTint)
        )
        .help("Grounding this in your “\(title)” note — × to drop it")
    }
}
