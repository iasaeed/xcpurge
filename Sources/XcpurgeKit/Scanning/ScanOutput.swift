/// References, dynamic patterns and ignore markers extracted from one file.
public struct ScanOutput: Sendable {
    public var references: [Reference] = []
    public var patterns: [DynamicPattern] = []
    public var ignoredLines: [Int32] = []
    /// Accessor path -> raw resource name, when the file is a SwiftGen / R.swift generated file.
    public var accessors: [String: String] = [:]
    /// True for generated accessor files; their references are not counted as uses.
    public var isGenerated = false
    /// Why the file was not scanned (too large, unreadable); its references are unknown.
    public var skipReason: String?

    public init() {}
}
