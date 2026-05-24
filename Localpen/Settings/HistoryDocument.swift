import SwiftUI
import UniformTypeIdentifiers

// JSON file wrapper for the History tab's "Export…" action.
struct HistoryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents,
           let str = String(data: data, encoding: .utf8) {
            self.text = str
        } else {
            self.text = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: text.data(using: .utf8) ?? Data())
    }
}
