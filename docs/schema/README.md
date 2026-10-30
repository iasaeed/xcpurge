# xcpurge output schemas

`findings-v2.schema.json` (JSON Schema draft 2020-12) describes the document that `xcpurge scan`, `assets`,
`strings` and `files` write with `--format json`: `schemaVersion`, `tool`, `root`, `modules`, `summary`, `size`,
`findings` (each with its stable `id`, and `history` when `--git` ran), `diagnostics`, and `baseline` when
`--baseline` was applied. The HTML report embeds the same document, so a saved `.json` can be re-rendered.

Validate a report with any draft 2020-12 validator, for example:

```sh
xcpurge scan . --format json > report.json
npx ajv-cli validate -s docs/schema/findings-v2.schema.json -d report.json --spec=draft2020
```

`SchemaTests` in this repository walks every fixture's output and asserts that each key path, type and enum
value is declared here, so the file cannot drift from the code.

## Version policy

- `schemaVersion` is an integer. Adding an **optional** field, a new enum value for `kind`, `category`,
  `history.status` or `history.bucket`, or a new diagnostic message keeps the number. Consumers must ignore
  unknown keys and unknown enum values. 0.4 added `id`, `history` and `baseline` this way; the version stayed 2.
- Removing or renaming a key, changing a type, making an optional key required, or changing the meaning of a
  value bumps the number and ships a new `findings-v<N>.schema.json` next to the old one. The old file stays.
- A new enum value is announced in the CHANGELOG; the JSON Schema `enum` lists are updated in the same commit.
- Finding `id`s are stable across runs for the same tree: kebab-case kind plus 10 hex digits of FNV-1a-64 over
  the identity key (`kind|module|name`, never a line number) and the path. Renaming or moving a file changes it.
- `--format agent` is a separate, line-oriented view of the same findings. Its first line carries its own
  version (`# xcpurge agent report v1`). Adding a line or a `key=value` to a row keeps `v1`; changing the shape
  of an existing line bumps it.
- `xcpurge explain --format json` has its own `schemaVersion` (1) with the same rules: optional additions keep
  it, removals and renames bump it.
- `xcpurge size` snapshots (`schemaVersion` 1) and `.xcpurge-baseline.json` (`version` 1) follow the same policy.
