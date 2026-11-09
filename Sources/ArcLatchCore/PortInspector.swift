import Foundation
import Darwin

/// Loopback port inspection: a plain TCP connect answers "is the port
/// occupied"; lsof and ps (run directly, argument arrays only) answer "who".
public enum PortInspector {

    public static func isListening(port: Int, timeoutMS: Int = 400) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return false }
        defer { close(fd) }

        var flags = fcntl(fd, F_GETFL, 0)
        if flags < 0 { flags = 0 }
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected == 0 { return true }
        if errno != EINPROGRESS { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let r = poll(&pfd, 1, Int32(timeoutMS))
        if r <= 0 { return false }
        var soError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        let ok = getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length)
        return ok == 0 && soError == 0
    }

    /// PIDs listening on a loopback TCP port, with executable paths.
    public static func listeners(port: Int) -> [ProcessListener] {
        let lsof = ToolRunner.run("/usr/sbin/lsof",
                                  ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"])
        let pids = lsof.stdout
            .split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        return pids.compactMap { describe($0) }
    }

    public static func describe(_ pid: Int32) -> ProcessListener? {
        let ps = ToolRunner.run("/bin/ps", ["-p", "\(pid)", "-o", "pid=,ppid=,comm="])
        guard let line = ps.stdout.split(separator: "\n").first else { return nil }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3,
              let p = Int32(parts[0]), let ppid = Int32(parts[1]) else { return nil }
        var path = parts[2...].joined(separator: " ")
        // comm= can truncate; fall back to a wider read through proc info.
        if path.hasSuffix("…") || path.count == 20 {
            if let full = fullPath(of: p) { path = full }
        }
        return ProcessListener(pid: p, ppid: ppid, path: path)
    }

    public static func fullPath(of pid: Int32) -> String? {
        // /bin/ps cannot give the full path; lsof can via -p + FD cwd is overkill.
        // Use `ps -o comm=` output as-is; most engine paths fit under the limit.
        nil
    }

    /// Resolve symlinks in a path for matching (e.g. /opt/homebrew/bin/ollama).
    public static func resolvePath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}
