import Foundation
import os

// sysctl + memory probe per SWIFTUI-SPEC.md §12.4 / ADR 0005.
// Written once on first launch to ~/Library/Application Support/Localpen/hardware.json.
// Phase 2 auto-pick reads this; Phase 1 just collects.
enum HardwareFingerprint {
    struct Snapshot: Codable {
        let hwModel: String
        let hwMachine: String
        let physicalMemoryBytes: UInt64
        let freeDiskBytes: Int64
        let collectedAt: Date
    }

    static let log = Logger(subsystem: "app.localpen.Localpen", category: "Hardware")

    static func collectAndPersistIfNeeded() {
        let path = persistencePath()
        if FileManager.default.fileExists(atPath: path.path) { return }
        let snap = collect()
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder.iso8601.encode(snap) {
            try? data.write(to: path)
            log.info("hardware fingerprint written")
        }
    }

    static func collect() -> Snapshot {
        Snapshot(
            hwModel: sysctlString("hw.model"),
            hwMachine: sysctlString("hw.machine"),
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            freeDiskBytes: freeDiskBytes(),
            collectedAt: Date()
        )
    }

    private static func persistencePath() -> URL {
        ((try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("Localpen/hardware.json")
    }

    private static func sysctlString(_ name: String) -> String {
        var size: size_t = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }

    private static func freeDiskBytes() -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let size = attrs[.systemFreeSize] as? NSNumber else { return 0 }
        return size.int64Value
    }
}

extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
