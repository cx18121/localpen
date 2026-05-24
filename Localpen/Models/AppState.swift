import Foundation
import Observation

// Top-level @Observable per SWIFTUI-SPEC.md §3.1.
// Server status, current model, AX permission state, history-write toggle.
// Filled in during M3/M4.
@Observable
@MainActor
final class AppState {
    var hasAXPermission: Bool = false
    var activeModelID: String = "qwen-2.5-7b-instruct-q4-km"
    var historyEnabled: Bool = true
}
