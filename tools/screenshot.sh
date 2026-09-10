#!/usr/bin/env bash
#
# screenshot.sh - grab what is actually on the Kindle's e-ink panel, over SSH.
#
#   ./tools/screenshot.sh [output.png]
#
# Reads /dev/fb0 on the device and converts it locally. This is the fastest way to
# see what the display is doing - including when the screen is black, wedged, or
# showing a window at the wrong size. It needs no software on the Kindle.
#
# Configure the connection with environment variables:
#
#   KINDLE_HOST   hostname or IP of the Kindle   (required)
#   KINDLE_PORT   SSH port                       (default 22)
#   KINDLE_USER   SSH user                       (default root)
#   KINDLE_KEY    SSH private key                (default: agent / default key)
#
# Example:
#   KINDLE_HOST=kindle.local KINDLE_PORT=22 ./tools/screenshot.sh out.png
#
# Panel format measured on a PW5 (firmware 5.19.2):
#   1248x3296, 8bpp grayscale, stride 1248, rotate 3
#   two 1648-row frames; the visible one is the first
#
set -euo pipefail

OUT="${1:-screenshot.png}"
HOST="${KINDLE_HOST:?set KINDLE_HOST to the Kindle hostname or IP}"
PORT="${KINDLE_PORT:-22}"
KUSER="${KINDLE_USER:-root}"
KEY="${KINDLE_KEY:-}"

SSH_OPTS=(-p "$PORT" -o BatchMode=yes -o ConnectTimeout=10)
SCP_OPTS=(-q -P "$PORT" -o BatchMode=yes)
if [ -n "$KEY" ]; then
  SSH_OPTS+=(-i "$KEY")
  SCP_OPTS+=(-i "$KEY")
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "reading /dev/fb0 from ${KUSER}@${HOST} ..."
ssh "${SSH_OPTS[@]}" "$KUSER@$HOST" 'dd if=/dev/fb0 of=/tmp/.shot.raw bs=64k 2>/dev/null'
scp "${SCP_OPTS[@]}" "$KUSER@$HOST:/tmp/.shot.raw" "$TMP/fb.raw"
ssh "${SSH_OPTS[@]}" "$KUSER@$HOST" 'rm -f /tmp/.shot.raw'

python3 - "$TMP/fb.raw" "$OUT" <<'PY'
import sys
from PIL import Image
raw, out = sys.argv[1], sys.argv[2]
img = Image.frombytes('L', (1248, 3296), open(raw, 'rb').read()).crop((0, 0, 1236, 1648))
img.save(out)
print(f"wrote {out} ({img.width}x{img.height})")
PY
