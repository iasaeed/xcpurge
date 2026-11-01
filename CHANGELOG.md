# Changelog

## Unreleased

### Changed

- An exact name in a module the visibility rule does not count (a framework or package the app links, a sibling
  target) no longer leaves a finding at high: it caps assets, strings, fonts and resource files at medium (reason
  code `not-visible`), or at low when it is the argument of a main-bundle lookup (`UIImage(named:)`, `Image("…")`,
  `UIColor(named:)`, `NSDataAsset`, `NSLocalizedString`, `String(localized:)`, `Text("key")`,
  `Bundle.main.url(forResource:)`; reason code `main-bundle-lookup`). Bundle-less lookups in dependencies of the
  owning app were medium and are now low too. Lookups that pass `.module`/`#bundle`, and localization calls naming
  another table, still never count. `bundle: nil` / `in: nil` now reads as the main bundle.
- A visible use of an accessor whose body in another module holds the name (`CommonStrings.attachmentTypeAnimated`
  wrapping `"ATTACHMENT_TYPE_ANIMATED"`) counts as a reference, for declarations whose name is declared only once.
  Heuristic, without type checking.

### Fixed

- A project target linking a local package product through `XCSwiftPackageProductDependency` with no `package =`
  attribute (Xcode writes this for a package added as a folder) got no dependency edge when the product's targets
  come from a variable (`targets: publicTargets`), which `--no-swift` cannot read: every non-test target of the
  package is now linked, and local packages the project references are searched first. App code in such projects
  now sees the package's assets and strings (mastodon-ios).

- Output xcpurge wrote inside the scanned tree (an `--output` HTML or JSON report, a baseline under another name,
  a `size --save` snapshot such as `size-base.json`, including ones saved by 0.4.0, or an `explain --format json`
  file) was read as a reference source, so the next scan or `--delete` dropped every finding it listed (e.g. the
  remaining copy of an asset after `remove` took the other one). Such files and the `.xcpurge/` and
  `.xcpurge-trash/` folders are now skipped by every walk; size snapshots now carry a `tool` field.

## 0.4.0 - 2026-10-30

### Added

- `xcpurge baseline [root] [--output FILE]` writes `.xcpurge-baseline.json`: one sorted line per finding identity
  (no line numbers or confidence, root-relative paths, locales collapsed into a count), regenerated in full with a
  `+N added, -M removed` summary, byte-identical for an unchanged tree on the same day.
- `--baseline FILE` (also `"baseline"` in `xcpurge.json`) on `scan`, `assets`, `strings` and `files` hides
  baselined findings as a multiset, prints `Baseline FILE (N days): A baselined, B new, C fixed`, and applies
  `--fail-on` and `--delete` to the new findings only. Fixed entries are scoped to the scanned categories,
  `--targets` and `--exclude`; `--strict-baseline` exits 1 on them. The JSON report carries a `baseline` object.
- Baseline warnings for age (`--baseline-max-age`, default 90 days), a different scope configuration
  (`configHash`), uncovered categories, a changed `--min-confidence`, another xcpurge minor version and empty files;
  a missing, empty, unparseable or newer-version baseline exits 2. The configured baseline file is dropped from the
  scan inventory so it is never read as a reference.

- `stale-ignore` findings (new category `ignores`, informational) for `.xcpurgeignore` rules and `//
  xcpurge:ignore` markers that suppress nothing: path globs matching no path on disk (checked against the inventory,
  then one lazy walk of the root that ignores `--targets`, `--exclude` and skipped `Pods/`), `kind:` typos,
  `module:` names no module has, `asset:` / `string:` rules with no match (only when that category was scanned; `asset:` matches loose image and font names with or without extension, catalog names exactly, as suppression does), and
  line-style markers that a second detector pass without markers still finds nothing for (never when a dynamic name
  or a kept dead-source file is involved). Block-comment markers and markers in generic text files are never
  reported; scoped runs (`--project`, `--package`, `--workspace`) keep only the glob and `kind:` checks. The disk
  walk prunes directories no rule can match under, skips build output and is capped (undecided rules are reported
  low as "could not evaluate"). `--no-stale-ignore` / `"staleIgnores": false` turns it off, `--fail-on-stale-ignore`
  exits 1.
