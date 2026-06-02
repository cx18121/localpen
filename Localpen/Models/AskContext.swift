import Foundation

/// User-facing representation of context attached to a free-form ask. Each
/// non-nil field renders as a removable chip above the AskInput. Clearing
/// a chip nils the field; submitting takes a final snapshot of what
/// survived.
struct AskContext: Equatable {
    /// The ambient capture-time context sources (ADR 0019): app, calendar, files,
    /// screen, mail. Each renders as a removable chip and emits one `<context>` line.
    var sources: [ContextItem] = []
    var selection: String?   // raw text; the chip shows a "N words selected" summary. The OPERAND, not a source.
    var knowledge: String?   // assembled KB context (ADR 0014); pre-prefixed `kb [Title]: …` lines.
                             // Built at stream time (query-dependent), not from the probe snapshot. Brain seam, not a source.

    init(sources: [ContextItem] = [], selection: String? = nil, knowledge: String? = nil) {
        self.sources = sources
        self.selection = selection
        self.knowledge = knowledge
    }

    /// Back-compat facade init (ADR 0019): the app/window and calendar inputs are now
    /// `ContextItem`s in `sources`, but call sites and tests still construct them by name.
    init(appLabel: String? = nil, selection: String? = nil, calendar: String? = nil, knowledge: String? = nil) {
        var s: [ContextItem] = []
        if let appLabel { s.append(.app(appLabel)) }
        if let calendar { s.append(.calendar(calendar)) }
        self.init(sources: s, selection: selection, knowledge: knowledge)
    }

    static let empty = AskContext()

    /// True when a non-empty selection chip survived to submit time — the single source for
    /// the `Action.ask(withSelection:)` flag (the prompt branches on whether a selection rode along).
    var hasSelection: Bool { selection?.isEmpty == false }

    // MARK: Named accessors — thin facade over `sources` so existing call sites + tests are unchanged.

    var appLabel: String? {
        get { sources.first { $0.kind == .app }?.label }
        set { setSource(.app, newValue.map(ContextItem.app)) }
    }
    var calendar: String? {
        get { sources.first { $0.kind == .calendar }?.label }
        set { setSource(.calendar, newValue.map(ContextItem.calendar)) }
    }

    /// Upsert (or, when nil, remove) the single source of a given kind, preserving the rest.
    mutating func setSource(_ kind: ContextKind, _ item: ContextItem?) {
        sources.removeAll { $0.kind == kind }
        if let item { sources.append(item) }
    }
    mutating func removeSource(_ kind: ContextKind) { sources.removeAll { $0.kind == kind } }

    /// Builds an AskContext from a ContextProbe snapshot. Formats the
    /// appLabel as "<app> · <window>" when both are present, falls back
    /// gracefully to whichever single field is non-nil. Calendar and file are already
    /// formatted in the probe (matching how appLabel-not-raw lands here).
    static func from(_ snapshot: ContextProbe.Snapshot) -> AskContext {
        let label: String?
        switch (snapshot.appName, snapshot.windowTitle) {
        case (let app?, let title?):  label = "\(app) · \(title)"
        case (let app?, nil):         label = app
        case (nil, let title?):       label = title
        case (nil, nil):              label = nil
        }
        var ctx = AskContext(appLabel: label, selection: snapshot.selection, calendar: snapshot.calendar)
        for item in snapshot.sourceItems { ctx.setSource(item.kind, item) }
        return ctx
    }
}
