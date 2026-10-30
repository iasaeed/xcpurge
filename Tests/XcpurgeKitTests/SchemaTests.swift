import Foundation
import XCTest
@testable import XcpurgeKit

/// `docs/schema/findings-v2.schema.json` against the JSON every fixture produces, plus synthetic `history` and
/// `baseline` data. A small walker (no validator dependency): every key path, type and enum value in the output
/// must be declared, and every enum in the schema must match the Swift enum it mirrors.
final class SchemaTests: XCTestCase {
    private static let schemaURL = FixtureSupport.fixturesURL.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/schema/findings-v2.schema.json")

    private func loadSchema() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.schemaURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], "schema is not a JSON object")
    }

    private func check(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let schema = try loadSchema()
        let value = try JSONSerialization.jsonObject(with: Data(json.utf8))
        var failures: [String] = []
        SchemaWalker(root: schema).validate(value, against: schema, at: "$", failures: &failures)
        XCTAssertTrue(failures.isEmpty, "schema violations:\n" + failures.joined(separator: "\n"), file: file, line: line)
    }

    private var fixtureNames: [String] {
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: FixtureSupport.fixturesURL.path)) ?? []
        return dirs.filter { !$0.hasPrefix(".") }.sorted()
    }

    func testEveryFixtureReportMatchesSchema() async throws {
        XCTAssertGreaterThanOrEqual(fixtureNames.count, 8)
        for name in fixtureNames {
            let result = try await ScanEngine(root: FixtureSupport.fixtureURL(name), config: Config()).run()
            try check(JSONReporter().render(result))
        }
    }

    func testSyntheticHistoryAndBaselineMatchSchema() throws {
        let synthetic = SyntheticResult.make(count: 300)
        var findings = synthetic.findings
        let commit = FindingHistory.Commit(sha: "0123abcd", date: "2024-05-01T10:00:00Z", authorName: "J. Appleseed",
                                           authorEmail: "j@example.com", subject: "Add icons")
        for i in findings.indices {
            switch i % 4 {
            case 0: findings[i].history = FindingHistory(status: .ok, lastCommit: commit, ageDays: 540, bucket: .leftover,
                                                         deadSince: commit)
            case 1: findings[i].history = FindingHistory(status: .shallow, note: "n/a (shallow clone)")
            case 2: findings[i].history = FindingHistory(status: .untracked)
            default: break
            }
        }
        let fixed = [BaselineEntry(key: "unusedAsset|App|gone", kind: .unusedAsset, category: .assets, module: "App",
                                   path: "App/Assets.xcassets/gone.imageset", name: "gone", count: 1),
                     BaselineEntry(key: "staleIgnore|.xcpurgeignore|Vendor/**", kind: .staleIgnore, category: .ignores,
                                   module: "unknown", path: ".xcpurgeignore", name: "Vendor/**")]
        let baseline = BaselineReport(file: ".xcpurge-baseline.json", createdAt: "2026-10-01T00:00:00Z", ageDays: 29,
                                      toolVersion: "0.4.0", baselinedCount: 140, newCount: findings.count, fixed: fixed,
                                      warnings: ["baseline is 29 days old"], strict: true)
        let result = ScanResult(context: synthetic.context, findings: findings, baseline: baseline)
        let json = JSONReporter().render(result)
        XCTAssertTrue(json.contains("\"history\""))
        XCTAssertTrue(json.contains("\"baseline\""))
        try check(json)
    }

    func testEmptyReportMatchesSchema() throws {
        let synthetic = SyntheticResult.make(count: 10)
        try check(JSONReporter().render(ScanResult(context: synthetic.context, findings: [])))
    }

    func testSchemaEnumsMatchSwift() throws {
        let schema = try loadSchema()
        let defs = try XCTUnwrap(schema["$defs"] as? [String: Any])
        func values(_ name: String) -> Set<String> { Set(((defs[name] as? [String: Any])?["enum"] as? [String]) ?? []) }
        XCTAssertEqual(values("FindingKind"), Set(FindingKind.allCases.map(\.rawValue)))
        XCTAssertEqual(values("Category"), Set(XcpurgeKit.Category.allCases.map(\.rawValue)))
        XCTAssertEqual(values("Confidence"), Set(Confidence.allCases.map(\.rawValue)))
        let kinds: [ModuleKind] = [.app, .appExtension, .appClip, .watchApp, .framework, .staticLib, .packageLibrary,
                                   .packageExecutable, .unitTest, .uiTest, .macro, .plugin, .aggregate, .unknown]
        XCTAssertEqual(values("ModuleKind"), Set(kinds.map(\.rawValue)))
        let history = try XCTUnwrap(defs["FindingHistory"] as? [String: Any])
        let props = try XCTUnwrap(history["properties"] as? [String: Any])
        XCTAssertEqual(Set(((props["status"] as? [String: Any])?["enum"] as? [String]) ?? []),
                       ["ok", "shallow", "untracked", "not-git", "unavailable"])
        XCTAssertEqual(Set(((props["bucket"] as? [String: Any])?["enum"] as? [String]) ?? []), ["recentlyAdded", "leftover"])
        XCTAssertEqual(schema["$schema"] as? String, "https://json-schema.org/draft/2020-12/schema")
        XCTAssertEqual(((schema["properties"] as? [String: Any])?["schemaVersion"] as? [String: Any])?["const"] as? Int,
                       JSONReporter.schemaVersion)
    }

    func testEveryRefResolves() throws {
        let schema = try loadSchema()
        var refs: [String] = []
        func collect(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let ref = dict["$ref"] as? String { refs.append(ref) }
                dict.values.forEach(collect)
            } else if let array = node as? [Any] {
                array.forEach(collect)
            }
        }
        collect(schema)
        XCTAssertFalse(refs.isEmpty)
        let walker = SchemaWalker(root: schema)
        for ref in refs { XCTAssertNotNil(walker.resolve(["$ref": ref]), "unresolved \(ref)") }
    }

    /// A finding that adds an undeclared key must fail, so the walker really checks key paths.
    func testWalkerRejectsUnknownKeys() throws {
        let schema = try loadSchema()
        let synthetic = SyntheticResult.make(count: 5)
        var json = JSONReporter().render(ScanResult(context: synthetic.context, findings: Array(synthetic.findings.prefix(1))))
        json = json.replacingOccurrences(of: "\"schemaVersion\" : 2", with: "\"schemaVersion\" : 2,\n  \"surprise\" : 1")
        let value = try JSONSerialization.jsonObject(with: Data(json.utf8))
        var failures: [String] = []
        SchemaWalker(root: schema).validate(value, against: schema, at: "$", failures: &failures)
        XCTAssertTrue(failures.contains { $0.contains("surprise") }, "\(failures)")
    }
}