- `.xcpurgeignore` rules remember their line and text (`Ignore.ruleSummaries`); the Swift/ObjC tokenizer exposes
  `ignoreMarkers` (line, covered lines, `//` or `/* */` style) next to the unchanged `ignoredLines`.

- `xcpurge size --compare base.json --format markdown|github`: a pull-request comment body that starts with
  `<!-- xcpurge-size -->` (sticky, edited in place), headline `### xcpurge size: +X (+Y%)`, an honest "what was
  measured" line (source-tree bytes; install size with `--app`; download size ≈ .ipa bytes for an .ipa), Base | PR |
  Change tables for tree and categories, modules and app sections in `<details>`, **Top changes** (`--top 20` paths
  with |change| ≥ `--min-path-delta 500` bytes, asset sets as units, the rest folded), reclaimable estimate and a
  footer; capped at 60,000 characters. `github` also appends the body to `$GITHUB_STEP_SUMMARY`.
  `--comment-threshold 100KB` prints nothing (and writes no `--output`) below that |change|; `--fail-if-grows
  500KB|2%` exits 1 with `size gate: grew +X (limit Y)` after the comment is written; `--allow-missing-compare`
  makes a missing base a note (exit 0). Snapshots gain `paths` (per-path bytes, asset sets as units) and
  `app.compressedBytes` for an .ipa; `schemaVersion` stays 1. Sample workflow: `docs/ci/xcpurge-size.yml`
  (artifact base, sticky comment deleted when quiet, `size-increase-ok` label skips the gate).

- `xcpurge init --xcode-phase [--configuration Release|any] [--max-warnings 50]` prints a Run Script build phase
  (Homebrew/local PATH, skips CI and other configurations, `command -v` guard that warns instead of failing, stamp
  file for incremental skips, sandboxing note); it writes nothing and never edits a project file. `--max-warnings N`
  on `--format xcode` caps the warning lines, adds `warning: [xcpurge] K more findings not shown (run xcpurge scan
  for all)` and always ends with `note: [xcpurge] T findings (h high, m medium, l low)` when there are findings.
  Sample workflow: `docs/ci/xcpurge.yml` (release binary, `--format github --baseline ... --fail-on any`, no
  xcodebuild).
- Reports present baselines and git history: text prints `Baseline: N baselined, M new, K fixed (D days old)` plus
  warnings (fixed list under `--verbose`) and `· 3y, J. Appleseed` after findings with history; `--format github`
  adds `; baseline: ...` to its summary notice and one `::notice` listing fixed entries; the HTML report gains an
  `ignores` category colour, a Baseline card (New / Baselined / Fixed, fixed list, age warning), Age and Author
  columns, a History facet and `age:>90` / `author:` / `bucket:` search tokens (only when some finding has
  history), a drawer History section (last commit, bucket and dead-since labelled heuristic) and `id` / `ageDays` /
  `author` CSV columns. Author e-mails are never shown.

- `--git` annotates findings with their last commit (sha, author name, date, subject), age in days and a
  `recentlyAdded`/`leftover` bucket (`--git-recent-days`, default 30) as an optional `history` object in JSON.
  One streaming `git log --name-only` per repository with early exit; submodules are walked separately. Shallow
  clones give `status: shallow` with a note instead of dates; uncommitted paths `untracked`; a non-git root
  `not-git`. `--git-emails` adds author emails (never by default); `--git-dead-since` runs a capped `git log -S`
  heuristic for the commit that removed the last use. Age never changes confidence.
- `--git` settles paths the index does not know (`git ls-files`: never committed, ignored, deleted) as `untracked`
  before the walk, so they cannot hold it up. A ghost reference is looked up on its own and shows the commit that
  deleted the file (`note: "deleted in <sha>"`, that commit as `lastCommit`; at most 50 per repository).

- `--verify "<build command>"` on `assets --delete`, `files --delete` and `remove` (with `--verify-timeout`,
  default 1800 s, and `--verify-max-builds`, default 8): preflight build (red → exit 4, nothing removed), build
  after the removal, restore the units the compiler names, bisect the rest under the cap, full restore and
  exit 4 on timeout. Dead source files that reference each other are one removal unit. The report always says
  "build-verified, not runtime-verified". Blocked paths persist in `.xcpurge-trash/verify-blocked.json`
  (`--delete` skips them, `remove` warns); the session manifest gains a `verify` record.
