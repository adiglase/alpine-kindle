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

FILES=(alpine.ext3 alpine.sh alpine.conf)
[ -f swap.img ] && FILES+=(swap.img)

rm -f alpine.zip
# -1: the free space in the ext3 image is zeros and compresses fine already;
# a higher level just costs build time here.
zip -1 -q alpine.zip "${FILES[@]}"

echo "Release:  $ZIP  ($(du -h "$ZIP" | cut -f1))"
sha256sum alpine.zip
