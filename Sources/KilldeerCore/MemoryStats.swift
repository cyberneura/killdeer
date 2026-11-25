import Darwin
import Foundation

/// The kernel's page counters that memory use is worked out from.
public struct VMPageCounts: Equatable, Sendable {
    public var active: UInt64
    public var inactive: UInt64
    public var speculative: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var purgeable: UInt64
    /// File-backed pages: the file cache.
    public var external: UInt64

    public init(
        active: UInt64 = 0, inactive: UInt64 = 0, speculative: UInt64 = 0, wired: UInt64 = 0,
        compressed: UInt64 = 0, purgeable: UInt64 = 0, external: UInt64 = 0
    ) {
        self.active = active
        self.inactive = inactive
        self.speculative = speculative
        self.wired = wired
        self.compressed = compressed
        self.purgeable = purgeable
        self.external = external
    }

    /// App memory, wired and compressed pages: what Activity Monitor adds up
    /// as "Memory Used". The file cache and purgeable pages are inside the
    /// active and inactive counts but can be handed back the moment something
    /// asks, so counting them would show a Mac that has merely read a lot of
    /// files as full.
    public var usedPages: UInt64 {
        let held = active + inactive + speculative + wired + compressed
        let reclaimable = purgeable + external
        return held > reclaimable ? held - reclaimable : 0
    }
}

/// How much of the RAM is in use.
public struct MemoryUsage: Equatable, Sendable {
    public let usedBytes: UInt64
    public let totalBytes: UInt64

    public init(usedBytes: UInt64, totalBytes: UInt64) {
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
    }

    public init(pages: VMPageCounts, pageSize: UInt64, totalBytes: UInt64) {
        self.init(usedBytes: pages.usedPages * pageSize, totalBytes: totalBytes)
    }

    /// 0 to 100.
    public var percent: Double {
        guard totalBytes > 0 else { return 0 }
        return min(100, Double(usedBytes) / Double(totalBytes) * 100)
    }
}

/// How much has been pushed out to the swap files.
public struct SwapUsage: Equatable, Sendable {
    public let usedBytes: UInt64
    /// What the swap files on disk add up to now. Not a limit: macOS adds
    /// files as they fill.
    public let allocatedBytes: UInt64
    public let physicalMemoryBytes: UInt64

    public init(usedBytes: UInt64, allocatedBytes: UInt64, physicalMemoryBytes: UInt64) {
        self.usedBytes = usedBytes
        self.allocatedBytes = allocatedBytes
        self.physicalMemoryBytes = physicalMemoryBytes
    }

    /// Swap in use against the size of the RAM, 0 to 100.
    ///
    /// Not against `allocatedBytes`, which is the usual meaning of a usage
    /// rate: macOS grows the swap files as they fill, so that ratio sits near
    /// the top whenever there is any swap at all and drops at the moment more
    /// is allocated, which is when things got worse. Against the RAM the
    /// figure rises and falls with the amount swapped out, and a Mac that has
    /// swapped out as much as it has memory is at the top of the scale.
    public var percentOfMemory: Double {
        guard physicalMemoryBytes > 0 else { return 0 }
        return min(100, Double(usedBytes) / Double(physicalMemoryBytes) * 100)
    }
}

public enum MemoryStats {
    /// Memory use as the kernel has it now.
    public static func sampleMemory() -> MemoryUsage? {
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else { return nil }

        // Balanced for the reason given in CPULoad.sample.
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }

        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS, pageSize > 0 else { return nil }

        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride
            / MemoryLayout<integer_t>.stride)
        var info = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let pages = VMPageCounts(
            active: UInt64(info.active_count),
            inactive: UInt64(info.inactive_count),
            speculative: UInt64(info.speculative_count),
            wired: UInt64(info.wire_count),
            compressed: UInt64(info.compressor_page_count),
            purgeable: UInt64(info.purgeable_count),
            external: UInt64(info.external_page_count)
        )
        return MemoryUsage(pages: pages, pageSize: UInt64(pageSize), totalBytes: total)
    }

    /// Swap use as the kernel has it now.
    public static func sampleSwap() -> SwapUsage? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return SwapUsage(
            usedBytes: usage.xsu_used,
            allocatedBytes: usage.xsu_total,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
    }
}