- `--verify` handles Ctrl-C / SIGTERM: the build's process group is stopped (not just xcpurge), everything is
  restored and the exit code is 4. A red build that no removed file can be blamed for (only project edits left,
  "unresolved") restores everything and exits 4 too. Aborts leave a record-only session whose `verify.reason`
  says `timed out`, `interrupted` or `unresolved`; `restore` skips such sessions by default and `restore --list`
  marks them "record only". Build commands that leave background children behind end when the shell exits.
- `assets --delete` / `files --delete`: `size-before.json` is measured on the ungated scan (before `--baseline`
  hides findings), like `size-after.json`, so the reclaimable figure can no longer appear to grow.
- `xcpurge restore --path <p>` (repeatable) restores part of a session and re-plans the `project.pbxproj` edit
  for what stays in the trash; a session that still has entries is never deleted.

- `--format agent` (`--agent-limit N`): plain, deterministic report for coding agents with one legend, a summary, rows grouped by kind and module (stable `id`, confidence, reason codes, ready `remove` command and `.xcpurgeignore` line), capped per kind with a narrowing hint.
- `xcpurge explain <root> <id|path|name>` (`--format text|json`): reported / suppressed (which rule or marker) / belowThreshold / notReported, owners, modules checked, the visibility rule, reference sites, dynamic patterns, the confidence derivation and what would make it safe; exit 2 with suggestions when nothing matches.
- `docs/schema/findings-v2.schema.json` (JSON Schema draft 2020-12) for the `--format json` document with a version policy, and the `skills/xcpurge` agent skill plus an AGENTS.md snippet in the README.

### Changed

- `assets --delete`, `files --delete`, `strings --prune` and `remove` without `--yes` and without a terminal on
  stdin: the confirmation cannot be answered, so the three scanning actions still write their report (stdout or
  `--output`) and then exit 2 with `Not a terminal; pass --yes to confirm.`; `remove` exits 2 after listing what
  it would do. Before, the run ended 0 having done nothing (and, briefly, exited 2 before writing the report).
- `--format agent`: `remove:` and `ignore:` are separate lines (the `remove:` text can be piped to a shell as
  is), and the `ignore:` value is the `.xcpurgeignore` entry verbatim, quoted only for control characters or
  leading/trailing whitespace, so pasting it never produces a rule that matches nothing.
- Text output ends with dimmed `note:` lines for info diagnostics (for example the scoped-run stale-ignore
  note), or `N notes (use --format json to see them)` above three; `--quiet` drops them, `--verbose` still lists
  them as `info:`.

- JSON findings carry a stable `id` (`<kind>-<10 hex>`, from the finding's identity key and path; no line
  number, so it survives edits elsewhere in the file). `schemaVersion` stays 2: the field is additive, as are the
  optional `history` (with `--git`) and `baseline` (with `--baseline`) fields.

### Fixed

- `--format agent`: project-supplied values (path, name, module, ignore entry) are escaped, so a `.strings` key
  or asset name containing a newline can no longer forge a `remove:` line; values with spaces, quotes or control
  characters are double-quoted with `\n \r \t \" \\ \u{XX}` escapes (new `values:` legend line), and a path with
  a control character is shell-quoted as `$'…'`. The `remove:` command now carries `--yes`: without a terminal
  the confirmation cannot be answered, and such a declined confirmation now exits 2 instead of 0 with nothing done.
- `xcpurge explain` takes its format from `--format` only; a `"format": "github"` in `xcpurge.json` no longer
  breaks it. A folder or catalog subject (`App/Assets.xcassets`) lists every finding under it.
- `xcpurge size` no longer applies the baseline or `--git`: the reclaimable estimate counts every finding and a
  missing baseline file does not fail it. `--fail-if-grows` / `--comment-threshold` values that do not fit in
  64 bits or are not finite (`99999999999999999999GB`, `1e300%`, `inf%`) are usage errors (exit 2), not traps.
- `xcpurge init --xcode-phase`: `--configuration` accepts spaces (`"App Store"`) and rejects shell syntax; the
  phase reports `warning: xcpurge exited N (run xcpurge --version to check the install)` instead of `|| true`.
