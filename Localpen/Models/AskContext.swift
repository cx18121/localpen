import Foundation

/// User-facing representation of context attached to a free-form ask. Each
/// non-nil field renders as a removable chip above the AskInput. Clearing
/// a chip nils the field; submitting takes a final snapshot of what
/// survived.
struct AskContext: Equatable {
    var appLabel: String?    // "Mail · Re: budget Q3" — formatted from probe snapshot
    var selection: String?   // raw text; the chip shows a "N words selected" summary
    var calendar: String?    // formatted upcoming-events line (ADR 0012); chip + `calendar:` prompt line
    var knowledge: String?   // assembled KB context (ADR 0014); pre-prefixed `kb [Title]: …` lines.
                             // Built at stream time (query-dependent), not from the probe snapshot.

    static let empty = AskContext()

    /// True when a non-empty selection chip survived to submit time — the single source for
    /// the `Action.ask(withSelection:)` flag (the prompt branches on whether a selection rode along).
    var hasSelection: Bool { selection?.isEmpty == false }

    /// Builds an AskContext from a ContextProbe snapshot. Formats the
    /// appLabel as "<app> · <window>" when both are present, falls back
    /// gracefully to whichever single field is non-nil. Calendar is already
    /// formatted in the probe (matching how appLabel-not-raw lands here).
    static func from(_ snapshot: ContextProbe.Snapshot) -> AskContext {
        let label: String?
        switch (snapshot.appName, snapshot.windowTitle) {
        case (let app?, let title?):  label = "\(app) · \(title)"
        case (let app?, nil):         label = app
        case (nil, let title?):       label = title
        case (nil, nil):              label = nil
        }
        return AskContext(appLabel: label, selection: snapshot.selection, calendar: snapshot.calendar)
    }
}
