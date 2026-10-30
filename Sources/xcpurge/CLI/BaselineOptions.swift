import ArgumentParser

/// `--baseline` and stale-ignore flags shared by the scanning commands (see `xcpurge baseline`).
struct BaselineOptions: ParsableArguments {
    @Option(help: "Hide findings listed in this baseline file and report fixed entries (see `xcpurge baseline`).",
            completion: .file())
    var baseline: String?
    @Flag(help: "Exit 1 when the baseline lists findings that are fixed; regenerate with `xcpurge baseline`.")
    var strictBaseline = false
    @Option(help: "Warn when the baseline is older than this many days (0 = never; default 90).")
    var baselineMaxAge: Int?
    @Flag(help: "Do not report .xcpurgeignore rules and inline markers that suppress nothing.")
    var noStaleIgnore = false
    @Flag(help: "Exit 1 on a stale ignore rule or marker (same as --fail-on stale-ignore).")
    var failOnStaleIgnore = false
}
