// LANE: A
/// `.xcpurgeignore` rules and inline `xcpurge:ignore` markers that no longer suppress anything, reported as
/// informational `staleIgnore` findings. Computed from the unfiltered findings (ignores off), see ScanEngine.run.
enum StaleIgnoreDetector {
    static func find(unfiltered: [Finding], context: ScanContext, categories: Set<Category>) -> [Finding] {
        []
    }
}
