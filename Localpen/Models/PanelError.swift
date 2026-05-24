import Foundation

enum PanelError: Error, Equatable {
    case serverDown(reason: String)
    case timeout
    case pasteBackFallback
    case diskFull
    case hotkeyConflict
    case network

    var displayMessage: String {
        switch self {
        case .serverDown:        return "Model server stopped. Restarting…"
        case .timeout:           return "Taking longer than usual."
        case .pasteBackFallback: return "Result copied. Press ⌘V in your app."
        case .diskFull:          return "Not enough space — need ~4 GB free."
        case .hotkeyConflict:    return "Couldn't capture the hotkey. Change in Localpen settings."
        case .network:           return "Can't reach the model server. Check your connection."
        }
    }
}
