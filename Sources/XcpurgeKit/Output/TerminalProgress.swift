import Foundation

/// Live single-line scan progress for a terminal: redraws one line in place (`\r` + clear to end of line) at
/// most ~10 times a second, ticking the elapsed time while a phase runs, and leaves the summary line behind.
/// Inactive (writes nothing) unless `isTTY` and not `quiet`, so piped or redirected stderr stays clean.
public final class TerminalProgress: ProgressSink, @unchecked Sendable {
    public let isActive: Bool
    private let colors: Bool
    private let width: Int
    private let printsSummary: Bool
    private let write: @Sendable (String) -> Void
    private let start = Date()
    private let interval: TimeInterval = 0.1

    private let lock = NSLock()
    private var current: ScanProgress?
    private var lastDraw = Date.distantPast
    private var drawn = false
    private var stopped = false
    private var timer: DispatchSourceTimer?

    /// - Parameters:
    ///   - isTTY: whether the destination is a terminal (`isatty(STDERR_FILENO)`).
    ///   - colors: dim/green styling (off under `NO_COLOR`); `\r` and clear-to-EOL are used either way.
    ///   - width: terminal columns; lines are cut to fit so they never wrap.
    ///   - printsSummary: leave the summary line when the scan finishes (off when the caller prints it).
    ///   - write: destination, stderr by default.
    public init(isTTY: Bool, quiet: Bool = false, colors: Bool = true, width: Int = 80, printsSummary: Bool = true,
                write: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }) {
        self.isActive = isTTY && !quiet
        self.colors = colors
        self.width = max(20, width)
        self.printsSummary = printsSummary
        self.write = write
        guard isActive else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    deinit { timer?.cancel() }

    public func report(_ event: ScanProgress) {
        guard isActive else { return }
        lock.withLock {
            guard !stopped else { return }
            let phaseChanged = current?.phase != event.phase
            current = event
            if case .finished(let summary) = event {
                stopLocked(summary: printsSummary ? summary : nil)
            } else if phaseChanged || Date().timeIntervalSince(lastDraw) >= interval {
                drawLocked()
            }
        }
    }

    /// Clears the live line (e.g. when the scan failed); idempotent.
    public func stop() {
        guard isActive else { return }
        lock.withLock { stopLocked(summary: nil) }
    }

    private func tick() {
        lock.withLock {
            guard !stopped, current != nil, Date().timeIntervalSince(lastDraw) >= interval * 0.9 else { return }
            drawLocked()
        }
    }

    private func stopLocked(summary: ScanSummary?) {
        guard !stopped else { return }
        stopped = true
        timer?.cancel()
        timer = nil
        var out = drawn ? "\r\u{1B}[K" : ""
        if let summary { out += summary.line + "\n" }
        if !out.isEmpty { write(out) }
    }

    private func drawLocked() {
        guard let current, let text = Self.describe(current, colors: colors) else { return }
        let elapsed = ScanSummary.duration(Date().timeIntervalSince(start))
        let plainLength = Self.visibleLength(text) + elapsed.count + 3
        var line = text
        if plainLength > width - 1 { line = Self.truncate(text, to: max(10, width - elapsed.count - 5)) }
        line += colors ? "  \u{1B}[2m\(elapsed)\u{1B}[0m" : "  \(elapsed)"
        write("\r" + line + "\u{1B}[K")
        lastDraw = Date()
        drawn = true
    }

    /// The live line for a phase (without the elapsed time); nil for `.finished`.
    public static func describe(_ event: ScanProgress, colors: Bool = false) -> String? {
        switch event {
        case .walking(let files):
            return "Walking files… \(ScanSummary.count(files, "file"))"
        case .discovering(let projects, let packages):
            return "Discovering projects… (\(ScanSummary.count(projects, "project")), \(ScanSummary.count(packages, "package")))"
        case .attributing(let modules):
            return "Attributing to modules… \(ScanSummary.count(modules, "module"))"
        case .indexing(let done, let total):
            return "Indexing references… \(ScanSummary.grouped(done))/\(ScanSummary.grouped(total)) files"
        case .detecting(let states):
            let check = colors ? "\u{1B}[32m✓\u{1B}[0m" : "✓"
            return "Running detectors: " + states.map { "\($0.name) \($0.done ? check : "…")" }.joined(separator: " ")
        case .finished:
            return nil
        }
    }

    /// Characters a terminal shows, ignoring SGR escape sequences.
    static func visibleLength(_ s: String) -> Int {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression).count
    }

    /// Cuts to `limit` visible characters (escape sequences are dropped when cutting).
    static func truncate(_ s: String, to limit: Int) -> String {
        let plain = s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        return plain.count <= limit ? s : String(plain.prefix(limit - 1)) + "…"
    }
}
