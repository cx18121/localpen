import Foundation
import GRDB

// GRDB record per SWIFTUI-SPEC.md §11.3 / ADR 0006.
// Schema (snake_case columns) lives in Persistence's migration.
struct Interaction: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var timestamp: Int64        // unix epoch seconds
    var sourceApp: String?
    var selection: String?
    var action: String
    var customPrompt: String?
    var modelID: String
    var modelOutput: String?
    var accepted: Bool
    var editedOutput: String?

    static let databaseTableName = "interactions"

    enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case sourceApp = "source_app"
        case selection
        case action
        case customPrompt = "custom_prompt"
        case modelID = "model_id"
        case modelOutput = "model_output"
        case accepted
        case editedOutput = "edited_output"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
