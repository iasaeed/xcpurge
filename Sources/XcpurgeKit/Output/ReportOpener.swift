import Foundation

/// Opens a written report with `/usr/bin/open`, optionally in a named browser (`open -a <app>`), falling back to
/// the default browser when that app cannot be used. Never throws: the outcome says what happened.
public enum ReportOpener {
    /// What `open` did, with its error output when it failed.
    public enum Outcome: Sendable, Equatable {
        /// Opened in `app`, or in the default browser when nil.
        case opened(app: String?)
        /// `app` could not be used (`reason`: open's message); the default browser opened the report instead.
        case fellBack(app: String, reason: String)
        /// Nothing opened; `message` is open's error output and exit status.
        case failed(message: String)

        /// One line for stderr; `path` goes into the manual command when nothing opened.
        public func describe(path: String) -> String {
            switch self {
            case .opened(let app?): return "Opened in \(app)"
            case .opened(nil): return "Opened in default browser"
            case .fellBack(let app, let reason):
                if reason.contains("Unable to find application") {
                    return "WARNING: \(app) not found; opened in default browser instead"
                }
                return "WARNING: could not open in \(app) (\(reason)); opened in default browser instead"
            case .failed(let message):
                return "WARNING: could not open the report: \(message)\n  Open it manually: open \"\(path)\""
            }
        }
    }

    /// Runs `/usr/bin/open` with the given arguments and returns its exit status and stderr.
    public typealias Runner = @Sendable (_ arguments: [String]) -> (status: Int32, stderr: String)

    /// Arguments passed to `/usr/bin/open`.
    public static func arguments(file: URL, browser: String?) -> [String] {
        if let browser, !browser.isEmpty { return ["-a", browser, file.path] }
        return [file.path]
    }

    /// Opens `file` in `browser` (or the default browser), falling back to the default browser when `browser`
    /// fails.
    public static func open(_ file: URL, browser: String? = nil, run: Runner = runOpen) -> Outcome {
        let first = run(arguments(file: file, browser: browser))
        guard first.status != 0 else { return .opened(app: browser?.isEmpty == false ? browser : nil) }
        let firstError = describe(first)
        guard let browser, !browser.isEmpty else { return .failed(message: firstError) }
        let fallback = run(arguments(file: file, browser: nil))
        guard fallback.status == 0 else {
            return .failed(message: "\(firstError); default browser: \(describe(fallback))")
        }
        return .fellBack(app: browser, reason: first.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func describe(_ r: (status: Int32, stderr: String)) -> String {
        let text = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text.isEmpty ? "" : text + " ") + "(open exited \(r.status))"
    }

    /// The real runner: `/usr/bin/open`, stdout discarded, stderr captured.
    public static let runOpen: Runner = { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        let err = Pipe()
        process.standardError = err
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { return (127, "cannot run /usr/bin/open: \(error)") }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
