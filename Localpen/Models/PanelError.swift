import Foundation

enum PanelError: Error, Equatable {
    case serverDown(reason: String)
    case timeout
    case pasteBackFallback
    case diskFull(needed: Int64, available: Int64)
    case hotkeyConflict
    case network

    var displayMessage: String {
        switch self {
        case .serverDown:        return "Model server stopped. Restarting…"
        case .timeout:           return "Taking longer than usual."
        case .pasteBackFallback: return "Result copied. Press ⌘V in your app."
        case .diskFull(let needed, let available):
            let neededGB = Double(needed) / 1_073_741_824
            let availableGB = Double(available) / 1_073_741_824
            return String(format: "Not enough space — need %.1f GB, have %.1f GB.", neededGB, availableGB)
        case .hotkeyConflict:    return "Couldn't capture the hotkey. Change in Localpen settings."
        case .network:           return "Can't reach the model server. Check your connection."
        }
    }

    var actionLabel: String {
        switch self {
        case .serverDown, .timeout, .network: return "Retry"
        case .pasteBackFallback:              return "Dismiss"
        case .diskFull:                       return "Open Storage Settings"
        case .hotkeyConflict:                 return "Open Settings"
        }
    }
}
