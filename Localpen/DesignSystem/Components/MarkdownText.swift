import SwiftUI

/// A lightweight Markdown renderer for the glance surfaces (now.md, briefing excerpts).
/// Handles the block structure the vault actually writes — ATX headings, blockquotes,
/// bullet + task lists, paragraphs — with inline emphasis/code/links via `AttributedString`
/// and accent-tinted `[[wikilinks]]`. It is deliberately NOT a full CommonMark engine (no
/// tables, fenced code, or nested lists): it covers what the vault contains and degrades
/// gracefully — an unrecognized line just renders as a paragraph. Native `Text` composition
/// over the design tokens, so no SPM dependency.
struct MarkdownText: View {
    private let blocks: [Block]

    init(_ markdown: String) {
        self.blocks = Self.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s3) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    // MARK: - Block model

    /// Internal + Equatable so the block-grouping (the logic-bearing part) is unit-testable;
    /// the SwiftUI rendering of each block is the thin part.
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case quote([String])
        case list([Item])
        case paragraph(String)

        struct Item: Equatable { let text: String; let checked: Bool? }   // checked == nil ⇒ plain bullet
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Self.inline(text)
                .font(Self.headingFont(level))
                .foregroundStyle(level >= 3 ? Tokens.textMute : Tokens.text)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .quote(let lines):
            HStack(alignment: .top, spacing: Spacing.s4) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Tokens.accentMute)
                    .frame(width: 2)
                VStack(alignment: .leading, spacing: Spacing.s1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Self.inline(line).font(Typography.body).foregroundStyle(Tokens.textMute)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .list(let items):
            VStack(alignment: .leading, spacing: Spacing.s2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.s3) {
                        marker(item.checked)
                        Self.inline(item.text).font(Typography.body).foregroundStyle(Tokens.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case .paragraph(let text):
            Self.inline(text)
                .font(Typography.body)
                .foregroundStyle(Tokens.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func marker(_ checked: Bool?) -> some View {
        switch checked {
        case nil:    Text("•").font(Typography.body).foregroundStyle(Tokens.textFaint)
        case false?: Image(systemName: "square").font(.system(size: 11)).foregroundStyle(Tokens.textFaint)
        case true?:  Image(systemName: "checkmark.square.fill").font(.system(size: 11)).foregroundStyle(Tokens.accent)
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:  return .system(size: 17, weight: .semibold)
        case 2:  return .system(size: 14, weight: .semibold)
        default: return .system(size: 12, weight: .semibold)
        }
    }

    // MARK: - Parsing (block grouping)

    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var quote: [String] = []
        var list: [Block.Item] = []
        var para: [String] = []

        func flushQuote() { if !quote.isEmpty { blocks.append(.quote(quote)); quote = [] } }
        func flushList()  { if !list.isEmpty { blocks.append(.list(list)); list = [] } }
        func flushPara()  { if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: " "))); para = [] } }
        func flushAll()   { flushQuote(); flushList(); flushPara() }

        for raw in markdown.components(separatedBy: "\n") {
            let indented = raw.first == " " || raw.first == "\t"
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flushAll(); continue }

            // Block markers only count at the line start (no indentation). Nested lists aren't
            // supported, so an indented `- child` degrades to a literal paragraph line rather
            // than being misrepresented as a top-level peer.
            if !indented, let (level, text) = heading(line) {
                flushAll(); blocks.append(.heading(level: level, text: text))
            } else if !indented, line.hasPrefix(">") {
                flushList(); flushPara()
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if !indented, let item = listItem(line) {
                flushQuote(); flushPara()
                list.append(item)
            } else {
                flushQuote(); flushList()
                para.append(line)
            }
        }
        flushAll()
        return blocks
    }

    /// `#`…`######` followed by a space ⇒ (level, text).
    private static func heading(_ line: String) -> (Int, String)? {
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", level < 6 { level += 1; idx = line.index(after: idx) }
        guard level > 0, idx < line.endIndex, line[idx] == " " else { return nil }
        return (level, String(line[line.index(after: idx)...]))
    }

    /// `- `, `* `, `- [ ] `, `- [x] ` ⇒ a list item (checked nil for a plain bullet).
    private static func listItem(_ line: String) -> Block.Item? {
        guard line.hasPrefix("- ") || line.hasPrefix("* ") else { return nil }
        let body = String(line.dropFirst(2))
        if body.hasPrefix("[ ] ") { return .init(text: String(body.dropFirst(4)), checked: false) }
        if body.lowercased().hasPrefix("[x] ") { return .init(text: String(body.dropFirst(4)), checked: true) }
        return .init(text: body, checked: nil)
    }

    // MARK: - Inline rendering

    /// One run of a line: wikilink display text (accent-tinted) or ordinary inline markdown.
    struct Segment: Equatable { let text: String; let wikilink: Bool }

    /// Split a line into wikilink and non-wikilink runs. `[[Target|Alias]]` displays the alias;
    /// `[[Target]]` displays the target. An unterminated `[[` is preserved literally so a
    /// half-typed wikilink in now.md is never silently dropped (graceful degradation).
    static func segments(_ line: String) -> [Segment] {
        var out: [Segment] = []
        var rest = Substring(line)
        while let open = rest.range(of: "[[") {
            let before = String(rest[..<open.lowerBound])
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "]]") else {
                if !before.isEmpty { out.append(.init(text: before, wikilink: false)) }
                out.append(.init(text: "[[" + String(after), wikilink: false))   // unmatched — literal
                return out
            }
            if !before.isEmpty { out.append(.init(text: before, wikilink: false)) }
            let inner = after[..<close.lowerBound]
            let display = inner.split(separator: "|").last.map(String.init) ?? String(inner)
            out.append(.init(text: display, wikilink: true))
            rest = after[close.upperBound...]
        }
        if !rest.isEmpty { out.append(.init(text: String(rest), wikilink: false)) }
        return out
    }

    /// Render one line's inline content: `[[wikilinks]]` accent-tinted, everything else through
    /// `AttributedString` markdown (bold/italic/code/links). Composed with `Text` `+`.
    static func inline(_ line: String) -> Text {
        segments(line).reduce(Text("")) { acc, seg in
            acc + (seg.wikilink ? Text(seg.text).foregroundColor(Tokens.accent) : attributed(seg.text))
        }
    }

    /// A `Text` from inline markdown, falling back to the raw string if it doesn't parse.
    private static func attributed(_ s: String) -> Text {
        guard !s.isEmpty else { return Text("") }
        if let attr = try? AttributedString(
            markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attr)
        }
        return Text(s)
    }
}
