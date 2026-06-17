import Foundation

/// Splits a frontmatter-stripped markdown body into heading-respecting chunks for
/// chunk-level embedding (W2 grounding). Pure + total so it's unit-testable with no I/O.
/// Chunks never span a heading; an over-long section is split on paragraph/whitespace;
/// a trailing runt merges back so grounding never surfaces a 3-word fragment.
struct Chunk: Sendable, Equatable {
    let heading: String?
    let text: String
}

enum Chunker {
    static func chunk(_ body: String, targetChars: Int = 512, maxChars: Int = 1000, minChars: Int = 120) -> [Chunk] {
        let lines = body.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")

        // 1. Group lines into (heading, [paragraph]) sections. A heading line opens a section.
        var sections: [(heading: String?, paragraphs: [String])] = []
        var curHeading: String? = nil
        var curParas: [String] = []
        var buf: [String] = []
        func flushPara() {
            let p = buf.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !p.isEmpty { curParas.append(p) }
            buf = []
        }
        func flushSection() {
            flushPara()
            if !curParas.isEmpty { sections.append((curHeading, curParas)) }
            curParas = []
        }
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.first == "#" {
                flushSection()
                curHeading = t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            } else if t.isEmpty {
                flushPara()
            } else {
                buf.append(t)
            }
        }
        flushSection()

        // 2. Within each section, pack paragraphs to ~target, hard-split > maxChars, merge runts.
        var chunks: [Chunk] = []
        for (heading, paras) in sections {
            var packed: [String] = []
            var cur = ""
            func push() { if !cur.isEmpty { packed.append(cur); cur = "" } }
            for para in paras {
                for piece in Self.hardSplit(para, maxChars: maxChars) {
                    if cur.isEmpty { cur = piece }
                    else if cur.count + 1 + piece.count <= targetChars { cur += " " + piece }
                    else { push(); cur = piece }
                }
            }
            push()
            // Merge a trailing runt into its predecessor (same heading only).
            if packed.count >= 2, let last = packed.last, last.count < minChars {
                packed[packed.count - 2] += " " + last
                packed.removeLast()
            }
            chunks.append(contentsOf: packed.map { Chunk(heading: heading, text: $0) })
        }
        return chunks
    }

    /// Split a single paragraph that exceeds `maxChars` on word boundaries; short paragraphs
    /// pass through unchanged.
    private static func hardSplit(_ para: String, maxChars: Int) -> [String] {
        guard para.count > maxChars else { return [para] }
        var out: [String] = []
        var cur = ""
        for word in para.split(separator: " ") {
            if cur.isEmpty { cur = String(word) }
            else if cur.count + 1 + word.count <= maxChars { cur += " " + word }
            else { out.append(cur); cur = String(word) }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}
