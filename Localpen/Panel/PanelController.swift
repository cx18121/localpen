import AppKit
import SwiftUI
import Observation
import os

@MainActor
@Observable
final class PanelController {
    var state: PanelState = .hidden

    @ObservationIgnored private var panel: FloatingPanel?
    @ObservationIgnored private let textIO: TextIO
    @ObservationIgnored private let streaming: StreamingClient
    @ObservationIgnored private let log = Logger(subsystem: "app.localpen.Localpen", category: "Latency")

    @ObservationIgnored private var activeCapture: TextIO.Capture?
    @ObservationIgnored private var streamingTask: Task<Void, Never>?
    @ObservationIgnored private var hotkeyTime: ContinuousClock.Instant?

    init(textIO: TextIO, streaming: StreamingClient) {
        self.textIO = textIO
        self.streaming = streaming
    }

    // MARK: - Entry / dismiss

    func toggleFromHotkey() {
        if state.isVisible {
            dismiss()
            return
        }
        Task { await captureAndShow() }
    }

    func dismiss() {
        streamingTask?.cancel()
        streamingTask = nil
        state = .hidden
        panel?.orderOut(nil)
        activeCapture = nil
        hotkeyTime = nil
    }

    // MARK: - State transitions driven by views

    func pick(_ action: Action) {
        switch action {
        case .custom:
            state = .customPrompt(currentSelection())
        default:
            startGeneration(action: action)
        }
    }

    func submitCustomPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        startGeneration(action: .custom(trimmed))
    }

    func backToMenu() {
        streamingTask?.cancel()
        streamingTask = nil
        if let sel = currentSelection() {
            state = .captured(sel)
        } else {
            state = .empty
        }
    }

    /// Context-aware Esc: from menu/empty → dismiss; from a sub-state → back to menu.
    func handleEscape() {
        switch state {
        case .hidden, .empty, .captured:
            dismiss()
        case .customPrompt, .generating, .result, .error:
            backToMenu()
        }
    }

    func acceptResult() {
        guard case .result(_, _, let text, _) = state else { return }
        let snapshot = activeCapture
        let panelRef = panel
        state = .hidden
        panelRef?.orderOut(nil)
        Task {
            if let cap = snapshot {
                await textIO.pasteBack(result: text, capture: cap)
            }
            await MainActor.run {
                self.activeCapture = nil
                self.hotkeyTime = nil
            }
        }
    }

    func setEditing(_ editing: Bool) {
        if case .result(let sel, let action, let text, _) = state {
            state = .result(sel, action, finalResult: text, isEditing: editing)
        }
    }

    func updateEditedResult(_ newText: String) {
        if case .result(let sel, let action, _, let editing) = state {
            state = .result(sel, action, finalResult: newText, isEditing: editing)
        }
    }

    // MARK: - Capture + show

    private func captureAndShow() async {
        hotkeyTime = ContinuousClock.now
        let capture = await textIO.captureSelection()
        activeCapture = capture

        if let text = capture.selection, !text.isEmpty {
            let sel = Selection(
                text: text,
                sourceBundleID: capture.sourceBundleID,
                sourceAppName: capture.sourceAppName
            )
            state = .captured(sel)
        } else {
            state = .empty
        }
        showPanel()
    }

    private func showPanel() {
        let view = PanelView(controller: self)
        let hosting = NSHostingView(rootView: view)
        let rect = NSRect(x: 0, y: 0, width: 360, height: 320)
        hosting.frame = rect

        if panel == nil {
            panel = FloatingPanel(contentRect: rect)
        }
        panel?.contentView = hosting

        if let screen = NSScreen.main?.visibleFrame {
            let x = screen.maxX - rect.width - 24
            let y = screen.midY - rect.height / 2
            panel?.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel?.orderFrontRegardless()
        panel?.makeKey()
    }

    // MARK: - Streaming

    private func startGeneration(action: Action) {
        let sel = currentSelection()
        state = .generating(sel, action, partial: "")
        streamingTask?.cancel()
        streamingTask = Task { @MainActor [weak self] in
            await self?.runStream(action: action, selection: sel)
        }
    }

    private func runStream(action: Action, selection: Selection?) async {
        let userText = selection?.text ?? ""
        let systemPrompt = ActionPrompts.systemPrompt(for: action)
        let userPrompt: String = {
            if case let .custom(instruction) = action {
                if userText.isEmpty {
                    return instruction
                }
                return "Instruction: \(instruction)\n\nText:\n\(userText)"
            }
            return userText
        }()

        var partial = ""
        var firstTokenLogged = false
        do {
            for try await token in streaming.complete(systemPrompt: systemPrompt, userText: userPrompt) {
                if Task.isCancelled { return }
                if !firstTokenLogged, let t = hotkeyTime {
                    let elapsed = ContinuousClock.now - t
                    log.info("hotkey→first-token: \(elapsed)")
                    firstTokenLogged = true
                }
                partial += token
                state = .generating(selection, action, partial: partial)
            }
            if Task.isCancelled { return }
            state = .result(selection, action, finalResult: partial, isEditing: false)
        } catch {
            if Task.isCancelled { return }
            state = .error(.network)
        }
    }

    // MARK: - Helpers

    private func currentSelection() -> Selection? {
        switch state {
        case .captured(let s):            return s
        case .customPrompt(let s):        return s
        case .generating(let s, _, _):    return s
        case .result(let s, _, _, _):     return s
        case .empty, .hidden, .error:     return nil
        }
    }
}
