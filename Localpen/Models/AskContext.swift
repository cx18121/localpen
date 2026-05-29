import Foundation

/// User-facing representation of context attached to a free-form ask. Each
/// non-nil field renders as a removable chip above the AskInput. Clearing
/// a chip nils the field; submitting takes a final snapshot of what
/// survived.
struct AskContext: Equatable {
    var appLabel: String?    // "Mail · Re: budget Q3" — formatted from probe snapshot
    var selection: String?   // raw text; the chip shows a "N words selected" summary

    static let empty = AskContext()

    /// Builds an AskContext from a ContextProbe snapshot. Formats the
    /// appLabel as "<app> · <window>" when both are present, falls back
    /// gracefully to whichever single field is non-nil.
    static func from(_ snapshot: ContextProbe.Snapshot) -> AskContext {
        let label: String?
        switch (snapshot.appName, snapshot.windowTitle) {
        case (let app?, let title?):  label = "\(app) · \(title)"
        case (let app?, nil):         label = app
        case (nil, let title?):       label = title
        case (nil, nil):              label = nil
        }
        return AskContext(appLabel: label, selection: snapshot.selection)
    }
}