- The HTML report drops `authorEmail` from the embedded document (and so from Download JSON); it was never shown.
- Sample workflows: the `size-increase-ok` label really skips the gate (the ternary was inverted), the comment
  steps run with `always()` so a failed gate still posts the comment, label changes re-run the job, fork PRs
  (read-only token) are documented and cannot hide the gate's result, and the base-snapshot lookup only considers
  push runs. `docs/ci/xcpurge.yml` uses the default shallow checkout with a commented `fetch-depth: 0` + `--git`
  variant. `make package` (`Scripts/package-release.sh`) builds the `xcpurge-macos.tar.gz` (universal; a failed
  universal build stops it unless `ALLOW_HOST_ONLY=1`) and `.sha256` the workflows download and verify with
  `shasum -a 256 -c` before extracting; the archive is reproducible (`SOURCE_DATE_EPOCH` / HEAD date, `gzip -n`)
  and `XCPURGE_PACKAGE_DIR` must stay inside `.build/`.
- `docs/schema/findings-v2.schema.json` no longer closes objects with `additionalProperties: false`, matching the
  "additive changes keep v2" policy; `SchemaTests` still requires every emitted key to be declared.

## 0.3.0 - 2026-10-29

### Added

- `xcpurge remove <root> <path> ...`: moves exactly the given files or asset sets to `.xcpurge-trash` and drops
  their `project.pbxproj` references, without filtering by finding kind or confidence. A path inside an asset
  set removes that (innermost) set; a path missing on disk (a `ghost-reference`) loses only its project
  references; plain folders are refused (asset sets, catalogs, bundle-like folders and folder references move
  whole); a path outside the root, also through a symlinked folder, or inside the trash is refused before
  anything is touched (exit 2); a symlink is moved itself, never its target. Confirms unless `--yes`;
  `--quiet` hides progress. Runs discovery only (no reference index), so it is fast; it does not record the
  size before/after table. `xcpurge restore` undoes it. `ScanEngine.discover()`, `Trash.targets(for:context:)`
  and `Trash.remove(paths:context:)` are the library entry points.
- The HTML report's drawer has a **Remove from terminal** section for file-backed findings: the shell-quoted
  `xcpurge remove` command with a Copy button, and for duplicates one command per copy in the group (keep one).

### Fixed

- `--delete`: a file that one project cannot drop (a `project.xcproj`, or a pbxproj line the editor cannot
  change) is no longer edited out of the other projects referencing it; it stays untouched everywhere.
- `--delete` / `remove`: an asset catalog given as a whole (`App/Assets.xcassets`) now loses its pbxproj
  reference too.

## 0.2.0 - 2026-10-29

### Added

- `--format html`: a self-contained interactive report written to `--output` or
  `<path>/.xcpurge/report-<timestamp>.html`; `--open` and `--browser` open it. The template is compiled into
  the binary (`make template` regenerates it).
- `CrossProject` fixture: a workspace whose app links and embeds another project's framework.
- Live scan progress on stderr when it is a terminal (phases with counts and elapsed time, throttled to ~10
  updates a second), ending with `Scanned N files in M modules in Xs — K findings (h high, m medium, l low)`.
  Never written to stdout; off when stderr is not a terminal, unstyled under `NO_COLOR`; `--quiet` /
  `-q` turns it off. `ScanEngine` takes an optional `ProgressSink`.
- After writing a report xcpurge prints its absolute path, the findings summary (`No findings.` when empty) and
  `Opened in <app>` / `Opened in default browser`, or a warning with `open`'s error and the manual
  `open "<path>"` command.
- A hint when the scan root holds three or more independent repositories (e.g. `~/Projects`).
- The HTML report shows "Loading N findings…" in the table until its script has rendered the rows.
- `xcpurge size`: bytes and file counts of the scanned tree by category (asset catalogs, loose images, fonts,
  strings, Interface Builder, other resources, source, other files), per asset catalog, per asset set type and
  per module, plus `Estimated reclaimable: X (high) / Y (high+medium)` from the detectors. `--app` measures a
  built `.app` or `.ipa` (executable, `Assets.car`, each `.lproj`, `Frameworks/*`, `PlugIns/*`, other
  resources); `--save` writes a JSON snapshot and `--compare` diffs against one (before, after, change, %).
