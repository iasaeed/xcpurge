$ xcpurge size Tests/Fixtures/ModularWorkspace --save size-base.json   # on main
$ # ... a PR adds 3 KB to widget_icon.imageset ...
$ xcpurge size . --compare size-base.json --format markdown
<!-- xcpurge-size -->
### xcpurge size: +2.9 KB (+9.1%)

Source-tree bytes (files in the repository), not shipped bytes.

|  | Base | PR | Change |
|---|---:|---:|---:|
| Whole tree | 32.1 KB | 35.1 KB | +2.9 KB (+9.1%) |
| Asset catalogs | 17.3 KB | 20.3 KB | +2.9 KB (+16.9%) |
| Loose images | 0 B | 0 B | no change |
| Fonts | 112 B | 112 B | no change |
| Strings | 3.5 KB | 3.5 KB | no change |
| Interface Builder | 4.1 KB | 4.1 KB | no change |
| Other resources | 2.2 KB | 2.2 KB | no change |
| Source | 3.9 KB | 3.9 KB | no change |
| Other files | 1.0 KB | 1.0 KB | no change |

<details><summary>Modules (6)</summary>

| Module | Base | PR | Change |
|---|---:|---:|---:|
| App/App.xcodeproj:App | 26.2 KB | 26.2 KB | no change |
| App/App.xcodeproj:AppWidget | 1.9 KB | 4.9 KB | +2.9 KB (+152.1%) |
| Packages/DesignSystem:DesignSystem | 2.4 KB | 2.4 KB | no change |
| Packages/Core:Core | 921 B | 921 B | no change |
| (unattributed) | 865 B | 865 B | no change |
| App/App.xcodeproj:AppTests | 331 B | 331 B | no change |

</details>

**Top changes** (|change| ≥ 500 B; grown and shrunk)

| Path | Base | PR | Change |
|---|---:|---:|---:|
| `App/AppWidget/Assets.xcassets/widget_icon.imageset` | 231 B | 3.2 KB | +2.9 KB (+1298.7%) |

Reclaimable (high+medium): 9.1 KB → 9.1 KB

<sub>xcpurge 0.4.0 · this comment is edited in place on each push.</sub>
