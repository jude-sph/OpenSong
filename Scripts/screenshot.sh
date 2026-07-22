#!/bin/bash
set -e
OUT="${1:-/tmp/opensong-shot.png}"
OPENSONG_SCREENSHOT=1 open build/OpenSong.app
sleep 6
screencapture -x "$OUT"
echo "captured $OUT"
