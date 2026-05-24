import SwiftUI
import UniformTypeIdentifiers
import GRDB

struct HistorySettingsView: View {
    let persistence: Persistence?
    @State private var rowCount: Int = 0
    @State private var showingClearConfirm: Bool = false
    @State private var showingExporter: Bool = false
    @State private var exportDocument: HistoryDocument?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s5) {
            Text("Interaction history")
                .font(Typography.body)
                .foregroundStyle(Tokens.text)

            Text("\(rowCount) interaction\(rowCount == 1 ? "" : "s") saved locally.")
                .font(Typography.subhead)
                .foregroundStyle(Tokens.textMute)

            HStack(spacing: Spacing.s5) {
                Button("Export…") {
                    Task { await prepareExport() }
                }
                .disabled(persistence == nil || rowCount == 0)

                Button("Clear history") {
                    showingClearConfirm = true
                }
                .disabled(persistence == nil || rowCount == 0)
            }

            Spacer()

            Text("History never leaves this Mac. Stored at ~/Library/Application Support/Localpen/history.sqlite.")
                .font(Typography.subhead)
                .foregroundStyle(Tokens.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task {
            rowCount = await persistence?.count() ?? 0
        }
        .alert("Clear history?", isPresented: $showingClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                Task {
                    try? await persistence?.deleteAll()
                    rowCount = await persistence?.count() ?? 0
                }
            }
        } message: {
            Text("All \(rowCount) interactions will be permanently deleted from this Mac.")
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "localpen-history.json"
        ) { _ in }
    }

    private func prepareExport() async {
        guard let persistence else { return }
        let json = (try? await persistence.dbQueue.read { db -> String in
            // Light-touch JSON export of all rows.
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM interactions ORDER BY id")
            let dicts: [[String: Any]] = rows.map { row in
                var d: [String: Any] = [:]
                for col in row.columnNames {
                    if let v = row[col] {
                        d[col] = v
                    }
                }
                return d
            }
            let data = try JSONSerialization.data(withJSONObject: dicts, options: [.prettyPrinted, .sortedKeys])
            return String(data: data, encoding: .utf8) ?? "[]"
        }) ?? "[]"
        exportDocument = HistoryDocument(text: json)
        showingExporter = true
    }
}
