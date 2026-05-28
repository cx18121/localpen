import Foundation
import GRDB

/// Per-action policy for what counts as a user-voice sample. The spec's
/// "Authored-text attribution" table, encoded once so neither exemplar selection
/// nor profile generation can drift from it at call sites.
///
/// Rule precedence (highest first):
///   1) `editedOutput` (the user's hand correction, when it differs from
///      model_output) — highest signal, ANY action.
///   2) For `.respond`, NEVER use `selection` (that's the third-party message
///      being replied to) and NEVER use `model_output` (that's the model's own
///      style — would induce drift). Use `custom_prompt` (the user's steer).
///   3) For conversation rows (thread_id != NULL), use `custom_prompt` — the
///      user's follow-up text. `selection` is always NULL there per ConversationStore.
///   4) For `.custom` with empty selection, use `custom_prompt` (the user's
///      instruction).
///   5) Otherwise (proofread/polish/moreFormal/moreCasual/shorter/custom with
///      non-empty selection), `selection` IS the user's text.
///
/// The query below is the ONLY place this precedence is encoded. Tests assert it
/// row-by-row.
enum MemoryAttribution {

    /// Exemplar selection: returns up to `limit` qualifying samples respecting the
    /// forget tombstone and per-action attribution. Returns ordered-by-recency in
    /// tests (`shuffle: false`) for determinism; `shuffle: true` for production.
    ///
    /// The CASE ordering encodes the spec's attribution policy. Critical: raw
    /// `model_output` is NEVER a user-voice sample — even an accepted reply was
    /// composed by the model, not the user, and using it would train memory on
    /// the model's own style (drift inducer). The user-authored sources for a
    /// `.respond` row are `edited_output` (if it differs from the model's output)
    /// and `custom_prompt` (how the user steered the reply).
    static func selectExemplars(in db: Database,
                                forgottenBefore: Int64,
                                limit: Int,
                                shuffle: Bool) throws -> [String] {
        let poolSize = max(limit * 4, 20)
        let rows = try Row.fetchAll(db, sql: """
            SELECT
              CASE
                -- highest signal: user's hand correction of the model output
                WHEN edited_output IS NOT NULL
                     AND edited_output <> COALESCE(model_output, '')
                     AND length(edited_output) >= 20 THEN edited_output
                -- respond: selection is third-party content; the user's steer
                -- phrasing (custom_prompt) IS legitimate user-voice signal.
                WHEN action = 'respond' THEN custom_prompt
                -- conversation: selection is always NULL; user follow-up is in custom_prompt.
                WHEN thread_id IS NOT NULL THEN custom_prompt
                -- custom one-shot with empty selection: fall back to the user's
                -- instruction text (how the user phrases requests).
                WHEN action = 'custom' AND (selection IS NULL OR length(selection) = 0)
                     THEN custom_prompt
                -- everything else: selection IS the user's own writing.
                ELSE selection
              END AS sample
            FROM interactions
            WHERE timestamp >= ?
            ORDER BY timestamp DESC, id DESC
            LIMIT ?
            """, arguments: [forgottenBefore, poolSize])

        var seen = Set<String>()
        var samples: [String] = []
        for row in rows {
            guard let s: String = row["sample"], (20...1200).contains(s.count) else { continue }
            let key = String(s.prefix(80))   // crude near-dup guard
            if seen.insert(key).inserted { samples.append(s) }
        }
        let picked = shuffle ? Array(samples.shuffled().prefix(limit)) : Array(samples.prefix(limit))
        return picked
    }

    /// Profile-generation input: returns up to `cap` (recent, eligible) samples
    /// labeled by source for the summarization prompt. Same attribution policy as
    /// `selectExemplars`, but emits a struct so the prompt builder can prioritize
    /// editedOutput rows and label sources.
    struct Sample: Equatable {
        let text: String
        let source: Source
        enum Source: String, Equatable {
            case userText           // user's own writing (selection on non-respond rows)
            case userEdit           // user's hand correction of model output (must differ from model_output)
            case replySteer         // user's steer phrasing on a .respond row (custom_prompt)
            case customSteer        // user's instruction on a .custom one-shot with empty selection
            case conversationTurn   // user's follow-up in a thread (custom_prompt)
        }
    }

    static func collectGenerationSamples(in db: Database,
                                         forgottenBefore: Int64,
                                         cap: Int) throws -> [Sample] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT action, selection, custom_prompt, model_output, edited_output, accepted, thread_id
            FROM interactions
            WHERE timestamp >= ?
            ORDER BY timestamp DESC, id DESC
            LIMIT ?
            """, arguments: [forgottenBefore, cap * 3])

        var out: [Sample] = []
        out.reserveCapacity(cap)
        for row in rows {
            let action: String = row["action"] ?? "custom"
            let selection: String? = row["selection"]
            let customPrompt: String? = row["custom_prompt"]
            let modelOutput: String? = row["model_output"]
            let editedOutput: String? = row["edited_output"]
            let accepted: Bool = (row["accepted"] as Int64? ?? 0) == 1
            let threadID: Int64? = row["thread_id"]

            // Precedence (mirrors the SQL CASE above):
            //   1) user's hand correction (must differ from model_output) — highest signal
            //   2) respond → custom_prompt only (the steer); never model_output (model's style)
            //   3) conversation rows → custom_prompt (selection is always NULL there)
            //   4) custom with empty selection → custom_prompt (the user's instruction)
            //   5) otherwise selection (the user's own writing)
            if let e = editedOutput, e != (modelOutput ?? ""), e.count >= 20 {
                out.append(.init(text: e, source: .userEdit))
            } else if action == "respond" {
                if let c = customPrompt, c.count >= 20 {
                    out.append(.init(text: c, source: .replySteer))
                }
                // raw model_output is the model's style, NOT user voice — skip.
            } else if threadID != nil {
                if let c = customPrompt, c.count >= 20 {
                    out.append(.init(text: c, source: .conversationTurn))
                }
            } else if action == "custom", (selection ?? "").isEmpty {
                if let c = customPrompt, c.count >= 20 {
                    out.append(.init(text: c, source: .customSteer))
                }
            } else if let s = selection, s.count >= 20 {
                out.append(.init(text: s, source: .userText))
            }
            _ = accepted   // currently unused; kept in the SELECT so future signals can read it
            if out.count >= cap { break }
        }
        return out
    }
}
