import AppKit
import SwiftUI
import os

@MainActor
final class PanelController {
    private var panel: FloatingPanel?
    private let textIO: TextIO
    private let streaming: StreamingClient
    private let log = Logger(subsystem: "app.localpen.Localpen", category: "Latency")

    private var currentCapture: TextIO.Capture?

    init(textIO: TextIO, streaming: StreamingClient) {
        self.textIO = textIO
        self.streaming = streaming
    }

    func toggleFromHotkey() {
        if let p = panel, p.isVisible {
            p.orderOut(nil)
            return
        }
        Task { await captureAndShow() }
    }

    private func captureAndShow() async {
        let hotkeyTime = ContinuousClock.now
        let capture = await textIO.captureSelection()
        currentCapture = capture

        let selectionText = capture.selection ?? ""
        let streamFactory: () -> AsyncThrowingStream<String, Error> = { [streaming, log] in
            let upstream = streaming.complete(
                systemPrompt: M1Prompts.polish,
                userText: selectionText
            )
            return AsyncThrowingStream { continuation in
                Task {
                    var firstTokenLogged = false
                    do {
                        for try await token in upstream {
                            if !firstTokenLogged {
                                let elapsed = ContinuousClock.now - hotkeyTime
                                log.info("hotkey→first-token: \(elapsed)")
                                firstTokenLogged = true
                            }
                            continuation.yield(token)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }

        let view = TracerBulletView(
            selection: selectionText,
            sourceAppName: capture.sourceAppName,
            polishStream: streamFactory,
            onAccept: { [weak self] result in
                Task { await self?.accept(result: result) }
            },
            onDismiss: { [weak self] in
                self?.panel?.orderOut(nil)
            }
        )

        let hosting = NSHostingView(rootView: view)
        let rect = NSRect(x: 0, y: 0, width: 360, height: 320)
        hosting.frame = rect

        if panel == nil {
            panel = FloatingPanel(contentRect: rect)
        }
        panel?.contentView = hosting
        panel?.setContentSize(rect.size)
        if let screenFrame = NSScreen.main?.visibleFrame {
            let x = screenFrame.maxX - rect.width - 24
            let y = screenFrame.midY - rect.height / 2
            panel?.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel?.orderFrontRegardless()
    }

    private func accept(result: String) async {
        guard let capture = currentCapture else { return }
        panel?.orderOut(nil)
        await textIO.pasteBack(result: result, capture: capture)
        currentCapture = nil
    }
}

enum M1Prompts {
    static let polish = """
    You are a writing assistant. Polish the user's text: fix grammar, smooth awkward phrasing, \
    minor rephrasing only. Preserve meaning, tone, and approximate length. Output only the polished \
    text — no commentary, no quotes, no preamble.
    """
}
