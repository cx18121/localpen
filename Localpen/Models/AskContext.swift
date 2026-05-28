import Foundation

/// User-facing representation of context attached to a free-form ask.
/// Task 4 fills in `from(_ snapshot:)`. Task 3 only needs the struct shape.
struct AskContext: Equatable {
    var appLabel: String?
    var selection: String?

    static let empty = AskContext()
}
