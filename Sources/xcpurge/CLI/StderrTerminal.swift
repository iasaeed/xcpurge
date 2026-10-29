import Foundation

/// What stderr is attached to: live progress needs a terminal, colors honour `NO_COLOR`.
enum StderrTerminal {
    /// A terminal that understands `\r` and clear-to-end-of-line (not `TERM=dumb`).
    static var isTTY: Bool {
        isatty(STDERR_FILENO) != 0 && ProcessInfo.processInfo.environment["TERM"] != "dumb"
    }

    static var colors: Bool { ProcessInfo.processInfo.environment["NO_COLOR"] == nil }

    /// Columns of the terminal, else `$COLUMNS`, else 80.
    static var width: Int {
        var size = winsize()
        if ioctl(STDERR_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 { return Int(size.ws_col) }
        return ProcessInfo.processInfo.environment["COLUMNS"].flatMap(Int.init) ?? 80
    }
}
