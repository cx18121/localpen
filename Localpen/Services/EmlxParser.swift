import Foundation

/// Extracts a plain-text body from an Apple Mail `.emlx` file (ADR 0019, source #3).
///
/// An `.emlx` is: a first line holding the RFC 822 message's byte length, then that
/// many bytes of the raw message, then a trailing XML plist of Mail's flags. We take
/// the declared slice (cleanly dropping the plist), split headers from body, walk a
/// `multipart/*` message for its first `text/plain` part (falling back to HTML, then
/// raw), decode the transfer encoding, and return capped, whitespace-collapsed text.
///
/// "Best-effort" by design: this feeds a context prompt, not a mail client, so a lossy
/// extraction on an exotic MIME shape is acceptable — it never throws, it returns "".
enum EmlxParser {

    /// Parse `.emlx` bytes → clean body text, capped via `ContextEngine.condense`.
    static func bodyText(_ data: Data, charCap: Int) -> String {
        guard let message = rfc822Slice(data) else { return "" }
        let (headers, body) = splitHeadersBody(message)
        let raw = extractPlainText(headers: headers, body: body)
        return ContextEngine.condense(raw, charCap: charCap)
    }

    // MARK: - .emlx framing

    /// Drop the leading byte-count line and the trailing plist, returning just the
    /// RFC 822 message. Uses the declared length when valid; otherwise falls back to
    /// "everything after the first newline minus a trailing plist".
    static func rfc822Slice(_ data: Data) -> String? {
        guard let nl = data.firstIndex(of: 0x0A) else {
            return String(data: data, encoding: .utf8)
        }
        let firstLine = String(decoding: data[data.startIndex..<nl], as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        let rest = data[data.index(after: nl)...]
        if let len = Int(firstLine), len > 0, len <= rest.count {
            let slice = rest.prefix(len)
            return decodeText(Data(slice))
        }
        // No valid length prefix: strip a trailing plist if present.
        var text = decodeText(Data(rest)) ?? ""
        if let r = text.range(of: "<?xml", options: .backwards) {
            text = String(text[text.startIndex..<r.lowerBound])
        }
        return text
    }

    // MARK: - MIME

    private static func splitHeadersBody(_ message: String) -> (String, String) {
        if let r = message.range(of: "\r\n\r\n") {
            return (String(message[..<r.lowerBound]), String(message[r.upperBound...]))
        }
        if let r = message.range(of: "\n\n") {
            return (String(message[..<r.lowerBound]), String(message[r.upperBound...]))
        }
        return (message, "")
    }

    /// Header lookup that respects RFC 822 folding (continuation lines start with WSP).
    /// Returns the raw value (NOT lowercased — callers lowercase for type checks but must
    /// keep original case for the boundary, which is case-sensitive).
    static func header(_ name: String, in headers: String) -> String? {
        let unfolded = headers
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n ", with: " ")
            .replacingOccurrences(of: "\n\t", with: " ")
        for raw in unfolded.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            if key.caseInsensitiveCompare(name) == .orderedSame {
                return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func extractPlainText(headers: String, body: String) -> String {
        let rawCT = header("Content-Type", in: headers) ?? "text/plain"
        let ct = rawCT.lowercased()
        // Boundary from the raw (case-sensitive) Content-Type, not the lowercased one.
        if ct.contains("multipart/"), let bnd = boundary(from: rawCT) {
            return walkMultipart(body, boundary: bnd)
        }
        let decoded = decodeTransfer(body, encoding: header("Content-Transfer-Encoding", in: headers))
        return ct.contains("text/html") ? stripHTML(decoded) : decoded
    }

    /// One level of multipart: pick the first `text/plain` part; else first `text/html`
    /// (stripped); else recurse into a nested multipart. Good enough for the common
    /// `multipart/alternative(text/plain, text/html)` and `mixed` shapes.
    private static func walkMultipart(_ body: String, boundary: String) -> String {
        let parts = body.components(separatedBy: "--\(boundary)")
        var htmlFallback: String?
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "--" { continue }
            let (h, b) = splitHeadersBody(part.hasPrefix("\n") || part.hasPrefix("\r")
                                         ? String(part.drop(while: { $0 == "\n" || $0 == "\r" }))
                                         : part)
            let rawCT = header("Content-Type", in: h) ?? "text/plain"
            let ct = rawCT.lowercased()
            let decoded = decodeTransfer(b, encoding: header("Content-Transfer-Encoding", in: h))
            if ct.contains("text/plain") {
                let text = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            } else if ct.contains("text/html"), htmlFallback == nil {
                htmlFallback = stripHTML(decoded)
            } else if ct.contains("multipart/"), let nested = Self.boundary(from: rawCT) {
                let inner = walkMultipart(b, boundary: nested)
                if !inner.isEmpty { return inner }
            }
        }
        return htmlFallback ?? ""
    }

    private static func boundary(from contentType: String) -> String? {
        guard let r = contentType.range(of: "boundary=", options: .caseInsensitive) else { return nil }
        var b = String(contentType[r.upperBound...])
        if let semi = b.firstIndex(of: ";") { b = String(b[..<semi]) }
        b = b.trimmingCharacters(in: .whitespaces)
        if b.hasPrefix("\"") && b.hasSuffix("\"") && b.count >= 2 { b = String(b.dropFirst().dropLast()) }
        return b.isEmpty ? nil : b
    }

    // MARK: - Transfer + charset decoding

    private static func decodeTransfer(_ body: String, encoding: String?) -> String {
        switch encoding?.lowercased() {
        case "base64":
            let joined = body.components(separatedBy: .whitespacesAndNewlines).joined()
            if let d = Data(base64Encoded: joined), let s = decodeText(d) { return s }
            return body
        case "quoted-printable":
            return decodeQuotedPrintable(body)
        default:
            return body
        }
    }

    static func decodeQuotedPrintable(_ s: String) -> String {
        var out = Data()
        let bytes = Array(s.utf8)
        var i = 0
        while i < bytes.count {
            let c = bytes[i]
            if c == 0x3D {  // '='
                // Soft line break: "=\r\n" or "=\n" → drop.
                if i + 1 < bytes.count, bytes[i+1] == 0x0A { i += 2; continue }
                if i + 2 < bytes.count, bytes[i+1] == 0x0D, bytes[i+2] == 0x0A { i += 3; continue }
                if i + 2 < bytes.count,
                   let hi = hex(bytes[i+1]), let lo = hex(bytes[i+2]) {
                    out.append(UInt8(hi * 16 + lo)); i += 3; continue
                }
                out.append(c); i += 1
            } else {
                out.append(c); i += 1
            }
        }
        return decodeText(out) ?? s
    }

    private static func hex(_ b: UInt8) -> Int? {
        switch b {
        case 0x30...0x39: return Int(b - 0x30)
        case 0x41...0x46: return Int(b - 0x41 + 10)
        case 0x61...0x66: return Int(b - 0x61 + 10)
        default: return nil
        }
    }

    /// UTF-8 first, Latin-1 fallback (never fails) so a non-UTF-8 mail still yields text.
    private static func decodeText(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    // MARK: - HTML

    /// Crude tag strip for HTML-only mail: drop script/style blocks, remove tags,
    /// decode the handful of common entities, collapse whitespace.
    static func stripHTML(_ html: String) -> String {
        var s = html
        for tag in ["script", "style", "head"] {
            s = s.replacingOccurrences(
                of: "<\(tag)[^>]*>.*?</\(tag)>",
                with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
                        "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&mdash;": "-", "&ndash;": "-"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        // Tag removal leaves whitespace runs; collapse so the body reads cleanly.
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
