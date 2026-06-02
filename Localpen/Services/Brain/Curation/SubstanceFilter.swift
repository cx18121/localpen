import Foundation

/// The substance filter (ADR 0015): keeps trivial transforms and throwaway asks out of
/// the brain. It is a *cheap deterministic pre-filter*, not the final judgment — it
/// rejects the clearly-not-worth-it so the dream cycle never spends 14B time on them, and
/// passes everything plausible to the model, which makes the nuanced call ("a draft to a
/// named person about a project, yes; 'fix this typo,' no").
///
/// Pure and total, so the gate is testable without a model. Deliberately conservative:
/// when in doubt it returns `true` (consider) — a false-keep just costs some model time,
/// while a false-drop silently loses knowledge, which is the worse failure.
enum SubstanceFilter {
    /// The fixed quick-action transforms (ADR 0004). A bare edit of someone's text is
    /// mechanical — never brain-worthy on its own, however long the edited passage.
    static let mechanicalActions: Set<String> =
        ["proofread", "polish", "more_formal", "more_casual", "shorter"]

    /// Below this many total transcript characters a thread is throwaway chatter.
    static let minSubstanceChars = 80

    /// `false` ⇒ drop now (don't synthesize). `true` ⇒ hand to the dream cycle's model.
    static func shouldConsider(_ convo: StashedConversation) -> Bool {
        let content = convo.turns
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.count >= minSubstanceChars else { return false }

        // A pure quick-action transform with no real conversation around it (just the
        // seed + result, no follow-up) is a mechanical edit — drop regardless of length.
        if !convo.isAsk,
           mechanicalActions.contains(convo.seedAction),
           convo.turns.count <= 2 {
            return false
        }
        return true
    }
}
