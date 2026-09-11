import Darwin
import Foundation

/// A socket a browser is listening on.
///
/// The address family is kept rather than collapsed to a port number. Two
/// processes can hold the same port at once, one per family, so a probe that
/// only knows the number can reach the wrong one: with something else on
/// `127.0.0.1:9222` a browser still binds `[::1]:9222`, and asking
/// `127.0.0.1` then reports the other process's browser version and WebSocket
/// URL as this browser's.
public struct ChromeListener: Hashable, Sendable {
    public let port: Int
    public let isIPv6: Bool

    public init(port: Int, isIPv6: Bool) {
        self.port = port
        self.isIPv6 = isIPv6
    }

    /// Loopback in this socket's family. A browser binds loopback for its
    /// debugging port, and a wildcard bind answers there too.
    public var probeHost: String { isIPv6 ? "[::1]" : "127.0.0.1" }
}

/// Which sockets a process is actually listening on.
///
/// A debugging port on the command line is a request, not a fact. The browser
/// may have failed to bind it, and something else entirely may hold it: an
/// Electron app started with its own `--remote-debugging-port`, which this
/// command deliberately does not list, or a forwarded port.
public struct ListeningSockets: Sendable {
    public init() {}

    public func callAsFunction(pid: pid_t) -> Set<ChromeListener> {
        let sized = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard sized > 0 else { return [] }

        let stride = MemoryLayout<proc_fdinfo>.stride
        // Descriptors open and close between the sizing call and this one, so
        // ask for more room than the size just reported.
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(sized) / stride + 32)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
        guard used > 0 else { return [] }

        var listeners: Set<ChromeListener> = []
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
            listeners.insert(ChromeListener(port: Int(port), isIPv6: info.psi.soi_family == AF_INET6))
        }
        return listeners
    }
}
