#!/usr/bin/env bash
#
# create-release.sh - pack the built image + Kindle-side scripts into alpine.zip
# Derived from schuhumi/alpine_kindle (GPL-3.0) - see README.md.
#
# Run after build-image.sh (which calls this for you).
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTDIR="$HERE/release"
ZIP="$OUTDIR/alpine.zip"

cd "$OUTDIR"
[ -f alpine.ext3 ] || { echo "alpine.ext3 not found - run build-image.sh first." >&2; exit 1; }

# Stage every on-Kindle file here as part of packaging. Keeping this in the
# release step (rather than only in build-image.sh) means a maintainer can fix a
# launcher or document and repack without rebuilding the 2.5 GiB image.
cp "$HERE/alpine.sh" "$OUTDIR/alpine.sh"
cp "$HERE/contrib/alpine.conf" "$OUTDIR/alpine.conf"
cp "$HERE/tools/install.sh" "$OUTDIR/install.sh"
cp "$HERE/tools/uninstall.sh" "$OUTDIR/uninstall.sh"
cp "$HERE/tools/diag.sh" "$OUTDIR/diag.sh"
mkdir -p "$OUTDIR/alpine-kindle-docs"
cp "$HERE/README.md" "$OUTDIR/alpine-kindle-docs/README.md"
cp "$HERE/LICENSE" "$OUTDIR/alpine-kindle-docs/LICENSE"
cp "$HERE/docs/COMPATIBILITY.md" "$OUTDIR/alpine-kindle-docs/COMPATIBILITY.md"
cp "$HERE/docs/KNOWN-ISSUES.md" "$OUTDIR/alpine-kindle-docs/KNOWN-ISSUES.md"
cp "$HERE/docs/TROUBLESHOOTING.md" "$OUTDIR/alpine-kindle-docs/TROUBLESHOOTING.md"

FILES=(alpine.ext3 alpine.sh alpine.conf install.sh uninstall.sh diag.sh
       alpine-kindle-docs/README.md alpine-kindle-docs/LICENSE
       alpine-kindle-docs/COMPATIBILITY.md
       alpine-kindle-docs/KNOWN-ISSUES.md
       alpine-kindle-docs/TROUBLESHOOTING.md)
[ -f swap.img ] && FILES+=(swap.img)

rm -f alpine.zip
# -1: the free space in the ext3 image is zeros and compresses fine already;
# a higher level just costs build time here.
zip -1 -q alpine.zip "${FILES[@]}"

echo "Release:  $ZIP  ($(du -h "$ZIP" | cut -f1))"
sha256sum alpine.zip
