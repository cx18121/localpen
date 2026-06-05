import ScreenCaptureKit
import Vision
import AppKit

/// OCR the window the user summoned from (ADR 0021, screen-OCR context source). Captures
/// the frontmost on-screen window of `pid` (held at summon, since once the notch opens
/// Localpen is frontmost) and runs Vision text recognition. Window-scoped on purpose:
/// the spike showed full-screen OCR is a noisy soup of menu bar + multiple windows, while
/// one window's text is clean. Captures the window surface, so the notch occluding it
/// doesn't matter. Returns nil when there's no grant / no window / no text.
enum ScreenCapture {

    struct Result: Sendable { let appName: String?; let text: String }

    /// Capture + OCR the frontmost window owned by `pid`. `charCap` caps the text.
    static func captureWindowText(pid: pid_t, charCap: Int) async -> Result? {
        guard pid > 0 else { return nil }
        // No grant yet: ask (adds Localpen to the Screen Recording list) and bail — the
        // user grants + relaunches, then the next add succeeds. Never a silent capture
        // of a black frame.
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            return nil
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            // content.windows is front-to-back; the first window of this pid is the one
            // the user was looking at. Skip zero-area/util windows.
            guard let window = content.windows.first(where: {
                $0.owningApplication?.processID == pid && $0.frame.width > 40 && $0.frame.height > 40
            }) else { return nil }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let cfg = SCStreamConfiguration()
            cfg.width = Int(window.frame.width * 2)    // 2x backing → crisper text → better OCR
            cfg.height = Int(window.frame.height * 2)
            cfg.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)

            let text = await Task.detached(priority: .userInitiated) { () -> String in
                let req = VNRecognizeTextRequest()
                req.recognitionLevel = .accurate
                req.usesLanguageCorrection = true
                guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])) != nil else { return "" }
                let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                return ContextEngine.condense(lines.joined(separator: "\n"), charCap: charCap)
            }.value

            guard !text.isEmpty else { return nil }
            return Result(appName: window.owningApplication?.applicationName, text: text)
        } catch {
            return nil
        }
    }
}
