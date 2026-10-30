#!/bin/sh
# Builds the release archive the sample workflows download:
#   .build/package/xcpurge-macos.tar.gz          `xcpurge` at the archive root (so `tar -xzf … -C bin` installs it)
#   .build/package/xcpurge-macos.tar.gz.sha256   `shasum -a 256` line; the workflows verify it before extracting
# The binary is universal (arm64 + x86_64). A universal build that fails stops the script, unless ALLOW_HOST_ONLY=1
# accepts a host-architecture-only archive (local testing; never for a published release).
# XCPURGE_PACKAGE_DIR picks the output folder (default .build/package; must stay inside .build/, it is wiped).
# The archive is reproducible for the same binary: owner 0:0, mode 755, mtime SOURCE_DATE_EPOCH (default: the
# commit date of HEAD), gzip without a timestamp.
# Run via `make package`, then attach both files to the GitHub release `v<version>`.
set -eu
cd "$(dirname "$0")/.."
out=${XCPURGE_PACKAGE_DIR:-.build/package}
case "$out" in
    .build/?*|"$PWD"/.build/?*) ;;
    *) echo "error: XCPURGE_PACKAGE_DIR must be a folder inside .build/ (got '$out'); it is removed and recreated" >&2; exit 2 ;;
esac
case "$out" in *..*) echo "error: XCPURGE_PACKAGE_DIR must not contain '..'" >&2; exit 2 ;; esac
name=xcpurge-macos.tar.gz

if swift build -c release --arch arm64 --arch x86_64; then
    bin=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/xcpurge
    kind=universal
elif [ "${ALLOW_HOST_ONLY:-}" = 1 ]; then
    echo "warning: universal build failed; ALLOW_HOST_ONLY=1, building for $(uname -m) only (not a release artifact)" >&2
    swift build -c release
    bin=$(swift build -c release --show-bin-path)/xcpurge
    kind=$(uname -m)
else
    echo "error: universal (arm64 + x86_64) build failed; fix the toolchain, or set ALLOW_HOST_ONLY=1 for a local, host-only archive" >&2
    exit 1
fi
[ -x "$bin" ] || { echo "error: $bin was not built" >&2; exit 1; }

rm -rf "$out" && mkdir -p "$out"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp "$bin" "$stage/xcpurge"
chmod 755 "$stage/xcpurge"
epoch=${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)}
touch -t "$(date -u -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null || date -u -d "@$epoch" +%Y%m%d%H%M.%S)" "$stage/xcpurge"
# bsdtar (macOS) and GNU tar spell the owner flags differently; `gzip -n` leaves out the gzip header timestamp.
if tar --version 2>/dev/null | grep -q GNU; then
    tar -C "$stage" --owner=0 --group=0 --numeric-owner -cf - xcpurge | gzip -n -9 > "$out/$name"
else
    tar -C "$stage" --uid 0 --gid 0 --numeric-owner -cf - xcpurge | gzip -n -9 > "$out/$name"
fi
(cd "$out" && shasum -a 256 "$name" > "$name.sha256")
version=$("$stage/xcpurge" --version 2>/dev/null || echo unknown)
echo "wrote $out/$name ($kind, xcpurge $version, mtime $epoch) and $out/$name.sha256"
cat "$out/$name.sha256"
