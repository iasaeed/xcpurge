import XcpurgeKit

/// `--fail-on` rule matching: `any`, a category (`assets`, `unused-assets`), or a finding kind (`dead-source`).
enum FailOn {
    static func validate(_ rules: [String]) throws {
        for rule in rules where !isKnown(rule) {
            throw XcpurgeError.invalidConfig("unknown --fail-on value \(rule)")
        }
    }

    static func isKnown(_ rule: String) -> Bool {
        rule == "any" || category(rule) != nil || FindingKind.allCases.contains { $0.flagName == rule }
    }

    static func category(_ rule: String) -> XcpurgeKit.Category? {
        let name = rule.hasPrefix("unused-") ? String(rule.dropFirst("unused-".count)) : rule
        return XcpurgeKit.Category(rawValue: name)
    }

    /// True when any finding matches any rule. Informational kinds only match when named explicitly.
    static func hit(_ rules: [String], _ findings: [Finding]) -> Bool {
        findings.contains { f in
            rules.contains { rule in
                if f.kind.flagName == rule { return true }
                if f.kind.isInformational { return false }
                return rule == "any" || category(rule) == f.category
            }
        }
    }
}
