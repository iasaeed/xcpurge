# Changelog

## Unreleased

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
