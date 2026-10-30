import Foundation

/// Applies a `BaselineFile` to the findings of a scan: hides what the file lists (as a multiset, so two
/// findings with one key need two counts), reports entries nothing matched as fixed, and collects warnings about
/// a baseline that was written under other settings than this run uses.
public enum BaselineMatcher {
    public static func apply(findings: [Finding], file: BaselineFile, filePath: String, categories: Set<Category>,
                             config: Config, strict: Bool = false, now: Date = Date(),
                             toolVersion: String = XcpurgeVersion.current, root: URL? = nil)
        -> (kept: [Finding], report: BaselineReport) {
        var remaining: [String: Int] = [:]
        for entry in file.entries { remaining[entry.key, default: 0] += entry.count }
        var kept: [Finding] = []
        var baselined = 0
        for f in findings.sorted(by: Finding.reportOrder) {
            let key = f.key
            if let left = remaining[key], left > 0 {
                remaining[key] = left - 1
                baselined += 1
            } else {
                kept.append(f)
            }
        }

        // Fixed: leftover counts, but only for entries this run could have produced (category scanned, module and
        // path inside --targets / --exclude). `xcpurge assets --baseline` never reports fixed strings.
        let targets = Set(config.targets)
        let excludes = config.exclude.map(Glob.init)
        let staleInScope = config.staleIgnores && categories.isSuperset(of: [.assets, .strings, .files])
        var fixed: [BaselineEntry] = []
        for entry in file.entries {
            guard let left = remaining[entry.key], left > 0 else { continue }
            let inScope = entry.category == .ignores ? staleInScope : categories.contains(entry.category)
            guard inScope, targets.isEmpty || targets.contains(entry.module) || entry.category == .ignores,
                  !excludes.contains(where: { $0.matches(entry.path) }) else { continue }
            var e = entry
            e.count = left
            fixed.append(e)
        }

        var warnings: [String] = []
        if file.entries.isEmpty { warnings.append("baseline has no entries; every finding is new") }
        if let root, !file.configHash.isEmpty, file.configHash != BaselineFile.configHash(config, root: root) {
            warnings.append("baseline was written with a different configuration (exclude, targets, project or similar); "
                + "regenerate with xcpurge baseline")
        }
        let missingCategories = categories.subtracting(file.categories).subtracting([.ignores]).map(\.rawValue).sorted()
        if !missingCategories.isEmpty {
            warnings.append("baseline does not cover \(missingCategories.joined(separator: ", ")); "
                + "those findings are all new")
        }
        // Gating with --fail-on against a baseline written without one is the normal workflow; only a baseline
        // written under some other gate is worth a word.
        if !file.failOn.isEmpty, Set(file.failOn) != Set(config.failOn) {
            warnings.append("baseline was written with --fail-on \(describe(file.failOn)); this run uses \(describe(config.failOn))")
        }
        if config.minConfidence < file.minConfidence {
            warnings.append("this run's --min-confidence \(config.minConfidence.rawValue) is below the baseline's "
                + "\(file.minConfidence.rawValue); findings between are reported as new")
        } else if config.minConfidence > file.minConfidence {
            warnings.append("this run's --min-confidence \(config.minConfidence.rawValue) is above the baseline's "
                + "\(file.minConfidence.rawValue); entries below it cannot match and may show as fixed")
        }
        let age = file.ageDays(now: now)
        if age == nil { warnings.append("baseline has no readable createdAt date") }
        if let age, config.baselineMaxAgeDays > 0, age > config.baselineMaxAgeDays {
            warnings.append("baseline is \(age) days old; regenerate with xcpurge baseline")
        }
        if majorMinor(file.toolVersion) != majorMinor(toolVersion) {
            warnings.append("baseline was written by xcpurge \(file.toolVersion); this is \(toolVersion)")
        }

        let report = BaselineReport(file: filePath, createdAt: file.createdAt, ageDays: age ?? 0, toolVersion: file.toolVersion,
                                    baselinedCount: baselined, newCount: kept.count, fixed: fixed, warnings: warnings,
                                    strict: strict)
        return (kept, report)
    }

    private static func describe(_ failOn: [String]) -> String {
        failOn.isEmpty ? "(none)" : failOn.sorted().joined(separator: ",")
    }

    static func majorMinor(_ version: String) -> String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }
}
