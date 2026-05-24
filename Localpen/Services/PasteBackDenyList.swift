import Foundation
import TOMLKit
import os

// Loads bundle IDs from Resources/known-bad-paste-apps.toml per ADR 0003 §9.3.
// Populated empirically during M7 manual testing.
enum PasteBackDenyList {
    private static let log = Logger(subsystem: "app.localpen.Localpen", category: "PasteDeny")

    private static let bundleIDs: Set<String> = {
        guard let url = Bundle.main.url(forResource: "known-bad-paste-apps", withExtension: "toml"),
              let toml = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        struct Doc: Decodable { let bundle_ids: [String] }
        do {
            let doc = try TOMLDecoder().decode(Doc.self, from: toml)
            log.info("deny-list: \(doc.bundle_ids.count) entries")
            return Set(doc.bundle_ids)
        } catch {
            log.error("deny-list decode failed: \(error.localizedDescription)")
            return []
        }
    }()

    static func shouldSkip(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains(bundleID)
    }
}
