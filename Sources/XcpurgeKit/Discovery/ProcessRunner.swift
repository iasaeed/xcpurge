import Darwin
import Foundation

/// Runs a subprocess with a timeout and captures stdout (stderr is discarded). The child leads its own process
/// group, and a timeout or `killAll` kills it with everything it started (`swift package` spawns `swift-frontend`
/// and the compiled manifest). It is registered with `ShellRunner`, which `--verify` interrupts use as well.
public enum ProcessRunner {
    public struct Result: Sendable {
        public var status: Int32
        public var stdout: Data
        public var timedOut: Bool
    }

    /// Set by the timeout timer; read after the run.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    /// Serialises pipe creation and spawning: a pipe end must not leak into a child that another thread starts at the
    /// same moment, or that run would not see end-of-file until the stranger exits (manifests run concurrently).
    private static let spawnLock = NSLock()

    /// Kills every running child and all it started at once (SIGKILL: a manifest evaluation has nothing to clean up).
    public static func killAll() {
        for child in ShellRunner.registry.running { kill(tree: child) }
    }

    /// SIGKILLs the child's group and every descendant: `swift package` runs the compiled manifest in a group of
    /// its own, which `killpg` on the child's group would miss.
    static func kill(tree child: pid_t) {
        let descendants = Self.descendants(of: child)
        killpg(child, SIGKILL)
        for pid in descendants { Darwin.kill(pid, SIGKILL) }
    }

    static func descendants(of root: pid_t) -> [pid_t] {
        var found: [pid_t] = [], queue = [root]
        while let parent = queue.popLast() {
            var pids = [pid_t](repeating: 0, count: 256)
            let n = Int(proc_listchildpids(parent, &pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
            for pid in pids.prefix(max(0, min(n, pids.count))) where pid > 0 {
                found.append(pid)
                queue.append(pid)
            }
        }
        return found
    }

    /// Starts the child in its own group with stdout on a pipe; returns its pid and the pipe's read end.
    private static func start(_ executable: String, _ arguments: [String],
                              environment: [String: String]?) throws -> (child: pid_t, readEnd: Int32) {
        spawnLock.lock()
        defer { spawnLock.unlock() }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let readEnd = fds[0], writeEnd = fds[1]
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

        // Own process group, signals unblocked and at their defaults (xcpurge may be ignoring SIGINT or SIGTERM
        // while it handles an interrupt, and an ignored signal would survive the exec).
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

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { for p in argv { free(p) } }
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { env in env.map { strdup("\($0.key)=\($0.value)") } + [nil] } ?? []
        defer { for p in envp { free(p) } }
        var pid: pid_t = 0
        let rc = environment == nil
            ? posix_spawn(&pid, executable, &actions, &attrs, argv, environ)
            : posix_spawn(&pid, executable, &actions, &attrs, argv, envp)
        close(writeEnd)
        guard rc == 0 else {
            close(readEnd)
            throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EIO)
        }
        ShellRunner.registry.add(pid)
        return (pid, readEnd)
    }

    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30,
                           environment: [String: String]? = nil) throws -> Result {
        let (child, readEnd) = try start(executable, arguments, environment: environment)
        defer { ShellRunner.registry.remove(child) }

        let timedOut = Flag()
        let timer = DispatchWorkItem { timedOut.set(); kill(tree: child) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

        // Until every holder of the pipe is gone: the timer kills the group, so this cannot hang.
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(readEnd, $0.baseAddress, $0.count) }
            if n > 0 { data.append(contentsOf: buffer[0..<n]) } else if n == 0 || errno != EINTR { break }
        }
        close(readEnd)
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0 && errno == EINTR {}
        timer.cancel()
        // Whatever the child left behind in its group dies with the run.
        killpg(child, SIGKILL)
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -(status & 0x7f)
        return Result(status: code, stdout: data, timedOut: timedOut.isSet)
    }

    /// Async wrapper that runs off the cooperative thread pool.
    public static func runAsync(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Swift.Result { try run(executable, arguments, timeout: timeout) })
            }
        }
    }

    /// While manifests are evaluated, SIGINT and SIGTERM kill the child groups before xcpurge itself dies, so an
    /// interrupted scan leaves no `swift-frontend` behind. The signal then takes its default effect.
    public final class InterruptGuard {
        private var sources: [any DispatchSourceSignal] = []
        private var previous: [(signal: Int32, action: sigaction)] = []

        public init() {
            for sig in [SIGINT, SIGTERM] {
                var ignore = sigaction()
                ignore.__sigaction_u.__sa_handler = SIG_IGN
                sigemptyset(&ignore.sa_mask)
                var old = sigaction()
                sigaction(sig, &ignore, &old)
                previous.append((sig, old))
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
                source.setEventHandler {
                    ProcessRunner.killAll()
                    signal(sig, SIG_DFL)
                    raise(sig)
                }
                source.resume()
                sources.append(source)
            }
        }

        public func dispose() {
            for s in sources { s.cancel() }
            sources = []
            for entry in previous {
                var action = entry.action
                sigaction(entry.signal, &action, nil)
            }
            previous = []
        }
    }
}
