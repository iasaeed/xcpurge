import ArgumentParser
import Foundation
import XcpurgeKit

/// `xcpurge purge`: one command for what `assets --delete`, `files --delete` and `strings --prune` do separately.
/// Scans every category, picks the actionable findings (filtered by `--only` and `--ids`), asks once, then moves
/// unused assets and files to the trash and prunes unused strings, all in one trash session.
struct PurgeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "purge",
        abstract: "Remove every actionable finding (assets, files, strings) in one go; undo with `xcpurge restore`.",
        discussion: """
            Unused assets and files are moved to .xcpurge-trash (their project references dropped); unused strings \
            are pruned from their tables (originals backed up in the same trash session). Only high-confidence \
            findings are acted on unless --min-confidence is given; --ids acts on exactly the listed findings, \
            whatever their confidence. Dead source, ghost references, duplicates and informational findings are \
            never acted on. --verify build-checks the files moved to the trash, not the pruned strings. \
            Undo with `xcpurge restore`.
            """)

    /// The categories purge acts on, in the order they are listed and acted on.
    static let categories: [XcpurgeKit.Category] = [.assets, .files, .strings]

    /// The finding kinds purge acts on: what `Trash` moves plus the string kinds `PruneStrings` removes. Dead
    /// source, ghost references, duplicates and informational findings are only reported.
    static let purgeableKinds: Set<FindingKind> = Trash.deletableKinds.union([.unusedString, .staleString])

    @OptionGroup var options: CommonOptions
    @Option(parsing: .singleValue,
            help: "Act only on findings matching this rule: assets, strings, files, unused-<category>, or a kind (orphan-file). Repeatable; commas allowed.")
    var only: [String] = []
    @Option(parsing: .singleValue,
            help: "Act only on the findings with these ids (from the report), whatever their confidence. Repeatable; commas allowed.")
    var ids: [String] = []
    @Flag(name: .shortAndLong, help: "Do not ask for confirmation.") var yes = false
    @Flag(help: "List what would be removed and print the report; change nothing.") var dryRun = false
    @OptionGroup var verifyOptions: VerifyOptions

    /// `--only` values with commas split out.
    var onlyRules: [String] { Self.splitList(only) }
    /// `--ids` values with commas split out.
    var idList: [String] { Self.splitList(ids) }

    static func splitList(_ values: [String]) -> [String] {
        values.flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func validate() throws {
        for rule in onlyRules {
            if rule == "any" { throw ValidationError("--only any is the default; omit it") }
            guard FailOn.isKnown(rule) else { throw ValidationError("unknown --only value \(rule)") }
            let category = FailOn.category(rule)
            let kind = FindingKind.allCases.first { $0.flagName == rule }
            if let category, !Self.categories.contains(category) {
                throw ValidationError("--only \(rule): purge never acts on \(category.rawValue) findings")
            }
            if let kind, !Self.purgeableKinds.contains(kind) {
                throw ValidationError("--only \(rule): purge never acts on \(rule) findings")
            }
        }
    }

    func run() async throws {
        let scanned = Set(XcpurgeKit.Category.scannable)
        // `--ids` names findings explicitly, whatever their confidence: scan at low so a confidence floor
        // (`--min-confidence` or `minConfidence` in xcpurge.json) cannot hide them. The report keeps that floor.
        let floor = try options.makeConfig().minConfidence
        var scanOptions = options
        if !idList.isEmpty { scanOptions.minConfidence = .low }
        // Gates (baseline, --git) are applied here so the ungated result is at hand: `size-before.json` must count
        // every finding, like the ungated rescan behind `size-after.json`.
        let ungated = try await ScanRunner.scan(scanOptions, categories: scanned, applyGates: false)
        var result = try BaselineGate.apply(ungated, options: scanOptions, categories: scanned)
        result = await HistoryStep.enrich(result, options: options.gitOptions, quiet: options.quiet)

        let pending = select(from: result)
        if !idList.isEmpty {
            let picked = Set(pending)
            result = ScanResult(context: result.context,
                                findings: result.findings.filter { $0.confidence >= floor || picked.contains($0) },
                                elapsed: result.elapsed, baseline: result.baseline)
        }
        let toTrash = VerifyStep.dropBlocked(pending.filter { $0.category != .strings }, root: result.context.root)
        let toPrune = pending.filter { $0.category == .strings }
        let acting = toTrash + toPrune
        guard !acting.isEmpty else {
            try ScanRunner.report(result, options)
            try ScanRunner.exitIfFailOn(result)
            return
        }
        if verifyOptions.enabled, !toPrune.isEmpty {
            ScanRunner.stderr("warning: --verify checks files moved to the trash only; \(toPrune.count) string key(s) "
                + "are pruned without a build check" + (toTrash.isEmpty ? " and no build runs" : "") + "\n")
        }

        let summary = Self.summary(trash: toTrash.count, prune: toPrune.count)
        let details = Self.groupedDetails(acting)
        if dryRun {
            let lines = details.map { "  \($0)\n" } + ["Dry run: would \(summary); nothing was changed.\n"]
            ScanRunner.stderr(lines.joined())
            try ScanRunner.report(result, options)
            try ScanRunner.exitIfFailOn(result)
            return
        }
        let question = summary.prefix(1).uppercased() + summary.dropFirst() + "?"
        let answer = ConfirmPrompt.confirm(question, details: details, assumeYes: yes)
        guard answer == .yes else {
            try ScanRunner.report(result, options)
            return try answer.exitIfNotATerminal()
        }

        if !toTrash.isEmpty { try VerifyStep.preflight(verifyOptions, root: result.context.root, quiet: options.quiet) }
        let sizeBefore = SizeMeasurer.snapshot(ungated, categories: scanned)
        let store = try TrashStore.begin(root: result.context.root)
        var trashed = ActionReport(), pruned = ActionReport()
        if !toTrash.isEmpty {
            trashed = try Trash(store: store).apply(toTrash, context: result.context)
            trashed = try VerifyStep.verify(verifyOptions, store: store, context: result.context, action: trashed, quiet: options.quiet)
            // The session ID goes out first: pruning, writing or opening the report may still fail.
            ScanRunner.printAction(trashed, verb: "trashed", session: store.sessionID)
        }
        // Strings are pruned after the verify step: it bisects moved paths only, and an aborted verify restores
        // the whole session, so pruning first would have the abort undo the pruned strings too.
        if !toPrune.isEmpty {
            do {
                pruned = try PruneStrings(store: store).apply(toPrune, context: result.context)
            } catch {
                // Some tables may already be rewritten (their originals are in the session). Say how to undo,
                // write the report for what was trashed, then fail with the prune error.
                var text = "error: pruning strings failed: \(error.localizedDescription)\n"
                if FileManager.default.fileExists(atPath: store.sessionURL.path) {
                    text += "Everything changed so far is in trash session \(store.sessionID). "
                        + "Undo with: xcpurge restore --session \(store.sessionID)\n"
                }
                ScanRunner.stderr(text)
                try ScanRunner.report(result.afterAction(trashed, acted: toTrash), options)
                throw error
            }
            ScanRunner.printAction(pruned, verb: "pruned", session: store.sessionID)
        }

        await ScanRunner.recordSizes(before: sizeBefore, result: result, store: store, categories: scanned, options: options)
        let combined = ActionReport(moved: trashed.moved + pruned.moved, rewritten: trashed.rewritten + pruned.rewritten,
                                    skipped: trashed.skipped + pruned.skipped)
        try ScanRunner.report(result.afterAction(combined, acted: acting), options)
    }

    /// The findings to act on, all of purgeable kinds. Without `--ids`: `ScanRunner.actionable` per category (its
    /// confidence gate and notes), on the findings `--only` keeps. With `--ids`: exactly the listed findings, any
    /// confidence; ids that match nothing, or a finding purge never acts on, are reported on stderr.
    func select(from result: ScanResult) -> [Finding] {
        let rules = onlyRules
        let matchesOnly = { (f: Finding) in rules.isEmpty || FailOn.hit(rules, [f]) }
        let candidates = result.findings.filter {
            Self.categories.contains($0.category) && Self.purgeableKinds.contains($0.kind) && matchesOnly($0)
        }

        let wanted = idList
        guard !wanted.isEmpty else {
            let filtered = ScanResult(context: result.context, findings: candidates, elapsed: result.elapsed,
                                      baseline: result.baseline)
            return Self.categories.flatMap { ScanRunner.actionable(filtered, category: $0, options: options) }
        }
        let wantedSet = Set(wanted)
        let chosen = candidates.filter { wantedSet.contains($0.id) }
        let chosenIDs = Set(chosen.map(\.id))
        let allIDs = Set(result.findings.map(\.id))
        var seen = Set<String>()
        let unique = wanted.filter { seen.insert($0).inserted }
        let notFound = unique.filter { !allIDs.contains($0) }
        let notActionable = unique.filter { allIDs.contains($0) && !chosenIDs.contains($0) }
        if !notFound.isEmpty {
            ScanRunner.stderr("warning: \(notFound.count) id(s) not found in this scan: \(notFound.joined(separator: ", "))\n")
        }
        if !notActionable.isEmpty {
            let why = rules.isEmpty ? "purge never acts on these kinds" : "purge never acts on these kinds, or excluded by --only"
            ScanRunner.stderr("warning: \(notActionable.count) id(s) left alone (\(why)): \(notActionable.joined(separator: ", "))\n")
        }
        if chosen.isEmpty { ScanRunner.stderr("None of the given ids can be purged; nothing to do.\n") }
        return chosen
    }

    /// `move 2 asset/file item(s) to .xcpurge-trash and remove 1 string key(s)`
    static func summary(trash: Int, prune: Int) -> String {
        var parts: [String] = []
        if trash > 0 { parts.append("move \(trash) asset/file item(s) to \(TrashStore.directoryName)") }
        if prune > 0 { parts.append("remove \(prune) string key(s)") }
        return parts.joined(separator: " and ")
    }

    /// The pending actions grouped by category: a header line per category, then one line per finding.
    static func groupedDetails(_ findings: [Finding]) -> [String] {
        categories.flatMap { category -> [String] in
            let group = findings.filter { $0.category == category }
            guard !group.isEmpty else { return [] }
            let verb = category == .strings ? "prune" : "trash"
            return ["\(category.rawValue) (\(verb) \(group.count)):"] + group.map { "  " + ScanRunner.describe($0) }
        }
    }
}
