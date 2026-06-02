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
        case .captureToInbox, .appendTimeline, .createSource, .nominateLink, .updateNow:
            return .autoApply
        case .rewriteCuratedPage, .promoteTopic, .resolveContradiction,
             .createPerson, .mergeIdentities:
            return .queueSuggestion
        }
    }
}
