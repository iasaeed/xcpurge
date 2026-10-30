import Foundation
import XCTest
@testable import XcpurgeKit

/// `FindingIdentity.key` / `.id` (the baseline and `explain` contract) and `Finding`'s hand-written encoder.
final class FindingIdentityTests: XCTestCase {
    private func finding(_ kind: FindingKind, category: XcpurgeKit.Category, path: String, line: Int? = nil,
                         name: String? = nil, module: String = "App", confidence: Confidence = .high) -> Finding {
        Finding(kind: kind, category: category, path: path, line: line, name: name, module: module, confidence: confidence,
                reasons: ["r"])
    }

    /// One finding of every kind, each with a line number.
    private var everyKind: [Finding] {
        [
            finding(.unusedAsset, category: .assets, path: "App/Assets.xcassets/old_icon.imageset", line: 1, name: "old_icon"),
            finding(.unusedFont, category: .assets, path: "App/Fonts/Brand.ttf", line: 1, name: "Brand.ttf"),
            finding(.unusedString, category: .strings, path: "App/en.lproj/Localizable.strings", line: 12, name: "hello"),
            finding(.staleString, category: .strings, path: "App/Localizable.xcstrings", line: 40, name: "old_banner"),
            finding(.orphanFile, category: .files, path: "App/Orphan.swift", line: 1),
            finding(.ghostReference, category: .files, path: "App/Ghost.swift", line: 1),
            finding(.deadSource, category: .files, path: "App/Dead/DeadHelper.swift", line: 1, name: "DeadHelper"),
            finding(.unusedInterfaceFile, category: .files, path: "App/Unused.xib", line: 1),
            finding(.unusedResource, category: .files, path: "App/unused.json", line: 1),
            finding(.duplicate, category: .duplicates, path: "App/dup_a.png", line: 1),
            finding(.dynamicLookup, category: .assets, path: "App/Loader.swift", line: 33, name: "icon_*", confidence: .low),
            finding(.staleIgnore, category: .ignores, path: ".xcpurgeignore", line: 3, name: "Vendor/**", module: "unknown",
                    confidence: .medium),
        ]
    }

    func testKeyShapesPerKind() {
        let keys = Dictionary(uniqueKeysWithValues: everyKind.map { ($0.kind, $0.key) })
        XCTAssertEqual(keys[.unusedAsset], "unusedAsset|App|old_icon")
        XCTAssertEqual(keys[.unusedFont], "unusedFont|App|App/Fonts/Brand.ttf")
        XCTAssertEqual(keys[.unusedString], "unusedString|App|Localizable|hello")
        XCTAssertEqual(keys[.staleString], "staleString|App|Localizable|old_banner")
        XCTAssertEqual(keys[.orphanFile], "orphanFile|App|App/Orphan.swift")
        XCTAssertEqual(keys[.ghostReference], "ghostReference|App|App/Ghost.swift")
        XCTAssertEqual(keys[.deadSource], "deadSource|App|App/Dead/DeadHelper.swift")
        XCTAssertEqual(keys[.unusedInterfaceFile], "unusedInterfaceFile|App|App/Unused.xib")
        XCTAssertEqual(keys[.unusedResource], "unusedResource|App|App/unused.json")
        XCTAssertEqual(keys[.duplicate], "duplicate|App|App/dup_a.png")
        XCTAssertEqual(keys[.dynamicLookup], "dynamicLookup|App|App/Loader.swift|icon_*")
        XCTAssertEqual(keys[.staleIgnore], "staleIgnore|.xcpurgeignore|Vendor/**")
        // A loose image without a set name falls back to the path form.
        XCTAssertEqual(finding(.unusedAsset, category: .assets, path: "App/Images/loose.png").key, "unusedAsset|App|App/Images/loose.png")
    }

