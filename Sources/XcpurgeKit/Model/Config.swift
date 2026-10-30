import Foundation

/// Scan options. Loaded from `xcpurge.json`, then overridden by command-line flags.
public struct Config: Codable, Sendable, Equatable {
    public var project: String?
    public var workspace: String?
    public var package: String?
    /// Restrict findings to these module names (empty = all).
    public var targets: [String] = []
    public var format: String?
    public var failOn: [String] = []
    public var minConfidence: Confidence = .low
    public var exclude: [String] = []
    public var derivedData: String?
    public var includePods = false
    public var ignoreTestReferences = false
    public var retainPublic = false
    public var noSwift = false
    public var verbose = false
    /// Extra function names treated as localization calls (e.g. `L`, `tr`).
    public var localizationMacros: [String] = []
    /// Baseline file whose findings are hidden (`--baseline`); see `xcpurge baseline`.
    public var baseline: String?
    /// Warn when the baseline is older than this many days (0 = never).
    public var baselineMaxAgeDays = 90
    /// Report `.xcpurgeignore` rules and inline markers that suppress nothing (`--no-stale-ignore` turns it off).
    public var staleIgnores = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case project, workspace, package, targets, format, failOn, minConfidence, exclude, derivedData,
             includePods, ignoreTestReferences, retainPublic, noSwift, verbose, localizationMacros,
             baseline, baselineMaxAgeDays, staleIgnores
    }

    /// Tolerant decoding: every key optional, unknown keys ignored.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        project = try c.decodeIfPresent(String.self, forKey: .project)
        workspace = try c.decodeIfPresent(String.self, forKey: .workspace)
        package = try c.decodeIfPresent(String.self, forKey: .package)
        targets = try c.decodeIfPresent([String].self, forKey: .targets) ?? []
        format = try c.decodeIfPresent(String.self, forKey: .format)
        failOn = try c.decodeIfPresent([String].self, forKey: .failOn) ?? []
        minConfidence = try c.decodeIfPresent(Confidence.self, forKey: .minConfidence) ?? .low
        exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
        derivedData = try c.decodeIfPresent(String.self, forKey: .derivedData)
        includePods = try c.decodeIfPresent(Bool.self, forKey: .includePods) ?? false
        ignoreTestReferences = try c.decodeIfPresent(Bool.self, forKey: .ignoreTestReferences) ?? false
        retainPublic = try c.decodeIfPresent(Bool.self, forKey: .retainPublic) ?? false
        noSwift = try c.decodeIfPresent(Bool.self, forKey: .noSwift) ?? false
        verbose = try c.decodeIfPresent(Bool.self, forKey: .verbose) ?? false
        localizationMacros = try c.decodeIfPresent([String].self, forKey: .localizationMacros) ?? []
        baseline = try c.decodeIfPresent(String.self, forKey: .baseline)
        baselineMaxAgeDays = try c.decodeIfPresent(Int.self, forKey: .baselineMaxAgeDays) ?? 90
        staleIgnores = try c.decodeIfPresent(Bool.self, forKey: .staleIgnores) ?? true
    }

    public static let fileName = "xcpurge.json"

    /// Loads `url`, or returns defaults when the file does not exist.
    public static func load(from url: URL) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        return try decoder.decode(Config.self, from: data)
    }

    /// Starter `xcpurge.json` written by `xcpurge init`.
    public static let template = """
    {
      "targets": [],
      // Globs whose files are never reported. They are still read as references, so excluding
      // generated code (SwiftGen, R.swift) is safe but not needed: generated accessors are detected.
      "exclude": ["Vendor/**"],
      "minConfidence": "medium",
      "failOn": [],
      "ignoreTestReferences": false,
      "retainPublic": false,
      "localizationMacros": []
    }

    """
}
