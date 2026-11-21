import Darwin
import Foundation

public struct HardwareProfile: Equatable, Sendable {
    public var chip: String
    public var totalMemory: UInt64
    public var availableMemory: UInt64
    public var freeDisk: UInt64

    public init(chip: String, totalMemory: UInt64, availableMemory: UInt64, freeDisk: UInt64) {
        self.chip = chip
        self.totalMemory = totalMemory
        self.availableMemory = availableMemory
        self.freeDisk = freeDisk
    }

    public static func availableMemory(_ counts: VMPageCounts) -> UInt64 {
        (counts.free + counts.inactive + counts.speculative + counts.purgeable) * counts.pageSize
    }

    public static func read(diskPath: String = NSHomeDirectory()) -> HardwareProfile {
        HardwareProfile(
            chip: sysctlString("machdep.cpu.brand_string") ?? "Mac",
            totalMemory: sysctlUInt64("hw.memsize") ?? 0,
            availableMemory: vmCounts().map(availableMemory) ?? 0,
            freeDisk: freeDisk(at: diskPath)
        )
    }

    static func freeDisk(at path: String) -> UInt64 {
        var stats = statfs()
        guard statfs(path, &stats) == 0 else { return 0 }
        return UInt64(stats.f_bavail) * UInt64(stats.f_bsize)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    private static func vmCounts() -> VMPageCounts? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return VMPageCounts(
            pageSize: UInt64(getpagesize()), free: UInt64(stats.free_count), active: UInt64(stats.active_count),
            inactive: UInt64(stats.inactive_count), speculative: UInt64(stats.speculative_count),
            wired: UInt64(stats.wire_count), compressor: UInt64(stats.compressor_page_count),
            purgeable: UInt64(stats.purgeable_count), external: UInt64(stats.external_page_count),
            internalPages: UInt64(stats.internal_page_count)
        )
    }
}
