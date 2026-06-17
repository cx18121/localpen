import SwiftUI

/// A horizontal row of the KB pages a brain-backed answer drew on (ADR 0014). Accent-
/// tinted (KB-derived, like the calendar chip) and tappable to open the note in Obsidian.
/// Shared by the conversation surface (ask threads) and one-shot results (W2 grounded
/// respond/custom transforms).
struct SourceChips: View {
    let sources: [ContextBundle.Provenance]
    let onOpen: (ContextBundle.Provenance) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            Text("Sources")
                .font(Typography.footerHint)
                .foregroundStyle(Tokens.textFaint)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.s2) {
                    ForEach(sources, id: \.path) { src in
                        Button { onOpen(src) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "book.closed")
                                    .font(Typography.microGlyph)
                                Text(src.title)
                                    .font(Typography.subhead)
                                    .lineLimit(1)
                            }
                            .foregroundStyle(Tokens.accent)
                            .padding(.horizontal, Spacing.s3)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: Spacing.innerRadius, style: .continuous)
                                    .fill(Tokens.accentTint)
                            )
                        }
                        .buttonStyle(.plain)
                        .help("Open “\(src.title)” in Obsidian")
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.s7)
        .padding(.vertical, Spacing.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
