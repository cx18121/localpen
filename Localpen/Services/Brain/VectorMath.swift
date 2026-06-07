import Foundation

/// Pure vector helpers for dense retrieval. Brute-force cosine is fine at vault scale
/// (~hundreds–thousands of vectors); no ANN / sqlite-vec needed.
enum VectorMath {
    /// Cosine similarity in [-1, 1]. Returns 0 on length mismatch or a zero vector
    /// (degenerate inputs rank last rather than crashing).
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Double = 0, na: Double = 0, nb: Double = 0
        for i in a.indices {
            dot += Double(a[i]) * Double(b[i])
            na += Double(a[i]) * Double(a[i])
            nb += Double(b[i]) * Double(b[i])
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// `[Float]` → little-endian BLOB for sqlite storage, and back.
    static func data(from floats: [Float]) -> Data {
        floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }
    static func floats(from data: Data) -> [Float] {
        var out = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = out.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return out
    }
}
