import Foundation

/// Short, stable codes for the free-text reasons detectors attach to findings (`--format agent`, `explain`).
/// A view only: the table maps today's reason strings by regular expression; detectors are not touched.
/// First matching row wins; anything unmatched is `other`.
public enum ReasonCodes {
    /// One row of the table: the code, the pattern that selects it, and a one-line meaning for `explain`.
    public struct Entry: Sendable {
        public let code: String
        let pattern: String
        public let meaning: String
        /// What would make a finding with this reason safe to act on.
        public let toMakeSafe: String
    }

    /// In legend order. `other` is last and matches nothing by pattern.
    public static let table: [Entry] = [
        .init(code: "skipped-source", pattern: #"source .* skipped \("#,
              meaning: "a reference source could not be read, so every high finding was capped at medium",
              toMakeSafe: "Make the skipped file readable (or exclude it with --exclude) and rescan."),
        .init(code: "case-only-match", pattern: #"case differs|case-insensitive"#,
              meaning: "the only reference differs in letter case",
              toMakeSafe: "Compare the spelling at the reference site with the resource name; a case-only match fails on case-sensitive volumes and in asset catalogs."),
        .init(code: "dyn-pattern", pattern: #"built dynamically|built at runtime|non-literal key"#,
              meaning: "a name built at runtime (string interpolation, concatenation, format) could produce this name",
              toMakeSafe: "Open the dynamic site and list the names the expression can build; if this one is reachable, keep it and add an ignore line with a reason."),
        .init(code: "not-visible", pattern: #"a module that cannot see"#,
              meaning: "the exact name appears in a module the visibility rule does not count (a framework or package the app links, a sibling target)",
              toMakeSafe: "Check whether that module ends up in the same app at runtime and whether the reference reaches a loader; if so the resource is used."),
        .init(code: "string-literal", pattern: #"string literal|appears as a string|names the key outside code|outside a localization call|without tableName"#,
              meaning: "the name appears as a bare string, outside the call that would load it",
              toMakeSafe: "Check whether that literal reaches a loader (NSClassFromString, Bundle.url, UIImage(named:), a server payload) or is just text."),
        .init(code: "main-bundle-lookup", pattern: #"resolves to the main bundle at runtime"#,
              meaning: "a lookup that reads the main bundle (UIImage(named:), Image, NSLocalizedString, Bundle.main.url) names it from a module the visibility rule does not count",
              toMakeSafe: "Check whether the module with the lookup is linked into the app that owns the resource; if it is, the lookup finds this resource at runtime."),
        .init(code: "main-bundle", pattern: #"main bundle|Bundle\.main|without a bundle"#,
              meaning: "the reference reads the main bundle, not the bundle that holds this resource",
              toMakeSafe: "Decide which bundle the call reads at runtime; a package resource read through Bundle.main is a bug to fix, not a dead resource."),
        .init(code: "preview-only", pattern: #"SwiftUI previews"#,
              meaning: "only SwiftUI previews reference it",
              toMakeSafe: "Removing it only affects Xcode previews; keep it if the preview is wanted."),
        .init(code: "public-api", pattern: #"public API"#,
              meaning: "public declarations of a library with no consumer inside this repository",
              toMakeSafe: "Search consumers outside this repository (other apps, SDK users) before removing public API."),
        .init(code: "test-only", pattern: #"only (referenced|used) (from|by) tests?|test targets? only"#,
              meaning: "only test targets reference it",
              toMakeSafe: "Decide whether test-only production code should move into the test target or stay."),
        .init(code: "extension-only", pattern: #"extension-only|category-only"#,
              meaning: "the file only extends types declared elsewhere, so nothing names the file itself",
              toMakeSafe: "Check whether the members the extension adds are used anywhere; the file name is never referenced."),
        .init(code: "app-icon", pattern: #"not named by ASSETCATALOG|Icon Composer icon"#,
              meaning: "an icon set that build settings or Info.plist select, not code",
              toMakeSafe: "Check ASSETCATALOG_COMPILER_APPICON_NAME, ALTERNATE_APPICON_NAMES and Info.plist icons in every configuration and xcconfig."),
        .init(code: "odr", pattern: #"on-demand resource"#,
              meaning: "an on-demand resource requested by tag at runtime",
              toMakeSafe: "Check the tags passed to NSBundleResourceRequest."),
        .init(code: "numbered-sibling", pattern: #"numbered sibling"#,
              meaning: "a numbered name whose sibling is used, so a loop may build this one",
              toMakeSafe: "Check loops that build numbered names (`icon_\\(i)`)."),
        .init(code: "font-declared", pattern: #"^declared in UIAppFonts"#,
              meaning: "the font is declared in UIAppFonts but never named",
              toMakeSafe: "Search UIFont(name:), Font.custom and Interface Builder font attributes for the PostScript or family name."),
        .init(code: "xcode-stale", pattern: #"Xcode marked this key stale"#,
              meaning: "Xcode's string extraction no longer finds the key",
              toMakeSafe: "Confirm the source string is gone; the translation can then be deleted from the catalog."),
        .init(code: "ib-stale", pattern: #"object ID .* no longer exists"#,
              meaning: "a storyboard or xib object ID the key points at is gone",
              toMakeSafe: "Open the Interface Builder file and confirm the object was removed."),
        .init(code: "duplicate", pattern: #"identical bytes"#,
              meaning: "byte-identical copies of the same file",
              toMakeSafe: "Keep one copy and point every reference at it."),
        .init(code: "ghost-ref", pattern: #"points at a missing path"#,
              meaning: "a project file reference whose path does not exist on disk",
              toMakeSafe: "Confirm the file was deleted on purpose; `xcpurge remove` drops the project.pbxproj lines."),
        .init(code: "target-member", pattern: #"^member of "#,
              meaning: "the missing file is still a member of build targets",
              toMakeSafe: "The build will fail until the reference is removed or the file restored."),
        .init(code: "excluded", pattern: #"excluded from (every|target)|may exclude it on purpose"#,
              meaning: "on disk but excluded from every target that could build it",
              toMakeSafe: "Check whether the exclusion is deliberate (platform-specific file, sample code) before deleting."),
        .init(code: "unattributed", pattern: #"outside every group|not referenced by any project|not a member of any target|script or tool"#,
              meaning: "no project or package claims the file",
              toMakeSafe: "Check scripts, CI and build phases that read the file by path; the project graph cannot see those."),
        .init(code: "folder-ref", pattern: #"inside folder reference|inside folder copied as a whole"#,
              meaning: "copied into the bundle as part of a folder, so it may be read by path",
              toMakeSafe: "Search for the folder name and for enumeration of its contents (contentsOfDirectory, urls(forResourcesWithExtension:))."),
        .init(code: "convention", pattern: #"by convention|load without a name"#,
              meaning: "a file some SDK or framework loads by convention, without naming it",
              toMakeSafe: "Check the SDKs in use for files they read by name (GoogleService-Info.plist, Core Data models, Settings.bundle)."),
        .init(code: "stale-ignore", pattern: #"matches no (file|path)|no asset named|suppresses nothing|not a known kind|no module (matches|named)|unknown (kind|module)|no finding matches"#,
              meaning: "an ignore rule or marker that suppresses nothing",
              toMakeSafe: "Delete the rule or marker, or fix its spelling."),
        .init(code: "no-ref", pattern: #"no reference|not referenced|never referenced|never used|no Info\.plist key|no Settings\.bundle pane|not a known Info\.plist key"#,
              meaning: "no reference by name, generated symbol or accessor from any module that can see it",
              toMakeSafe: "Grep the whole repository (scripts, CI, docs, server payloads) for the name; xcpurge only reads the sources it indexes."),
        .init(code: "generated", pattern: #"generated"#,
              meaning: "involves a generated file or symbol",
              toMakeSafe: "Regenerate (SwiftGen, R.swift, Xcode symbols) and rescan before removing."),
        .init(code: "other", pattern: #"(?!)"#,
              meaning: "a reason the code table does not classify; read the text",
              toMakeSafe: "Read the reason text and verify by hand."),
    ]

    /// Every code in legend order.
    public static var codes: [String] { table.map(\.code) }

    public static func entry(for code: String) -> Entry { table.first { $0.code == code } ?? table.last! }

    /// The code of one reason string.
    public static func classify(_ reason: String) -> String {
        for row in table where reason.range(of: row.pattern, options: .regularExpression) != nil { return row.code }
        return "other"
    }

    /// Codes of a finding's reasons, deduplicated, in reason order; `other` when it has no reasons.
    public static func codes(for finding: Finding) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for reason in finding.reasons {
            let code = classify(reason)
            if seen.insert(code).inserted { out.append(code) }
        }
        return out.isEmpty ? ["other"] : out
    }
}
