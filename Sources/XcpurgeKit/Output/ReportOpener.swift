import Foundation

/// Opens a written report with `/usr/bin/open`, optionally in a named browser (`open -a <app>`).
public enum ReportOpener {
    /// Arguments passed to `/usr/bin/open`.
    public static func arguments(file: URL, browser: String?) -> [String] {
        if let browser, !browser.isEmpty { return ["-a", browser, file.path] }
        return [file.path]
    }

    /// Launches `open` and waits for it; throws when it exits non-zero (e.g. unknown browser).
    public static func open(_ file: URL, browser: String? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments(file: file, browser: browser)
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw XcpurgeError.invalidConfig("open \(process.arguments!.joined(separator: " ")) exited \(process.terminationStatus)")
        }
    }
}
