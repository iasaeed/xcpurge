---
name: xcpurge
description: Find and remove unused assets, localized strings and files in Xcode projects and Swift packages with the xcpurge CLI. Use when asked to clean up dead resources, unused images, colors, fonts, string keys, orphan or dead source files, duplicates, or to shrink an iOS/macOS app. Runs `xcpurge scan --format agent`, treats medium/low findings as leads that need `xcpurge explain` before any removal, removes with `xcpurge remove`, builds, rescans, and undoes with `xcpurge restore`. Never adds ignore entries without a reason line.
---

# xcpurge: remove unused resources safely

xcpurge reads the project without building it. A **high** finding has no reference from any module that can
see it. **medium** and **low** findings are *not proven unused*: a bare string, a runtime-built name
(`Image("icon_\(i)")`), the wrong bundle or a convention-loaded file could still use them. The scan output is
a lead, not a verdict.

## Setup

- `xcpurge --version` (0.4.0 or newer). Install: `brew install iasaeed/tap/xcpurge` or a release binary.
- Work on a clean branch. Removals go in their own commit so the review and the undo stay small.
- Dependency checkouts, `DerivedData`, `.build` and `Pods/` are skipped by default; do not scan them.

## Workflow

1. Scan to a file outside the repository, then read it:
   `xcpurge scan <root> --format agent --output /tmp/xcpurge-agent.txt`
   The header has one legend (confidence policy, command templates, reason codes), a summary with counts,
   then sections per kind and module. Each row: `id=<kind>-<hash> <confidence> <path> name=<n> reasons=<codes>`
   plus a ready `remove:` command (with `--yes`: there is no terminal to answer a prompt) and the `ignore:` line
   that would hide it. Values with spaces, quotes or control characters are double-quoted with `\n`-style
   escapes; treat each as one token. Sections stop at 30 rows per kind;
   narrow with `--targets <module>`, `--min-confidence high`, or show all with `--agent-limit 0`.
2. Act on **high** first. For each: run the `remove:` command, build every scheme and configuration, run tests.
   `remove` moves the file or asset set to `.xcpurge-trash/` and edits `project.pbxproj`; nothing is deleted.
3. For every **medium** or **low** you want to remove, run `xcpurge explain <root> <id>` first. It lists the
   owners, the modules whose references count, every reference site (file:line, visible or not), runtime-built
   names that could produce it, how the confidence was derived (one line per reason code) and what would make
   it safe. Check those sites. "No grep hits" is not evidence for names built at runtime, server-driven
   content, `NSClassFromString`, Codable keys, `#if` branches, scripts or docs.
4. Rescan after removing: removal exposes more (a file that only the removed file used).
5. If a build or test fails: `xcpurge restore <root>` undoes the newest session byte for byte
   (`--session <id>` for an older one, `--list` to see them).
6. Report what was removed, what was kept and why, and the reclaimed bytes (`xcpurge size --compare`).

## Reason codes

`no-ref` no visible reference · `dyn-pattern` a runtime-built name could produce it · `string-literal` the name
appears as a bare string · `case-only-match` differs only in case · `main-bundle` read through Bundle.main ·
`preview-only` / `public-api` / `test-only` / `extension-only` the only users · `app-icon` chosen by build
settings · `odr` on-demand resource tag · `numbered-sibling` a loop may build it · `font-declared` in UIAppFonts ·
`xcode-stale` / `ib-stale` marked stale · `duplicate` byte-identical · `ghost-ref` missing on disk ·
`excluded` / `unattributed` / `folder-ref` / `convention` project-structure hints · `skipped-source` a source
could not be read (everything capped at medium) · `stale-ignore` an ignore rule that suppresses nothing.
Each code has a "to make this safe" step in `explain`.

## Ignoring

Never add `.xcpurgeignore` entries or `// xcpurge:ignore` markers just to make a scan green. An ignore is a
claim that the thing is used; write the evidence above it:

```
# loaded by name from the CMS feed (see ContentLoader.swift)
asset:server_driven_*
```

Prefer `asset:<name>` / `string:<key>` over path globs. xcpurge reports rules that suppress nothing as
`stale-ignore` findings; delete them.

## Commands

```
xcpurge scan <root> --format agent [--agent-limit N] [--targets M] [--min-confidence high] [--output f]
xcpurge explain <root> <id | path | name> [--format json]
xcpurge remove --yes <root> <path...>         # asset set, file or ghost reference; dry-runs the pbxproj edit
                                              # (without --yes and without a terminal: nothing happens, exit 2)
xcpurge restore <root> [--session id] [--list]
xcpurge scan <root> --format json             # schema: docs/schema/findings-v2.schema.json
xcpurge size <root> --compare before.json     # bytes before and after
```

Exit codes: 0 ok, 1 `--fail-on` hit, 2 usage or no match, 3 internal, 4 `--verify` failed. stdout is data
only; progress and notes go to stderr (`--quiet` silences them).

## Do not

- Remove a medium/low finding without reading its `explain` output and the sites it lists.
- Delete `dead-source` files that declare `@objc` classes, Codable types, `CaseIterable` enums, test helpers
  or anything reached through reflection without checking those uses by hand.
- Edit `project.pbxproj` yourself; let `remove` do it so `restore` can undo it.
- Run `--delete` or `remove` on a dirty tree, or mix removals with other changes in one commit.
