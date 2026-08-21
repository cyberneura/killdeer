import AppKit
import Darwin
import Foundation

public struct ProcessEnumerator: Sendable {
    public init() {}

    public func snapshots() throws -> [ProcessSnapshot] {
        let processes = try kernelProcesses()
        let appNames = Dictionary(
            uniqueKeysWithValues: NSWorkspace.shared.runningApplications.compactMap { app in
                app.localizedName.map { (app.processIdentifier, $0) }
            }
        )

        return processes.compactMap { entry -> ProcessSnapshot? in
            let pid = entry.kp_proc.p_pid
            guard pid > 0, let details = details(for: pid) else { return nil }
            let name = appNames[pid] ?? processName(pid: pid) ?? details.arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "(unknown)"
            return ProcessSnapshot(
                identity: ProcessIdentity(pid: pid, startTime: details.startTime),
                parentPID: entry.kp_eproc.e_ppid,
                name: name,
                arguments: details.arguments,
                totalCPUTimeNanoseconds: details.cpuNanoseconds
            )
        }
    }

    public func identity(for pid: pid_t) -> ProcessIdentity? {
        details(for: pid).map { ProcessIdentity(pid: pid, startTime: $0.startTime) }
    }

    private func kernelProcesses() throws -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else {
            throw KilldeerError.sysctlFailed("process list sizing", errno)
        }

        // Processes can appear between calls, so leave growth room and retry ENOMEM.
        for _ in 0..<3 {
            var entries = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 32)
            var byteCount = entries.count * MemoryLayout<kinfo_proc>.stride
            let result = entries.withUnsafeMutableBytes { bytes in
                sysctl(&mib, u_int(mib.count), bytes.baseAddress, &byteCount, nil, 0)
            }
            if result == 0 {
                entries.removeSubrange(byteCount / MemoryLayout<kinfo_proc>.stride..<entries.count)
                return entries
            }
            guard errno == ENOMEM else { throw KilldeerError.sysctlFailed("process list", errno) }
            size = byteCount + 32 * MemoryLayout<kinfo_proc>.stride
        }
        throw KilldeerError.sysctlFailed("process list", ENOMEM)
    }

    private func details(for pid: pid_t) -> (startTime: Date, cpuNanoseconds: UInt64, arguments: [String])? {
        var bsd = proc_bsdinfo()
        let bsdSize = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(bsdSize)) == Int32(bsdSize) else { return nil }

        var task = proc_taskinfo()
        let taskSize = MemoryLayout<proc_taskinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(taskSize)) == Int32(taskSize) else { return nil }

        let start = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000)
        let cpu = task.pti_total_user &+ task.pti_total_system
        return (start, cpu, processArguments(pid: pid))
    }

    private func processName(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private func processArguments(pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var data = [UInt8](repeating: 0, count: size)
        let result = data.withUnsafeMutableBytes { bytes in
            sysctl(&mib, u_int(mib.count), bytes.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return [] }
        data.removeSubrange(size..<data.count)

        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return [] }
        var index = MemoryLayout<Int32>.size
        while index < data.count, data[index] != 0 { index += 1 } // executable path
        while index < data.count, data[index] == 0 { index += 1 }

        var args: [String] = []
        while index < data.count, args.count < Int(argc) {
            let end = data[index...].firstIndex(of: 0) ?? data.endIndex
            if end > index, let value = String(bytes: data[index..<end], encoding: .utf8) { args.append(value) }
            index = end == data.endIndex ? end : end + 1
        }
        return args
    }
}
