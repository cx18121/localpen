import Foundation

/// A candidate write the curation layer (ADR 0015) might make to the vault. The cases
/// are exactly the two classes ADR 0015 enumerates — and `WriteClassifier` maps each to
/// a `WriteDisposition`. This is the *competence boundary*: what a local ≤14B model may
/// apply unsupervised (additive/structured, git as the backstop) vs. what it may only
/// *propose* for one-click apply (high-judgment, where an unsupervised small model would
/// silently degrade a curated page).
enum CurationWrite: Equatable, Sendable {
    // MARK: Additive / structured — auto-apply, no gate, git-backed (~90%)
    /// A clipping/quick capture → `raw/inbox/<ts>.md`.
    case captureToInbox(text: String)
    /// A Timeline entry appended to an *existing* `people/` page (never creates one).
    case appendTimeline(person: String, entry: String)
    /// Append a dated entry to a project page's tool-owned `## Activity` log (project-activity
    /// freshness). Additive — auto-applied.
    case appendActivity(projectTitle: String, entry: String)
    /// Distill a person page's own raw facts into its `## Compiled Truth` (synthesized summary)
    /// + a deduped/merged `## Connections` (people-synthesis pass). Auto-applied — it only
    /// restates/condenses facts already on the page, and git is the backstop.
    case synthesizePerson(name: String, compiledTruth: String, connections: [String])
    /// A new `sources/` page synthesized from template.
    case createSource(title: String, body: String)
    /// Nominating a dangling `[[link]]` target so the graph self-wires.
    case nominateLink(fromPage: String, toTitle: String)
    /// Refreshing the always-loaded `now.md` working-state entry point.
    case updateNow(text: String)

    // MARK: High-judgment — queued one-click suggestion, never silent (~10%)
    /// Rewriting an existing *curated* page (synthesis/restructure).
    case rewriteCuratedPage(title: String, body: String)
    /// Promoting a cluster of sources into a new `topics/` synthesis page.
    case promoteTopic(title: String)
    /// Reconciling a contradiction across pages (the vault forbids silent blending).
    case resolveContradiction(page: String, detail: String)
    /// Creating a *new* `people/` page (identity resolution is error-prone).
    case createPerson(name: String)
    /// Merging or splitting two identities into one canonical person.
    case mergeIdentities(into: String, from: String)
}

extension CurationWrite {
    /// Reconstruct a write from its kind + the flat field bag that both the synthesis JSON
    /// (`CurationSynthesis.ProposedWrite`) and persisted suggestions (`SuggestionPayload`)
    /// carry. The single source of truth for "flat fields → enum"; returns nil when a field
    /// the kind requires is absent, so a garbled/old entry drops rather than reaching the vault.
    static func make(kind: String,
                     text: String? = nil, person: String? = nil, entry: String? = nil,
                     title: String? = nil, body: String? = nil,
                     fromPage: String? = nil, toTitle: String? = nil, name: String? = nil,
                     page: String? = nil, detail: String? = nil,
                     into: String? = nil, from: String? = nil) -> CurationWrite? {
        switch kind {
        case "captureToInbox":      return text.map(Self.captureToInbox)
        case "updateNow":           return text.map(Self.updateNow)
        case "createPerson":        return name.map(Self.createPerson)
        case "promoteTopic":        return title.map(Self.promoteTopic)
        case "appendTimeline":
            guard let person, let entry else { return nil }
            return .appendTimeline(person: person, entry: entry)
        case "createSource":
            guard let title, let body else { return nil }
            return .createSource(title: title, body: body)
        case "nominateLink":
            guard let fromPage, let toTitle else { return nil }
            return .nominateLink(fromPage: fromPage, toTitle: toTitle)
        case "rewriteCuratedPage":
            guard let title, let body else { return nil }
            return .rewriteCuratedPage(title: title, body: body)
        case "resolveContradiction":
            guard let page, let detail else { return nil }
            return .resolveContradiction(page: page, detail: detail)
        case "mergeIdentities":
            guard let into, let from else { return nil }
            return .mergeIdentities(into: into, from: from)
        default:                    return nil
        }
    }
}

/// What the curator is allowed to do with a `CurationWrite` (ADR 0015).
enum WriteDisposition: Equatable, Sendable {
    /// Mechanical/additive: apply directly to the vault. Git is the safety net.
    case autoApply
    /// The model isn't reliable enough unsupervised: surface as a one-click proposal
    /// (or hand the page to a Claude Code session) — never write silently.
    case queueSuggestion
}

/// The pure ADR 0015 rule. Deterministic and total over `CurationWrite`, so the
/// judgment-split is testable independently of the model that *generates* the writes.
enum WriteClassifier {
    static func disposition(for write: CurationWrite) -> WriteDisposition {
        switch write {
        case .captureToInbox, .appendTimeline, .appendActivity, .synthesizePerson,
             .createSource, .nominateLink, .updateNow:
            return .autoApply
        case .rewriteCuratedPage, .promoteTopic, .resolveContradiction,
             .createPerson, .mergeIdentities:
            return .queueSuggestion
        }
    }
}
