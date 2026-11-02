# What iOS developers ask for in a cleanup tool (community research, Oct 2026)

Sources: ~22 Reddit threads (via archive mirrors), Apple Developer Forums, Swift Forums,
Hacker News, ~70 GitHub issues across Periphery / FengNiao / LSUnusedResources / xcprune /
SwiftLint / SwiftGen / R.swift / Tuist, Emerge Tools, Duolingo, Uber, Lyft and Tinder engineering blogs.
Raw notes with quotes and URLs live in the session scratchpad (`research-*.md`).
Stack Overflow and X were not reachable; their signal is inferred from citations elsewhere.

## Market context

- Periphery (6.2k stars) was archived on 2026-08-12 and went commercial ("Periphery Pro", free for indie/OSS).
  A community fork appeared 2026-10-26 with "no feature roadmap". Its unused-image and xcstrings PRs were never merged.
- No open-source tool covers code + assets + strings together, none has undo, none works without a build.
- Practitioners run dead-code tools weekly or at release time, never blocking, because "a false positive must not block a merge".
- Two `xcprune` repos exist (0 stars, report-only, assets + strings only). Name collision risk is real.

## Ranked feature ideas

Demand = how often and how strongly it appeared across all four source groups.

| # | Idea | Demand | Effort | Evidence |
|---|------|--------|--------|----------|
| 1 | **Baseline mode**: `xcpurge baseline` records today's findings; CI fails only on NEW ones (`--baseline .xcpurge-baseline.json`). Diff against merge-base, post inline PR comments. | very high | S | home-assistant/iOS PR 5466 hand-built this; Periphery shipped #283/#710/#759; Reddit "keep project clear" threads |
| 2 | **Size-diff PR comment** (OSS, self-hosted): `xcpurge size --compare` already exists; add `--format github` for size, a threshold gate (`--fail-if-grows 100KB`), top-N changes table. | high | S | Emerge's PR comments are hosted-only and Emerge is now part of Sentry; Duolingo grew 50 MB/yr until gated |
| 3 | **Unused / undeclared SPM + target dependencies** (`xcpurge deps`): import graph per module vs declared `dependencies:` / Link phase. Report redundant and implicit deps. | high | M | Tuist `inspect dependencies` has open FP issues (#7335, #7281, #12702); Swift Forums request unanswered; Bitrise: 0.8–3 MB per unused embedded framework |
| 4 | **"Ignore no longer needed" warnings**: flag `.xcpurgeignore` / `xcpurge:ignore` entries that match nothing. Include in baseline. | high | S | Periphery #427 (10 reactions), shipped 2026-01, then got its own FP stream; Android R8 config analyzer |
| 5 | **Git-history enrichment**: per finding show last-touched date and author (`git log -1`), "dead since" (last reference removed in commit X). Bucket "unfinished feature" vs "garbage". Owner column in HTML report. | high | S | Lyft "chasing code owners"; Uber Piranha routes to flag author; Reddit "unused ≠ worthless" triage |
| 6 | **Localization integrity** (strings category extension): placeholder mismatch (`%@` count/order per language), missing plural forms, stale translations (source changed, translation not), unlocalized `InfoPlist.strings` keys, `.strings` vs `.xcstrings` migration leftovers. | medium-high | M | Reddit 2026 xcstrings linter thread; Tinder per-file ~4 KB overhead; SwiftGen #1065 (66 reactions) for xcstrings |
| 7 | **Per-language / per-asset-type size attribution**: size by `.lproj`, by raster vs vector vs PDF, largest rasters with "vectorize / SF Symbol" hint, universal vs thinned estimate. | medium | S-M | Reddit 70 MB→10.7 MB by vectorizing; Icon Composer bloat threads (1.3k views); "universal size misleads" |
| 8 | **Verify mode**: after `--delete`/`remove`, build affected scheme (and optionally run tests); auto-restore the session on failure. | medium | M | Reddit dead-code skill reverts on failed tests; Periphery `--auto-remove` asks (#666, #703) |
| 9 | **Xcode build-phase recipe + run-script helper**: `xcpurge init --xcode-phase` inserts a Run Script phase emitting `--format xcode` warnings, incremental via cache, no aggregate target. | medium | S | Periphery #600 (28 reactions, open in Pro); Adam Wulf's aggregate-target hack; Reddit "couldn't get warnings inline" |
| 10 | **Agent / LLM interface**: `--format agent` (compact prompt-ready), stable JSON schema doc, `xcpurge explain <path>` (why flagged, every evidence site), optional MCP server. | medium | S-M | Periphery Pro ships `agent-prompt`; Reddit "can my claude code agent use it?"; AI-generated dead code complaints |
| 11 | **Runtime-usage import**: accept a list of classes / image names / string keys actually loaded in production (Reaper-style export or a tiny instrumentation hook) and cross-check static findings → "unused in prod" tier. | medium | M-L | Duolingo: 2,684 of 8,567 classes unused, static tools missed them; Reaper now OSS under Sentry, self-host only |
| 12 | **Cross-target duplicate resource bundles**: detect same SPM resource bundle / asset catalog copied into app + extensions; report bytes wasted and the fix (shared framework). | medium | M | Lyft catalog copied 73× (~35 MB); Apple Forums 749265 (2.1k views) workaround threads |
| 13 | **Scale / cache**: persistent reference-index cache keyed by file hash, `--changed-since <ref>` incremental mode for PR runs on 10k+ file repos. | medium | M | Periphery #928 (30 GB cache), #960, #977, #582; your 28 GB tree scan |
| 14 | **Unused imports** (per file, with `@_exported` and extension/operator leakage awareness). | low-medium | M | SwiftLint `unused_import` FPs; forums "strict imports" thread; risky without a type checker |
| 15 | **SARIF output** for GitHub code scanning / SonarQube. | low | S | Reddit linter thread asked; no competitor has it |

## Already covered by xcpurge (don't rebuild)

Synced folders / local packages (Periphery #828, 28 reactions), asset symbol accessors (FengNiao #3, LSUnusedResources #51),
plist/IB/custom-bundle references (FengNiao #10/#46/#57), dynamic-name downgrade (FengNiao #63), per-kind config,
undo via trash, no-build scan, JSON/xcode/github output, xcstrings key detection with `extractionState`.

## Suggested bundles

- **CI bundle** (1 + 2 + 4 + 9): makes xcpurge a standing gate instead of a one-off. Mostly small changes.
- **Trust bundle** (5 + 8 + 10): answers "why is this flagged, who owned it, is it safe", the top adoption blocker everywhere.
- **New detectors** (3 + 6 + 12): categories nobody ships open-source today.
