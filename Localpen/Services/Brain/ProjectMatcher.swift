import Foundation

/// Maps the repo you're working in to its cxkb `projects/` page (project-aware recall —
/// "feed my agents THIS-project context"). Pure + total so the matching is unit-testable.
///
/// Repo dirs are kebab/lowercase (`local-pen`), project pages are Title Case (`Localpen`),
/// so matching is on a normalized form (alphanumerics only, lowercased). Exact normalized
/// title match wins; callers fall back to a free-text search when there's no match.
enum ProjectMatcher {
    /// Lowercased, alphanumerics only — so "Local Pen", "local-pen", "localpen" all unify.
    static func normalize(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    /// Derive a project identifier from a filesystem path — its last path component (the
    /// repo directory name). Empty / "." resolve to the current working directory; "~" is
    /// expanded. Trailing slashes tolerated.
    static func repoName(fromPath path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespaces)
        if p.isEmpty || p == "." { p = FileManager.default.currentDirectoryPath }
        p = (p as NSString).expandingTildeInPath
        return URL(fileURLWithPath: p).standardizedFileURL.lastPathComponent
    }

    /// The project page whose title matches the repo name (normalized). nil ⇒ no exact
    /// match (caller should fall back to search). Among ties, the shortest title wins
    /// (the most specific page, not an over-long variant).
    static func match(repoName: String, projects: [KBPage]) -> KBPage? {
        let target = normalize(repoName)
        guard !target.isEmpty else { return nil }
        return projects
            .filter { normalize($0.title) == target }
            .min { $0.title.count < $1.title.count }
    }
}