/// Minimal JSON Schema walker for the subset the xcpurge schema uses: `$ref` into `$defs`, `type`, `const`,
/// `enum`, `properties` / `required` / `additionalProperties` / `propertyNames`, `items`, `minimum`, `pattern`.
struct SchemaWalker {
    let root: [String: Any]

    func resolve(_ node: [String: Any]) -> [String: Any]? {
        guard let ref = node["$ref"] as? String else { return node }
        guard ref.hasPrefix("#/") else { return nil }
        var current: Any = root
        for part in ref.dropFirst(2).split(separator: "/") {
            guard let dict = current as? [String: Any], let next = dict[String(part)] else { return nil }
            current = next
        }
        return current as? [String: Any]
    }

    func validate(_ value: Any, against rawNode: [String: Any], at path: String, failures: inout [String]) {
        guard let node = resolve(rawNode) else { failures.append("\(path): unresolved $ref \(rawNode["$ref"] ?? "")"); return }
        if let type = node["type"] {
            let allowed = (type as? [String]) ?? [type as? String ?? ""]
            if !allowed.contains(where: { matches(value, type: $0) }) {
                failures.append("\(path): \(describe(value)) is not \(allowed.joined(separator: "|"))")
                return
            }
        }
        if let const = node["const"], !(const as AnyObject).isEqual(value) { failures.append("\(path): expected const \(const)") }
        if let options = node["enum"] as? [String] {
            if let s = value as? String, !options.contains(s) { failures.append("\(path): '\(s)' not in enum \(options)") }
        }
        if let min = node["minimum"] as? Double, let n = value as? NSNumber, n.doubleValue < min {
            failures.append("\(path): \(n) below minimum \(min)")
        }
        if let pattern = node["pattern"] as? String, let s = value as? String,
           s.range(of: pattern, options: .regularExpression) == nil {
            failures.append("\(path): '\(s)' does not match \(pattern)")
        }
        if let dict = value as? [String: Any] {
            let properties = node["properties"] as? [String: Any] ?? [:]
            for key in (node["required"] as? [String]) ?? [] where dict[key] == nil { failures.append("\(path): missing \(key)") }
            for (key, child) in dict.sorted(by: { $0.key < $1.key }) {
                if let names = node["propertyNames"] as? [String: Any] {
                    validate(key, against: names, at: "\(path).\(key)<name>", failures: &failures)
                }
                if let schema = properties[key] as? [String: Any] {
                    validate(child, against: schema, at: "\(path).\(key)", failures: &failures)
                } else if let extra = node["additionalProperties"] as? [String: Any] {
                    validate(child, against: extra, at: "\(path).\(key)", failures: &failures)
                } else if node["additionalProperties"] as? Bool == true {
                    continue
                } else {
                    failures.append("\(path).\(key): undeclared key")
                }
            }
        } else if let array = value as? [Any], let items = node["items"] as? [String: Any] {
            for (i, child) in array.enumerated() { validate(child, against: items, at: "\(path)[\(i)]", failures: &failures) }
        }
    }

    private func matches(_ value: Any, type: String) -> Bool {
        switch type {
        case "object": return value is [String: Any]
        case "array": return value is [Any]
        case "string": return value is String
        case "null": return value is NSNull
        case "boolean": return isBool(value)
        case "number": return value is NSNumber && !isBool(value)
        case "integer":
            guard let n = value as? NSNumber, !isBool(value) else { return false }
            return n.doubleValue == n.doubleValue.rounded()
        default: return false
        }
    }

    private func isBool(_ value: Any) -> Bool {
        guard let n = value as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    private func describe(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if isBool(value) { return "boolean" }
        if value is NSNumber { return "number" }
        if value is String { return "string" }
        if value is [Any] { return "array" }
        return "object"
    }
}
