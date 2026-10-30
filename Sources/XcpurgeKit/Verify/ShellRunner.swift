// LANE: C
import Darwin
import Foundation

/// Runs a `--verify` command through `/bin/sh -c` in its own process group, so a timeout (or an interrupt)
/// kills the whole build tree (xcodebuild and its children), with stdout and stderr merged into a capped ring
/// buffer (the last 2 MB). The run ends when the shell exits: children it left behind (`cmd &`) get one second
/// to finish writing, then the group is killed.
public enum ShellRunner {
    public struct Result: Sendable {
        public var status: Int32
        /// Merged stdout + stderr, last `outputCap` bytes at most.
        public var output: String
        public var timedOut: Bool
        /// `interruptAll` fired while this command ran (SIGINT/SIGTERM handling in `VerifyRunner`).
        public var interrupted: Bool

        /// The last `n` lines of the output.
        public func tail(_ n: Int) -> [String] {
            let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var trimmed = lines
            while trimmed.last?.isEmpty == true { trimmed.removeLast() }
            return Array(trimmed.suffix(n))
        }
    }

    public static let outputCap = 2 * 1024 * 1024
    /// Grace between SIGTERM and SIGKILL on timeout or interrupt.
    static let killGrace: TimeInterval = 10
    /// How long children that outlive the shell may keep the pipe open.
    static let drainGrace: TimeInterval = 1

    /// Process groups of the builds running right now, and whether an interrupt was requested.
    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var groups = Set<pid_t>()
        private var interruptedFlag = false
        func add(_ g: pid_t) { lock.withLock { _ = groups.insert(g) } }
        func remove(_ g: pid_t) { lock.withLock { _ = groups.remove(g) } }
        var running: [pid_t] { lock.withLock { Array(groups) } }
        var interrupted: Bool {
            get { lock.withLock { interruptedFlag } }
            set { lock.withLock { interruptedFlag = newValue } }
        }
    }
    private static let registry = Registry()

    /// Called from a signal handler: SIGTERM every running build group (SIGKILL after the grace) and remember
    /// that the current operation was interrupted, so the caller can stop before the next build.
    public static func interruptAll() {
        registry.interrupted = true
        for g in registry.running { terminate(group: g) }
    }

    /// True after `interruptAll` until `clearInterrupt`.
    public static var wasInterrupted: Bool { registry.interrupted }
    public static func clearInterrupt() { registry.interrupted = false }

    static func terminate(group: pid_t) {
        killpg(group, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) { killpg(group, SIGKILL) }
    }

    /// Set by the timeout timer; read after the run.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    /// The shell's exit, reported by the waiter thread.
    private final class Exit: @unchecked Sendable {
        private let lock = NSLock()
        private var statusValue: Int32?
        private var at: Date?
        func set(_ status: Int32) { lock.withLock { statusValue = status; at = Date() } }
        var status: Int32? { lock.withLock { statusValue } }
        var exitedAt: Date? { lock.withLock { at } }
    }

    /// Blocking. A timeout of 0 or less means no limit.
    public static func run(_ command: String, cwd: URL, timeout: TimeInterval) -> Result {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else {
            return Result(status: -1, output: "cannot create pipe: \(String(cString: strerror(errno)))", timedOut: false, interrupted: false)
        }
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

        // Own process group; signals unblocked and at their defaults (xcpurge may be ignoring SIGINT/SIGTERM
        // itself while it verifies, and the child must not inherit that or SIGTERM would never reach it).
        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attrs, &noSignals)
        posix_spawnattr_setsigdefault(&attrs, &allSignals)
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attrs, 0)

        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(command), nil]
        defer { for p in argv { free(p) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/sh", &actions, &attrs, argv, environ)
        close(writeEnd)
        guard rc == 0 else {
            close(readEnd)
            return Result(status: -1, output: "cannot start /bin/sh: \(String(cString: strerror(rc)))", timedOut: false, interrupted: false)
        }
        let child = pid
        registry.add(child)
        defer { registry.remove(child) }

        let timedOut = Flag()
        var timer: DispatchWorkItem?
        if timeout > 0 {
            let item = DispatchWorkItem { timedOut.set(); terminate(group: child) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
            timer = item
        }

        // The shell is reaped on its own thread, so a child that keeps the pipe open cannot hide its exit.
        let exit = Exit()
        let waiter = DispatchGroup()
        waiter.enter()
        DispatchQueue.global().async {
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0 && errno == EINTR {}
            exit.set((status & 0x7f) == 0 ? (status >> 8) & 0xff : -(status & 0x7f))
            waiter.leave()
        }

        var ring = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var sawEOF = false
        while true {
            var fd = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&fd, 1, 200)
            if ready > 0 {
                let n = buffer.withUnsafeMutableBytes { read(readEnd, $0.baseAddress, $0.count) }
                if n > 0 {
                    ring.append(contentsOf: buffer[0..<n])
                    if ring.count > outputCap { ring.removeFirst(ring.count - outputCap) }
                    continue
                }
                if n == 0 || errno != EINTR { sawEOF = true; break }
            } else if ready < 0, errno != EINTR {
                break
            }
            // Shell gone but something still holds the pipe: give it the grace, then kill what is left.
            if let at = exit.exitedAt, Date().timeIntervalSince(at) > drainGrace { break }
        }
        close(readEnd)
        if !sawEOF {
            killpg(child, SIGTERM)
            usleep(100_000)
            killpg(child, SIGKILL)
        }
        waiter.wait()
        timer?.cancel()
        let wasTimeout = timedOut.isSet
        if wasTimeout { killpg(child, SIGKILL) }
        return Result(status: exit.status ?? -1, output: String(decoding: ring, as: UTF8.self), timedOut: wasTimeout,
                      interrupted: registry.interrupted)
    }

    /// `run` off the cooperative thread pool.
    public static func runAsync(_ command: String, cwd: URL, timeout: TimeInterval) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: run(command, cwd: cwd, timeout: timeout)) }
        }
    }
}
