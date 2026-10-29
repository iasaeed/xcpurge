# Changelog

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
