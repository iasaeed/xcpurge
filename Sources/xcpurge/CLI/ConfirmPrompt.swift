import Foundation

/// Asks for confirmation on a terminal; `--yes` skips it, and a non-interactive stdin answers no.
enum ConfirmPrompt {
    static func confirm(_ question: String, assumeYes: Bool) -> Bool {
        if assumeYes { return true }
        guard isatty(STDIN_FILENO) != 0 else {
            FileHandle.standardError.write(Data("\(question) Not a terminal; pass --yes to confirm.\n".utf8))
            return false
        }
        print("\(question) [y/N] ", terminator: "")
        fflush(stdout)
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return answer == "y" || answer == "yes"
    }
}
