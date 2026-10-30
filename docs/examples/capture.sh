#!/bin/bash
# Regenerates the captures in docs/examples/ that the README quotes.
# Run from the repository root after `swift build -c release`:
#   docs/examples/capture.sh            # writes into docs/examples/
#   OUT=/tmp/caps docs/examples/capture.sh
# DEMO (default /tmp/demo) must not exist: the safe-delete demo copies ClassicApp there.
# Timings, trash session IDs and the scan root differ from run to run; the absolute
# checkout path is replaced by /path/to/xcpurge.
set -euo pipefail
X="$PWD/.build/release/xcpurge"
OUT=${OUT:-docs/examples}
DEMO=${DEMO:-/tmp/demo}
export NO_COLOR=1
mkdir -p "$OUT"
anon() { sed "s#$PWD#/path/to/xcpurge#g"; }

cap() { # cap <file> <xcpurge args...>
  local file=$1; shift
  { echo "\$ xcpurge $*"; "$X" "$@"; } 2>&1 | anon > "$OUT/$file"
}
cap scan-modularworkspace.txt    scan    Tests/Fixtures/ModularWorkspace
cap modules-modularworkspace.txt modules Tests/Fixtures/ModularWorkspace
cap modules-crossproject.txt     modules Tests/Fixtures/CrossProject
cap strings-modularworkspace.txt strings Tests/Fixtures/ModularWorkspace
cap files-classicapp.txt         files   Tests/Fixtures/ClassicApp
cap files-mixedapp.txt           files   Tests/Fixtures/MixedApp
cap size-modularworkspace.txt    size    Tests/Fixtures/ModularWorkspace
cap html-report-modularworkspace.txt scan Tests/Fixtures/ModularWorkspace --format html --output /tmp/xcpurge-report.html
cap init-xcode-phase.txt         init    --xcode-phase

# Size PR comment: base snapshot of the fixture, then a copy with one image grown by 3 KB.
SIZEDEMO=$(mktemp -d)
cp -R Tests/Fixtures/ModularWorkspace "$SIZEDEMO/mw"
"$X" size "$SIZEDEMO/mw" --save "$SIZEDEMO/base.json" --quiet > /dev/null
head -c 3000 /dev/urandom >> "$SIZEDEMO/mw/App/AppWidget/Assets.xcassets/widget_icon.imageset/widget_icon.png"
{ echo "\$ xcpurge size Tests/Fixtures/ModularWorkspace --save size-base.json   # on main"
  echo "\$ # ... a PR adds 3 KB to widget_icon.imageset ..."
  echo "\$ xcpurge size . --compare size-base.json --format markdown"
  "$X" size "$SIZEDEMO/mw" --compare "$SIZEDEMO/base.json" --format markdown 2>/dev/null | sed "s#$SIZEDEMO/mw#/path/to/xcpurge/Tests/Fixtures/ModularWorkspace#g"
} > "$OUT/size-markdown-modularworkspace.md"
rm -rf "$SIZEDEMO"

# Live progress: stderr must be a terminal, stdout goes to /dev/null.
script -q "$OUT/progress-tty.raw" sh -c "'$X' scan Tests/Fixtures/ModularWorkspace --format json > /dev/null" < /dev/null > /dev/null 2>&1 || true
{ echo "\$ script -q tty.raw sh -c 'xcpurge scan Tests/Fixtures/ModularWorkspace --format json > /dev/null'; cat -v tty.raw"
  cat -v "$OUT/progress-tty.raw"; } > "$OUT/progress-tty-raw.txt"
perl -pe 's/\e\[[0-9;]*[A-Za-z]//g; s/\r/\n/g' "$OUT/progress-tty.raw" | grep -av '^\s*$' | grep -av '^\^D' > "$OUT/progress-tty-clean.txt"
rm "$OUT/progress-tty.raw"

# Safe delete and restore on a throwaway git copy of ClassicApp.
[ ! -e "$DEMO" ] || { echo "$DEMO exists; remove it or set DEMO" >&2; exit 2; }
cp -R Tests/Fixtures/ClassicApp "$DEMO"
(
  cd "$DEMO" && git init -q && git add -A && git commit -qm base
  run() { echo "\$ $*"; "$@"; }
  x() { echo "\$ xcpurge $*"; "$X" "$@"; }
  echo "\$ cp -R Tests/Fixtures/ClassicApp $DEMO && cd $DEMO && git init -q && git add -A && git commit -qm base"
  run git status --short
  x assets
  x assets --delete --yes
  run git status --short
  run git diff --stat
  x restore --list
  sid=$("$X" restore --list | awk 'NR==1{print $1}')
  x restore --session "$sid"
  run git status --short
  echo "# (no output: the tree matches the base commit again)"
) > "$OUT/safe-delete-classicapp.txt" 2>&1
for f in xcode github; do
  (cd "$DEMO" && echo "\$ cd $DEMO" && echo "\$ xcpurge files --format $f" && "$X" files --format $f) > "$OUT/format-$f-classicapp.txt"
done
echo "wrote $OUT"
