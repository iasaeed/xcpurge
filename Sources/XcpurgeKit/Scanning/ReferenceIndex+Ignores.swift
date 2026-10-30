// LANE: A
extension ReferenceIndex {
    /// The same index with every `xcpurge:ignore` line forgotten, for the detector pass that decides which
    /// markers still suppress something (`StaleIgnoreDetector`). References, patterns and markers are unchanged.
    func withoutIgnores() -> ReferenceIndex {
        var copy = self
        copy.ignoredLines = []
        return copy
    }

    /// True when some Swift/ObjC source carries a `//`-style marker: the only kind that can be reported as stale.
    var hasLineStyleMarkers: Bool {
        ignoreMarkers.values.contains { $0.contains { $0.style == .line } }
    }
}
