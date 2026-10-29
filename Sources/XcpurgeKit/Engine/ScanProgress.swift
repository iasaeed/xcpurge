import Foundation

/// One step of a scan, reported to a `ProgressSink` while it runs (in pipeline order).
public enum ScanProgress: Sendable, Equatable {
    /// Files inventoried so far.
    case walking(files: Int)
    /// Xcode projects and Swift packages found (then parsed).
    case discovering(projects: Int, packages: Int)
    /// Modules in the graph files are being attributed to.
    case attributing(modules: Int)
    /// Reference sources read so far, out of `total`.
    case indexing(done: Int, total: Int)
    /// Detector names (registry order) with whether each has finished.
    case detecting([DetectorState])
    /// The scan is complete.
    case finished(ScanSummary)

    public struct DetectorState: Sendable, Equatable {
        public var name: String
        public var done: Bool

        public init(name: String, done: Bool) {
            self.name = name
            self.done = done
        }
    }

    /// Phase identity, ignoring counts.
    public var phase: Int {
        switch self {
        case .walking: 0
        case .discovering: 1
        case .attributing: 2
        case .indexing: 3
        case .detecting: 4
        case .finished: 5
        }
    }
}

/// Receives scan progress. Called from any thread, possibly concurrently and often (once per file);
/// implementations throttle their own output.
public protocol ProgressSink: Sendable {
    func report(_ event: ScanProgress)
}

/// The default sink: ignores everything.
public struct NoProgress: ProgressSink {
    public init() {}
    public func report(_ event: ScanProgress) {}
}

/// Totals of a finished scan, and the one-line summary printed after it.
public struct ScanSummary: Sendable, Equatable {
    public var files: Int
    public var modules: Int
    public var seconds: Double
    public var high: Int
    public var medium: Int
    public var low: Int

    public init(files: Int, modules: Int, seconds: Double, high: Int, medium: Int, low: Int) {
        self.files = files
        self.modules = modules
        self.seconds = seconds
        self.high = high
        self.medium = medium
        self.low = low
    }

    /// Totals of `result`; `seconds` defaults to `result.elapsed`.
    public init(_ result: ScanResult, seconds: Double? = nil) {
        let f = result.findings
        self.init(files: result.context.inventory.files.count, modules: result.context.graph.modules.count,
                  seconds: seconds ?? result.elapsed, high: f.filter { $0.confidence == .high }.count,
                  medium: f.filter { $0.confidence == .medium }.count, low: f.filter { $0.confidence == .low }.count)
    }

    public var findings: Int { high + medium + low }

    /// `Scanned 12,480 files in 9 modules in 2.3s — 38 findings (8 high, 30 medium, 0 low)`.
    public var line: String {
        let head = "Scanned \(Self.count(files, "file")) in \(Self.count(modules, "module")) in \(Self.duration(seconds))"
        guard findings > 0 else { return head + " — No findings." }
        return head + " — \(Self.count(findings, "finding")) (\(high) high, \(medium) medium, \(low) low)"
    }

    /// `1 file`, `12,480 files`.
    static func count(_ n: Int, _ noun: String) -> String { "\(grouped(n)) \(noun)\(n == 1 ? "" : "s")" }

    /// Thousands separated by commas, independent of locale.
    public static func grouped(_ n: Int) -> String {
        var digits = String(n.magnitude), out = ""
        while digits.count > 3 {
            out = "," + digits.suffix(3) + out
            digits.removeLast(3)
        }
        return (n < 0 ? "-" : "") + digits + out
    }

    /// `0.4s`, `12.0s`, `1m 05s`.
    public static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let s = Int(seconds.rounded())
        return String(format: "%dm %02ds", s / 60, s % 60)
    }
}
