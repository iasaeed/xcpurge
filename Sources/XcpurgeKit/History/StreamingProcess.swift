// LANE: C
import Foundation

/// Runs a subprocess and hands its stdout to a callback chunk by chunk, so a long `git log` can be stopped as
/// soon as the caller has what it needs. stderr is collected (capped) for diagnostics. Blocking: call it off the
/// cooperative pool (`runAsync`).
public enum StreamingProcess {
    public struct Outcome: Sendable {
        public var status: Int32
        /// The callback asked to stop (the process was terminated); `status` is then meaningless.
        public var stoppedEarly: Bool
        public var timedOut: Bool
        /// Last bytes of stderr (at most `stderrCap`).
        public var stderr: String
    }

    static let stderrCap = 64 * 1024

    /// Lets the timeout closure reach the process; `killed` is only written by that closure.
    private final class Box: @unchecked Sendable {
        let process: Process
        let stderrHandle: FileHandle
        private let lock = NSLock()
        private var killedFlag = false
        private var stderrData = Data()
        init(_ p: Process, stderr: FileHandle) { process = p; stderrHandle = stderr }
        var killed: Bool {
            get { lock.withLock { killedFlag } }
            set { lock.withLock { killedFlag = newValue } }
        }
        func appendStderr(_ d: Data) {
            lock.withLock {
                stderrData.append(d)
                if stderrData.count > stderrCap { stderrData.removeFirst(stderrData.count - stderrCap) }
            }
        }
        var stderr: Data { lock.withLock { stderrData } }
    }

    /// - Parameters:
    ///   - onStdout: receives each chunk; return false to stop the process (SIGTERM) and return early.
    ///   - timeout: nil means no limit.
    public static func run(_ executable: String, _ arguments: [String], currentDirectory: URL? = nil,
                           environment: [String: String]? = nil, timeout: TimeInterval? = nil,
                           onStdout: (Data) -> Bool) throws -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        if let environment { process.environment = environment }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let box = Box(process, stderr: err.fileHandleForReading)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            let handle = box.stderrHandle
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                box.appendStderr(chunk)
            }
            group.leave()
        }
        var timer: DispatchWorkItem?
        if let timeout {
            let item = DispatchWorkItem {
                if box.process.isRunning { box.killed = true; box.process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
            timer = item
        }
        var stopped = false
        let reader = out.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            if stopped { continue }   // drain to EOF so the child can exit
            if !onStdout(chunk) {
                stopped = true
                if process.isRunning { process.terminate() }
            }
        }
        process.waitUntilExit()
        group.wait()
        timer?.cancel()
        return Outcome(status: process.terminationStatus, stoppedEarly: stopped, timedOut: box.killed,
                       stderr: String(decoding: box.stderr, as: UTF8.self))
    }

    /// Buffers all of stdout (for short commands such as `rev-parse`).
    public static func capture(_ executable: String, _ arguments: [String], currentDirectory: URL? = nil,
                               timeout: TimeInterval? = nil) throws -> (outcome: Outcome, stdout: Data) {
        var data = Data()
        let outcome = try run(executable, arguments, currentDirectory: currentDirectory, timeout: timeout) { chunk in
            data.append(chunk)
            return true
        }
        return (outcome, data)
    }

    /// `run` off the cooperative thread pool.
    public static func runAsync(_ executable: String, _ arguments: [String], currentDirectory: URL? = nil,
                                timeout: TimeInterval? = nil,
                                onStdout: @escaping @Sendable (Data) -> Bool) async throws -> Outcome {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Swift.Result {
                    try run(executable, arguments, currentDirectory: currentDirectory, timeout: timeout, onStdout: onStdout)
                })
            }
        }
    }
}
