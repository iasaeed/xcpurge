// LANE: C
import Darwin
import Foundation

/// Runs a `--verify` command through `/bin/sh -c` in its own process group, so a timeout kills the whole build
/// tree (xcodebuild and its children), with stdout and stderr merged into a capped ring buffer (the last 2 MB).
public enum ShellRunner {
    public struct Result: Sendable {
        public var status: Int32
        /// Merged stdout + stderr, last `outputCap` bytes at most.
        public var output: String
        public var timedOut: Bool

        /// The last `n` lines of the output.
        public func tail(_ n: Int) -> [String] {
            let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var trimmed = lines
            while trimmed.last?.isEmpty == true { trimmed.removeLast() }
            return Array(trimmed.suffix(n))
        }
    }

    public static let outputCap = 2 * 1024 * 1024
    /// Grace between SIGTERM and SIGKILL on timeout.
    static let killGrace: TimeInterval = 10

    private final class Killer: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        let pgid: pid_t
        init(pgid: pid_t) { self.pgid = pgid }
        func fire() {
            lock.withLock { fired = true }
            killpg(pgid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) { [pgid] in
                killpg(pgid, SIGKILL)
            }
        }
        var didFire: Bool { lock.withLock { fired } }
    }

    /// Blocking. A timeout of 0 or less means no limit.
    public static func run(_ command: String, cwd: URL, timeout: TimeInterval) -> Result {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return Result(status: -1, output: "cannot create pipe: \(String(cString: strerror(errno)))", timedOut: false) }
        let readEnd = fds[0], writeEnd = fds[1]

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, readEnd)
        posix_spawn_file_actions_addclose(&actions, writeEnd)
        posix_spawn_file_actions_addchdir_np(&actions, cwd.path)

        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attrs, 0)

        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(command), nil]
        defer { for p in argv { free(p) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/sh", &actions, &attrs, argv, environ)
        close(writeEnd)
        guard rc == 0 else {
            close(readEnd)
            return Result(status: -1, output: "cannot start /bin/sh: \(String(cString: strerror(rc)))", timedOut: false)
        }

        let killer = Killer(pgid: pid)
        var timer: DispatchWorkItem?
        if timeout > 0 {
            let item = DispatchWorkItem { killer.fire() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
            timer = item
        }

        var ring = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(readEnd, $0.baseAddress, $0.count) }
            if n > 0 {
                ring.append(contentsOf: buffer[0..<n])
                if ring.count > outputCap { ring.removeFirst(ring.count - outputCap) }
            } else if n == 0 || errno != EINTR {
                break
            }
        }
        close(readEnd)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        timer?.cancel()
        let timedOut = killer.didFire
        // Children that survived SIGTERM get SIGKILL anyway; nothing of ours is left in the group.
        if timedOut { killpg(pid, SIGKILL) }
        let exit: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -(status & 0x7f)
        return Result(status: exit, output: String(decoding: ring, as: UTF8.self), timedOut: timedOut)
    }

    /// `run` off the cooperative thread pool.
    public static func runAsync(_ command: String, cwd: URL, timeout: TimeInterval) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: run(command, cwd: cwd, timeout: timeout)) }
        }
    }
}
