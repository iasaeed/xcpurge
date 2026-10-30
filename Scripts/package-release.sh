#!/bin/sh
# Builds the release archive the sample workflows download:
#   .build/package/xcpurge-macos.tar.gz          `xcpurge` at the archive root (so `tar -xzf … -C bin` installs it)
#   .build/package/xcpurge-macos.tar.gz.sha256   `shasum -a 256` line for the release notes / Homebrew formula
# The binary is universal (arm64 + x86_64) when the toolchain can build both; otherwise the host architecture alone,
# with a warning. Run via `make package`, then attach both files to the GitHub release `v<version>`.
set -eu
cd "$(dirname "$0")/.."
out=${OUT:-.build/package}
name=xcpurge-macos.tar.gz

if swift build -c release --arch arm64 --arch x86_64 >/dev/null 2>&1; then
    bin=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/xcpurge
    kind=universal
else
    echo "warning: universal build failed; building for $(uname -m) only" >&2
    swift build -c release
    bin=$(swift build -c release --show-bin-path)/xcpurge
    kind=$(uname -m)
fi
[ -x "$bin" ] || { echo "error: $bin was not built" >&2; exit 1; }

rm -rf "$out" && mkdir -p "$out"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp "$bin" "$stage/xcpurge"
chmod 755 "$stage/xcpurge"
# A fixed owner, mode and mtime keep the archive reproducible for the same binary.
if tar --version 2>/dev/null | grep -q GNU; then
    tar -C "$stage" --owner=0 --group=0 --numeric-owner -czf "$out/$name" xcpurge
else
    tar -C "$stage" --uid 0 --gid 0 --numeric-owner -czf "$out/$name" xcpurge
fi
(cd "$out" && shasum -a 256 "$name" > "$name.sha256")
version=$("$stage/xcpurge" --version 2>/dev/null || echo unknown)
echo "wrote $out/$name ($kind, xcpurge $version) and $out/$name.sha256"
cat "$out/$name.sha256"
