import Foundation

// sysctl + memory + free-disk probe per SWIFTUI-SPEC.md §12.4 / ADR 0005.
// Phase 1 only consumes `freeDiskBytes` (the model-download disk-full
// pre-check); the other fields exist for Phase 2 hardware-aware auto-pick.
enum HardwareFingerprint {
    struct Snapshot: Codable {
        let hwModel: String
        let hwMachine: String
        let physicalMemoryBytes: UInt64
        let freeDiskBytes: Int64
        let collectedAt: Date
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
