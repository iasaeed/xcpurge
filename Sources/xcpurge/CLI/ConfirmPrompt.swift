import Foundation

/// Asks for confirmation on a terminal; `--yes` skips it. Without a terminal there is nobody to answer: the caller
/// finishes its read-only work (writes the report) and then exits 2 via `Answer.exitIfNotATerminal`, so a
/// non-interactive run never ends 0 having silently done nothing.
enum ConfirmPrompt {
    enum Answer: Equatable {
        case yes, no
        /// stdin is not a terminal and `--yes` was not given; stderr already says how to confirm.
        case notATerminal

        /// Exit 2 (usage) for `.notATerminal`; call it after the declined path has written its report.
        func exitIfNotATerminal() throws {
            if self == .notATerminal { throw XcpurgeExit.usage.exitCode }
        }
    }

    /// - Parameter details: lines listed before an interactive question (what the action will touch).
    static func confirm(_ question: String, details: [String] = [], assumeYes: Bool) -> Answer {
        if assumeYes { return .yes }
        guard isatty(STDIN_FILENO) != 0 else {
            FileHandle.standardError.write(Data("\(question) Not a terminal; pass --yes to confirm.\n".utf8))
            return .notATerminal
        }
        for line in details { print("  \(line)") }
        print("\(question) [y/N] ", terminator: "")
        fflush(stdout)
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return answer == "y" || answer == "yes" ? .yes : .no
    }
}
