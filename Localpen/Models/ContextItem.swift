import Foundation

/// A capture-time, query-independent context input (ADR 0019). The ambient
/// "what's around you right now" family — the active app, your calendar, the
/// file you have open, what's on screen, your mail. Each is read at capture,
/// frozen for the session, shown as a removable chip, and emitted as one line
/// in the `<context>` block.
///
/// NOT a context source: the **selection** (the operand a transform acts on) and
/// the **knowledge** brain (query-time, relevance-ranked) — both stay first-class
/// fields on `AskContext`.
enum ContextKind: String, Codable, Sendable, CaseIterable {
    case app, selection, files, screen, knowledge, calendar, mail

    /// Fixed order of context lines inside the `<context>` block. `selection` and
    /// `knowledge` are ranked here too (though they aren't `ContextItem`s) so the
    /// one prompt loop can interleave everything deterministically. The existing
    /// app → selection → knowledge → calendar order is preserved; new sources slot
    /// in by rank without disturbing it.
    var promptRank: Int {
        switch self {
        case .app: 0
        case .selection: 1
        case .files: 2
        case .screen: 3
        case .knowledge: 4
        case .calendar: 5
        case .mail: 6
        }
    }
}

/// One captured ambient input. `label` is the raw value (used by the `AskContext`
/// facade accessors); `chipText` is what the removable chip shows; `promptLine` is
/// the single line emitted into the `<context>` block.
struct ContextItem: Codable, Equatable, Sendable {
    let kind: ContextKind
    let label: String
    let chipText: String
    let promptLine: String

    static func app(_ label: String) -> ContextItem {
        .init(kind: .app, label: label, chipText: label, promptLine: "app: \(label)")
    }

    static func calendar(_ line: String) -> ContextItem {
        .init(kind: .calendar, label: line, chipText: line, promptLine: "calendar: \(line)")
    }

    /// The file you have open (ADR 0019, source #1). `name` is the filename; `body`
    /// is the (capped) extracted text. Empty body ⇒ just the filename rides along.
    static func file(name: String, body: String) -> ContextItem {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(kind: .files, label: name, chipText: "file [\(name)]",
                     promptLine: trimmed.isEmpty ? "file [\(name)]" : "file [\(name)]: \(trimmed)")
    }
}

/// A capture-time context source (ADR 0019). Implementations read one ambient
/// input behind an authorization gate; the probe runs the enabled ones at capture.
/// `capture()` is async because most sources (screen, file reads) are inherently
/// async — a cached source just returns fast.
protocol ContextSource: Sendable {
    var kind: ContextKind { get }
    var isEnabled: @Sendable () -> Bool { get }
    func capture() async -> ContextItem?
}
