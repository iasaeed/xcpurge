import Foundation

/// Asks for confirmation on a terminal; `--yes` skips it. Without a terminal there is nobody to answer, so the
/// process says how to confirm and exits 2 (usage) rather than ending 0 having done nothing.
enum ConfirmPrompt {
    /// - Parameter details: lines listed before an interactive question (what the action will touch).
    static func confirm(_ question: String, details: [String] = [], assumeYes: Bool) -> Bool {
        if assumeYes { return true }
        guard isatty(STDIN_FILENO) != 0 else {
            FileHandle.standardError.write(Data("\(question) Not a terminal; pass --yes to confirm.\n".utf8))
            exit(XcpurgeExit.usage.rawValue)
        }
        for line in details { print("  \(line)") }
        print("\(question) [y/N] ", terminator: "")
        fflush(stdout)
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return answer == "y" || answer == "yes"
    }
}
