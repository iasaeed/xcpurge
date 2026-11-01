/// References, dynamic patterns and ignore markers extracted from one file.
public struct ScanOutput: Sendable {
    public var references: [Reference] = []
    public var patterns: [DynamicPattern] = []
    public var ignoredLines: [Int32] = []
    /// `xcpurge:ignore` comments of Swift/ObjC sources (generic text files never fill this: their match is a raw substring).
    public var ignoreMarkers: [IgnoreMarker] = []
    /// Accessor path -> raw resource name, when the file is a SwiftGen / R.swift generated file.
    public var accessors: [String: String] = [:]
    /// True for generated accessor files; their references are not counted as uses.
    public var isGenerated = false
    /// Swift only: index into `references` of a string literal -> the outermost `var`/`let`/`func` whose body holds it.
    public var enclosingDeclarations: [Int: String] = [:]
    /// Swift only: how often each outermost `var`/`let`/`func` name is declared in the file.
    public var declarationCounts: [String: Int] = [:]
    /// Why the file was not scanned (too large, unreadable); its references are unknown.
    public var skipReason: String?

    public init() {}
}
