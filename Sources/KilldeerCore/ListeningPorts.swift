import Darwin
import Foundation

/// Which TCP ports a process is actually listening on.
///
/// A debugging port on the command line is a request, not a fact. The browser
/// may have failed to bind it, and something else entirely may hold it: an
/// Electron app started with its own `--remote-debugging-port`, which this
/// command deliberately does not list, or a forwarded port. Probing the port
/// alone would then answer for that other process and report its WebSocket URL
/// as this browser's, which is the confusion the command exists to end.
public struct ListeningPorts: Sendable {
    public init() {}

    public func callAsFunction(pid: pid_t) -> Set<Int> {
        let sized = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard sized > 0 else { return [] }

        let stride = MemoryLayout<proc_fdinfo>.stride
        // Descriptors open and close between the sizing call and this one, so
        // ask for more room than the size just reported.
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(sized) / stride + 32)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
        guard used > 0 else { return [] }

        var ports: Set<Int> = []
        for descriptor in descriptors.prefix(Int(used) / stride)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP),
                  info.psi.soi_proto.pri_tcp.tcpsi_state == Int32(TSI_S_LISTEN)
            else { continue }
            // insi_lport is stored in network byte order.
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport))
            ports.insert(Int(port))
        }
        return ports
    }
}
