import Foundation
import XCTest

/// Runs the `xcpurge` executable built alongside the tests.
enum CLISupport {
    static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The `xcpurge` next to this test bundle (whatever the scratch path), else `.build/debug/xcpurge`.
    static var binary: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            let candidate = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("xcpurge")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return packageRoot.appendingPathComponent(".build/debug/xcpurge")
    }

    /// Runs the CLI with stdout and stderr on pipes; skips the test when the binary is not built.
    static func run(_ args: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("\(binary.path) not built; run `swift build` first")
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let errData = LockedData()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData.set(err.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData.get(), as: UTF8.self))
    }

    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ d: Data) { lock.withLock { data = d } }
        func get() -> Data { lock.withLock { data } }
    }
}
