# Changelog

## Unreleased

### Added

- `--format html`: a self-contained interactive report written to `--output` or
  `<path>/.xcpurge/report-<timestamp>.html`; `--open` and `--browser` open it. The template is compiled into
  the binary (`make template` regenerates it).
- `CrossProject` fixture: a workspace whose app links and embeds another project's framework.

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