- `assets|files --delete` and `strings --prune` store `size-before.json` / `size-after.json` in the trash
  session and print a before → after table of the categories that changed; `restore` prints it reversed.
- The HTML report has a Size card (resources, source, whole tree, reclaimable high and high + medium).
- The HTML module graph zooms and pans, and a Show Pods toggle reveals or hides dependency modules; the report
  uses a light-only theme.
- README rewritten as a guided tour with real examples.

### Changed

- JSON reports are `schemaVersion` 2: they add a `size` object (tree sizes by category and module, reclaimable
  estimate). The HTML page still renders schema 1 documents (without the Size card).

### Fixed

- Storyboards, xibs, Swift/ObjC sources and plists over 5 MB were skipped, which emptied the storyboard's
  object-ID set and let `strings --prune` remove live translations. Only generic text is size-capped now, and a
  skipped source caps findings at medium.
- `Text("\(a) of \(b)")` now matches the key `"%lld of %lld"` (all literal segments are compared); format keys
  without a match are never high.
- `art.scnassets` named inside a path literal, Reality Composer projects used through their generated type,
  Core Data models (never high), UIKit's default nib lookup (`MyViewController()` loads `MyView.xib`), and
  files inside synchronized folders copied whole (low) are no longer reported as high.
- Cross-project links in a workspace (`BUILT_PRODUCTS_DIR` products, foreign container proxies) make the app a
  consumer of the other project's framework.
- Only Interface Builder-shaped IDs (`abc-12-def`, numbers) make a key an object-ID key; `onboarding.title`
  in `Onboarding.strings` is checked against code.
- `--exclude` and `exclude` hide findings but keep excluded files as reference sources; the init template no
  longer excludes `**/Generated/**`.
- `--delete` dry-runs the project edit and moves only files whose references can be removed; CRLF pbxproj
  files and `.xcdatamodeld` version groups are edited; `project.xcproj` references keep their files.
- Bundle-less `Image("x")` / `NSLocalizedString` in a dependency module count (medium) for the app's resources.
- Project paths match files case-insensitively on case-insensitive volumes.
- Nested types used unqualified inside their outer type keep their file alive.
- An unterminated string no longer shifts later line numbers; a source folder named `build` is scanned.
- After `--delete` / `--prune` the printed report lists only what is left.
- Large JSON/HTML/CSS/JS/xcconfig files are streamed in chunks instead of skipped; only unreadable files (not
  under `--exclude`) cap findings at medium.
- `--delete` writes the backed-up project edit before moving files, restores a reference whose file failed to
  move, and matches project paths case-insensitively on case-insensitive volumes.
- The HTML report renders module graphs that contain a cycle.
- `build/` holding a package or project is scanned; `pubspec.yaml` marks Flutter output; only directories
  with exact build-folder names count.
- The undo command is printed before the report is written; a failing `--open` is a warning; actions that
  change nothing leave no empty trash session.
- `--browser` naming an app that is not installed falls back to the default browser and says so, instead of
  failing quietly; `open`'s error output is shown when nothing could be opened.

## 0.1.0 - 2026-10-29

First release.

- `scan`, `assets`, `strings`, `files` with text, JSON, Xcode and GitHub Actions output, `--fail-on`,
  `--min-confidence`, `--targets`, `--exclude`, `xcpurge.json` and `.xcpurgeignore`.
- Discovery of classic and synchronized-folder `project.pbxproj`, Xcode 27.2 `project.xcproj` (best effort),
  Swift packages (with a no-swift fallback) and workspaces; module graph with dependency and embed visibility.
- Assets: catalogs, loose images, fonts (PostScript/family/full names), app icon and accent protection,
  generated asset symbols (mangling plus DerivedData index), SwiftGen/R.swift accessors, dynamic-name downgrade,
  byte-identical duplicates.
- Strings: `.xcstrings`, `.strings`, `.stringsdict`, Settings.bundle, Info.plist keys, storyboard strings,
  bundle/table narrowing, generated string symbols, stale keys.
- Files: orphans, ghost references, dead source files, unused storyboards/xibs and resources.
- Safe cleanup: `--delete` / `--prune` act on high-confidence findings by default, move everything into
  `.xcpurge-trash` with a manifest, and `restore` undoes a session byte for byte.
- `modules`, `init`, `doctor`.
