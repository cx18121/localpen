import SwiftUI

/// A small-caps section header — the canonical "RECENT", "VOICE", "FACTS", "REVISE"
/// label that introduces a group of rows. Always 10pt semibold, tracking 0.9, faint
/// text, padded to align with rows below.
///
/// `trailing` is for the optional inline metadata you sometimes want beside the
/// title — e.g. "editable", a count, "learned from 142". Rendered at subhead size in
/// the same faint hue so it never competes with the header itself.
///
/// **Not for ActionMenuView's group headers** — those are positioned by the sliding
/// focus-highlight math and use their own fixed-height variant. Use this everywhere
/// else.
struct SectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: Spacing.s3) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(Tokens.textFaint)
            if let trailing {
                Text(trailing)
                    .font(Typography.subhead)
                    .foregroundStyle(Tokens.textFaint)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.s7)
        .padding(.top, Spacing.s5)
        .padding(.bottom, Spacing.s2)
    }
}
