import Foundation

// GRDB record per SWIFTUI-SPEC.md §11.3. Implementation lands in M3.
struct Interaction {
    var id: Int64?
    var timestamp: Date
    var sourceApp: String?
    var selection: String?
    var action: String
    var customPrompt: String?
    var modelID: String
    var modelOutput: String?
    var accepted: Bool
    var editedOutput: String?
}
