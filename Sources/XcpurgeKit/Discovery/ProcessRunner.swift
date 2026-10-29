import Foundation

/// Runs a subprocess with a timeout and captures stdout (stderr is discarded).
public enum ProcessRunner {
    public struct Result: Sendable {
        public var status: Int32
        public var stdout: Data
        public var timedOut: Bool
    }

    private final class Box: @unchecked Sendable {
        let process: Process
        init(_ p: Process) { process = p }
    }

    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30,
                           environment: [String: String]? = nil) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let box = Box(process)
        let timer = DispatchWorkItem { if box.process.isRunning { box.process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let timedOut = timer.isCancelled == false && process.terminationReason == .uncaughtSignal
        timer.cancel()
        return Result(status: process.terminationStatus, stdout: data, timedOut: timedOut)
    }

    /// Async wrapper that runs off the cooperative thread pool.
    public static func runAsync(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result_(catching: { try run(executable, arguments, timeout: timeout) }))
            }
        }
    }

    private typealias Result_ = Swift.Result<Result, Error>
}