    func testKeyNeverContainsTheLineNumber() {
        for f in everyKind {
            var moved = f
            moved.line = (f.line ?? 0) + 977
            XCTAssertEqual(f.key, moved.key, "\(f.kind) key depends on the line")
            // Stale inline markers in one file share the key by design, so only their id tells them apart.
            if f.kind == .staleIgnore {
                XCTAssertNotEqual(f.id, moved.id, "staleIgnore id must tell two markers in one file apart")
            } else {
                XCTAssertEqual(f.id, moved.id, "\(f.kind) id depends on the line")
            }
            XCTAssertFalse(f.key.contains("|977"), f.key)
        }
    }

    func testStringKeysCollapseLocales() {
        let en = finding(.unusedString, category: .strings, path: "App/en.lproj/Localizable.strings", line: 12, name: "hello")
        let de = finding(.unusedString, category: .strings, path: "App/de.lproj/Localizable.strings", line: 90, name: "hello")
        let catalog = finding(.unusedString, category: .strings, path: "App/Resources/Localizable.xcstrings", name: "hello")
        let dict = finding(.unusedString, category: .strings, path: "App/fr.lproj/Localizable.stringsdict", name: "hello")
        XCTAssertEqual(en.key, de.key)
        XCTAssertEqual(en.key, catalog.key)
        XCTAssertEqual(en.key, dict.key)
        let other = finding(.unusedString, category: .strings, path: "App/en.lproj/Other.strings", name: "hello")
        XCTAssertNotEqual(en.key, other.key, "a different table is a different key")
        // The id still distinguishes the files (locale copies differ), the key does not: baselines count multiples.
        XCTAssertNotEqual(en.id, de.id)
    }

    func testIdPrefixIsTheKindFlagNameAndSuffixTenHex() throws {
        let hex = try NSRegularExpression(pattern: "^[0-9a-f]{10}$")
        for f in everyKind {
            XCTAssertTrue(f.id.hasPrefix(f.kind.flagName + "-"), f.id)
            let suffix = String(f.id.dropFirst(f.kind.flagName.count + 1))
            XCTAssertEqual(hex.numberOfMatches(in: suffix, range: NSRange(suffix.startIndex..., in: suffix)), 1, f.id)
        }
        XCTAssertTrue(everyKind.first { $0.kind == .staleIgnore }!.id.hasPrefix("stale-ignore-"))
        XCTAssertTrue(everyKind.first { $0.kind == .unusedInterfaceFile }!.id.hasPrefix("unused-interface-file-"))
    }

