// LANE: C
import ArgumentParser

/// `--git` history enrichment flags shared by the scanning commands.
struct GitOptions: ParsableArguments {
    @Flag(help: "Annotate findings with their last commit (author, date, age) from git history.")
    var git = false
    @Flag(help: "With --git: include author emails (names only by default).")
    var gitEmails = false
    @Flag(help: "With --git: guess the commit that removed the last use of each name (heuristic, slower).")
    var gitDeadSince = false
    @Option(help: "With --git: a path added within this many days is 'recently added', otherwise 'leftover'.")
    var gitRecentDays: Int = 30
}
