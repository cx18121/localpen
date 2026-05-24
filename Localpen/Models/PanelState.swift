import Foundation

// Full state machine per SWIFTUI-SPEC.md §6. Implementation lands in M2.
// M1's PanelController uses a simpler ad-hoc state.
enum PanelState {
    case hidden
    case firstRun(FirstRunStep)
    case empty
    case captured(Selection)
    case customPrompt(Selection?)
    case generating(Selection?, Action, partial: String)
    case result(Selection?, Action, finalResult: String, isEditing: Bool)
    case error(PanelError)
}

enum FirstRunStep {
    case permission
    case download(bytesDone: Int64, bytesTotal: Int64)
    case complete
}
