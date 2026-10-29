import Foundation

/// Asks for confirmation on a terminal; `--yes` skips it, and a non-interactive stdin answers no.
enum ConfirmPrompt {
    /// - Parameter details: lines listed before an interactive question (what the action will touch).
    static func confirm(_ question: String, details: [String] = [], assumeYes: Bool) -> Bool {
        if assumeYes { return true }
        guard isatty(STDIN_FILENO) != 0 else {
            FileHandle.standardError.write(Data("\(question) Not a terminal; pass --yes to confirm.\n".utf8))
            return false
        }
        for line in details { print("  \(line)") }
        print("\(question) [y/N] ", terminator: "")
        fflush(stdout)
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return answer == "y" || answer == "yes"
    }
}
