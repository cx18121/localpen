import Foundation
import AppKit

/// The hub surface's state + data loading (ADR 0016), extracted from PanelController so the
/// seven hub mode views bind one focused model instead of the whole controller. It owns no
/// session/streaming machinery — only the displayed hub data and the reads that populate it
/// (KB index, suggestion queue, vault files). The panel *transition* into the hub stays on
/// PanelController (it sets `state`); this model just prepares and serves the content.
@MainActor
@Observable
final class HubModel {
    /// Which hub mode is showing. Restored from UserDefaults on open; persisted on change.
    var mode: HubMode = .ask
    /// The KB-mode search field text.
    var query: String = ""
    /// KB-mode results (recent pages when the query is empty, search hits otherwise).
    var notes: [KBPage] = []
    /// People-mode list (pages of type `.person`).
    var people: [KBPage] = []
    /// People-mode relationship buckets (follow-ups due / reconnect / all) — ADR 0015 CRM.
    var peopleInsights = PeopleInsights.Result()
    /// Now-mode: the rendered text of `now.md` (empty if absent / brain off).
    var nowText: String = ""
    /// Today-mode (daily briefing): the cached upcoming schedule + recent inbox items.
    /// Follow-ups reuse `peopleInsights`; the now excerpt reuses `nowText`.
    var todaySchedule: String? = nil
    var todayInbox: [String] = []   // titles of recent raw/inbox/ items awaiting triage
    /// Transient confirmation after a Capture write ("Saved to inbox").
    var captureStatus: String? = nil
    /// Suggestions-mode: the queued high-judgment proposals (ADR 0015).
    var suggestions: [Suggestion] = []
    /// Transient status after an apply/dismiss in Suggestions mode.
    var suggestionStatus: String? = nil

    @ObservationIgnored private let brainIndex: BrainIndex?
    @ObservationIgnored private let suggestionStore: SuggestionStore?
    private static let lastModeKey = "hub.lastMode"

    init(brainIndex: BrainIndex?, suggestionStore: SuggestionStore?) {
        self.brainIndex = brainIndex
        self.suggestionStore = suggestionStore
    }

    /// Prepare the hub for display: restore the last mode, clear transient fields, load it.
    /// Called by `PanelController.enterHub` right before it flips `state` to `.hub`.
    func enter() {
        mode = UserDefaults.standard.string(forKey: Self.lastModeKey).flatMap(HubMode.init(rawValue:)) ?? .ask
        query = ""
        captureStatus = nil
        suggestionStatus = nil
        loadCurrentMode()
    }

    func setMode(_ mode: HubMode) {
        self.mode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.lastModeKey)
        query = ""
        captureStatus = nil
        suggestionStatus = nil
        loadCurrentMode()
    }

    /// Load the active mode's data. Ask is an editor (no load). Today loads everything it now
    /// rolls up (ADR 0024): schedule, now.md, follow-ups, suggestions, inbox.
    private func loadCurrentMode() {
        switch mode {
        case .today:   loadToday()
        case .kb:      searchNotes()
        case .people:  loadPeople()
        case .ask:     break
        }
    }

    /// Daily briefing (ADR 0024): the cached schedule, the now.md focus, due follow-ups, the
    /// suggestion queue, and recent inbox items — a morning glance over already-assembled
    /// signals, now the single home that absorbed Now / Capture / Suggestions.
    func loadToday() {
        // Schedule: the same cached 7-day window the ask chip uses (warms in background).
        let schedule = ICSCalendarReader().upcomingContext()
        todaySchedule = (schedule?.isEmpty == false) ? schedule : nil
        loadNow()          // populates nowText (Focus glance)
        loadPeople()       // populates peopleInsights (follow-ups teaser → People)
        loadSuggestions()  // populates suggestions (To review section)
        todayInbox = InboxStore(vaultRoot: BrainAccess.vaultRoot).recentTitles()
    }

    /// KB results: recent notes when the query is empty, search hits otherwise.
    func searchNotes() {
        guard let index = brainIndex else { notes = []; return }
        let q = query.trimmingCharacters(in: .whitespaces)
        Task { @MainActor in
            if q.isEmpty {
                self.notes = (await index.recentPages(limit: 40)).filter { $0.type != .person }
            } else {
                self.notes = (await KBSearch(dbQueue: index.dbQueue).search(q, limit: 30)).map(\.page)
            }
        }
    }

    private func loadPeople() {
        guard let index = brainIndex else { people = []; peopleInsights = .init(); return }
        Task { @MainActor in
            let loaded = (await index.recentPages(limit: 200)).filter { $0.type == .person }
            self.people = loaded
            self.peopleInsights = PeopleInsights.analyze(loaded, today: Date())
        }
    }

    private func loadNow() {
        let url = BrainAccess.vaultRoot.appendingPathComponent("now.md")
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        nowText = MarkdownParser.splitFrontmatter(raw).body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Open a KB page in its default app — Obsidian registers as the `.md` handler.
    func openNote(_ page: KBPage) {
        NSWorkspace.shared.open(URL(fileURLWithPath: page.path))
    }

    /// Open `now.md` in its default editor — the edit door for the read-only Now glance
    /// surface. Editing happens in Obsidian (the `.md` handler); the panel re-reads on reopen.
    func openNow() {
        NSWorkspace.shared.open(BrainAccess.vaultRoot.appendingPathComponent("now.md"))
    }

    /// Capture free text into the vault's `raw/inbox/` (ADR 0015 additive write).
    func commitCapture(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try InboxStore(vaultRoot: BrainAccess.vaultRoot).capture(trimmed)
            captureStatus = "Saved to inbox"
        } catch {
            captureStatus = "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// Load the high-judgment suggestion queue (ADR 0015) for the hub's Suggestions mode.
    func loadSuggestions() {
        suggestions = suggestionStore?.all() ?? []
    }

    /// Apply a user-approved suggestion: the one click is the human judgment the classifier
    /// required, so this writes via `VaultWriter.applyApproved`. On success the suggestion
    /// leaves the queue and the index re-reads the new page. Errors surface inline.
    func applySuggestion(_ suggestion: Suggestion) {
        guard let store = suggestionStore else { return }
        guard let write = suggestion.payload.curationWrite() else {
            suggestionStatus = "Couldn't reconstruct that proposal."
            return
        }
        let writer = VaultWriter(vaultRoot: BrainAccess.vaultRoot)
        do {
            _ = try writer.applyApproved(write, nowMillis: Int64(Date().timeIntervalSince1970 * 1000))
            store.remove(id: suggestion.id)
            suggestionStatus = "Applied: \(suggestion.summary)"
            loadSuggestions()
            if let index = brainIndex {
                let root = BrainAccess.vaultRoot
                Task.detached { await index.reindexAll(root: root) }
            }
        } catch VaultWriter.WriteError.targetExists {
            // The page already exists, so the suggestion's goal (it's there) is already
            // met — resolve it cleanly instead of erroring, and drop the stale suggestion.
            store.remove(id: suggestion.id)
            suggestionStatus = "Already exists — \(suggestion.summary)"
            loadSuggestions()
        } catch let VaultWriter.WriteError.notApplicable(msg) {
            suggestionStatus = msg
        } catch {
            suggestionStatus = "Couldn't apply: \(error.localizedDescription)"
        }
    }

    /// Drop a suggestion without applying it.
    func dismissSuggestion(_ suggestion: Suggestion) {
        suggestionStore?.remove(id: suggestion.id)
        suggestionStatus = "Dismissed."
        loadSuggestions()
    }
}
