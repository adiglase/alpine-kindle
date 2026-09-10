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
BUILD_INFO="$OUTDIR/BUILD-INFO.txt"
CHECKSUM="$OUTDIR/alpine.zip.sha256"

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

# Record enough information to identify and reproduce every published image.
# debugfs keeps repacking independent of build-image.sh and does not mount the image.
ALPINE_RELEASE="$(debugfs -R 'cat /etc/alpine-release' alpine.ext3 2>/dev/null | tr -d '\r\n')"
[ -n "$ALPINE_RELEASE" ] || { echo "Could not read /etc/alpine-release from alpine.ext3." >&2; exit 1; }
SOURCE_COMMIT="${SOURCE_COMMIT:-$(
  git -c safe.directory="$HERE" -C "$HERE" rev-parse HEAD 2>/dev/null || printf 'unknown'
)}"
cat > "$BUILD_INFO" <<EOF
Alpine Kindle release build
Source tag: ${RELEASE_TAG:-local build}
Source commit: $SOURCE_COMMIT
Alpine branch: ${ALPINE_BRANCH:-unknown}
Alpine release: $ALPINE_RELEASE
Architecture: ${ARCH:-armv7}
Image size: ${IMAGESIZE_MB:-unknown} MiB
Swap size: ${SWAP_MB:-unknown} MiB
Chromium included: ${WITH_CHROMIUM:-unknown}
EOF
cp "$BUILD_INFO" "$OUTDIR/alpine-kindle-docs/BUILD-INFO.txt"

FILES=(alpine.ext3 alpine.sh alpine.conf install.sh uninstall.sh diag.sh
       alpine-kindle-docs/README.md alpine-kindle-docs/LICENSE
       alpine-kindle-docs/BUILD-INFO.txt
       alpine-kindle-docs/COMPATIBILITY.md
       alpine-kindle-docs/KNOWN-ISSUES.md
       alpine-kindle-docs/TROUBLESHOOTING.md)
[ -f swap.img ] && FILES+=(swap.img)

rm -f alpine.zip
# -1: the free space in the ext3 image is zeros and compresses fine already;
# a higher level just costs build time here.
zip -1 -q alpine.zip "${FILES[@]}"
sha256sum alpine.zip > "$CHECKSUM"

echo "Release:  $ZIP  ($(du -h "$ZIP" | cut -f1))"
cat "$CHECKSUM"