    /// Pins the hash: FNV-1a 64 over `key|path`, first 10 hex digits (reference values from an independent implementation).
    func testIdIsDeterministicAndPinned() {
        let asset = finding(.unusedAsset, category: .assets, path: "App/Assets.xcassets/old_icon.imageset", name: "old_icon")
        XCTAssertEqual(asset.id, "unused-asset-8324ee39c9")
        XCTAssertEqual(asset.id, FindingIdentity.id(asset))
        let string = finding(.unusedString, category: .strings, path: "App/en.lproj/Localizable.strings", line: 12, name: "hello")
        XCTAssertEqual(string.id, "unused-string-8550c0a499")
        XCTAssertEqual(FindingIdentity.fnv1a64(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(FindingIdentity.fnv1a64("a"), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(FindingIdentity.hex10(0x0123_4567_89ab_cdef), "0123456789", "zero-padded to 16 digits before the cut")
        XCTAssertEqual(FindingIdentity.hex10(0xabcd_ef01_2345_6789), "abcdef0123")
        // Confidence, reasons, size and history are not part of the identity.
        var changed = asset
        changed.confidence = .low
        changed.reasons = ["other"]
        changed.sizeBytes = 99
        changed.history = FindingHistory(status: .ok, ageDays: 3)
        XCTAssertEqual(changed.id, asset.id)
        XCTAssertEqual(changed.key, asset.key)
    }

    func testIdsAreUniqueAcrossFixtures() async throws {
        for fixture in ["ModularWorkspace", "MixedApp", "StringsEdgeCases"] {
            var config = Config()
            config.noSwift = true
            let result = try await ScanEngine(root: FixtureSupport.fixtureURL(fixture), config: config).run()
            let ids = result.findings.map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count, "\(fixture): duplicate ids")
            XCTAssertFalse(ids.isEmpty, fixture)
        }
    }

    // MARK: - Codable

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    func testJSONRoundTripWithEveryField() throws {
        let commit = FindingHistory.Commit(sha: "abc123", date: "2024-01-02T03:04:05Z", authorName: "J. Appleseed",
                                           authorEmail: "j@example.com", subject: "Add icon")
        var f = finding(.unusedAsset, category: .assets, path: "App/Assets.xcassets/old_icon.imageset", line: 2, name: "old_icon",
                        confidence: .medium)
        f.sizeBytes = 1234
        f.groupID = "dup-1"
        f.history = FindingHistory(status: .ok, lastCommit: commit, ageDays: 700, bucket: .leftover, deadSince: commit,
                                   note: "n")
        let data = try encoder().encode(f)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["id"] as? String, f.id)
        XCTAssertEqual(object["line"] as? Int, 2)
        XCTAssertEqual(object["groupID"] as? String, "dup-1")
        XCTAssertEqual(Set(object.keys), ["id", "kind", "category", "path", "line", "name", "module", "confidence", "reasons",
                                          "sizeBytes", "groupID", "history"])
        let history = try XCTUnwrap(object["history"] as? [String: Any])
        XCTAssertEqual(history["status"] as? String, "ok")
        XCTAssertEqual((history["lastCommit"] as? [String: Any])?["authorEmail"] as? String, "j@example.com")
        let decoded = try JSONDecoder().decode(Finding.self, from: data)
        XCTAssertEqual(decoded, f)
        XCTAssertEqual(try encoder().encode(decoded), data, "re-encoding is stable")
    }

    func testJSONOmitsNilFieldsAndDecodesWithoutId() throws {
        let f = finding(.orphanFile, category: .files, path: "App/Orphan.swift")
        let data = try encoder().encode(f)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["id", "kind", "category", "path", "module", "confidence", "reasons"])
        XCTAssertEqual(try JSONDecoder().decode(Finding.self, from: data), f)
        // Pre-0.4 documents have no `id` or `history`; a stale `id` is ignored, never trusted.
        let legacy = Data("""
        {"kind":"orphanFile","category":"files","path":"App/Orphan.swift","module":"App","confidence":"high","reasons":["r"],"id":"bogus"}
        """.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Finding.self, from: legacy), f)
        XCTAssertEqual(try JSONDecoder().decode(Finding.self, from: legacy).id, f.id)
        XCTAssertEqual(try JSONDecoder().decode(Finding.self, from: Data("""
        {"kind":"staleIgnore","category":"ignores","path":".xcpurgeignore","module":"unknown","confidence":"medium","reasons":[]}
        """.utf8)).kind, .staleIgnore)
    }

    func testJSONReporterWritesIdAndOptionalBaseline() async throws {
        var config = Config()
        config.noSwift = true
        let result = try await ScanEngine(root: FixtureSupport.fixtureURL("SyncedApp"), config: config).run()
        let json = JSONReporter().render(result)
        let doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertNil(doc["baseline"], "omitted when no baseline was applied")
        let findings = try XCTUnwrap(doc["findings"] as? [[String: Any]])
        XCTAssertFalse(findings.isEmpty)
        XCTAssertEqual(findings.compactMap { $0["id"] as? String }, result.findings.map(\.id))
        var withBaseline = result
        withBaseline.baseline = BaselineReport(file: ".xcpurge-baseline.json", createdAt: "2026-10-01T00:00:00Z", ageDays: 12,
                                               toolVersion: "0.4.0", baselinedCount: 140, newCount: 3,
                                               fixed: [BaselineEntry(key: "orphanFile|App|A.swift", kind: .orphanFile, category: .files,
                                                                     module: "App", path: "A.swift")],
                                               warnings: ["w"], strict: true)
        let doc2 = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(JSONReporter().render(withBaseline).utf8)) as? [String: Any])
        let baseline = try XCTUnwrap(doc2["baseline"] as? [String: Any])
        XCTAssertEqual(baseline["baselinedCount"] as? Int, 140)
        XCTAssertEqual((baseline["fixed"] as? [[String: Any]])?.first?["key"] as? String, "orphanFile|App|A.swift")
    }
}
