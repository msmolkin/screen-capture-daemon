#!/bin/bash
# daily-stitch.sh — Concatenate all screen capture segments from a given day into one video per screen
# Usage: daily-stitch.sh [YYYY-MM-DD] [SCREEN_LABEL]
#   Stitch all screens from the date, or just a specific screen if SCREEN_LABEL is provided
#   SCREEN_LABEL format: "screen1", "screen2", etc. (optional)

set -euo pipefail

CAPTURE_DIR="$HOME/screen-recordings"
DATE="${1:-$(date -v-1d +%Y-%m-%d)}"
SPECIFIC_SCREEN="${2:-}"
DAY_DIR="$CAPTURE_DIR/$DATE"

if [ ! -d "$DAY_DIR" ]; then
  echo "No captures found for $DATE at $DAY_DIR"
  exit 0
fi

# If a specific screen was requested, only stitch that one
if [ -n "$SPECIFIC_SCREEN" ]; then
  SCREENS="$SPECIFIC_SCREEN"
else
  # Find all unique screen labels (e.g. "screen1", "screen2")
  SCREENS=$(find "$DAY_DIR" -name "capture-screen*-*.mp4" -type f | sed -E 's/.*capture-(screen[0-9]+)-.*/\1/' | sort -u)

  # Fallback for old format without screen label
  if [ -z "$SCREENS" ]; then
    SCREENS="all"
  fi
fi

for SCREEN in $SCREENS; do
  if [ "$SCREEN" = "all" ]; then
    PATTERN="capture-*.mp4"
    OUTPUT="$CAPTURE_DIR/${DATE}-full.mp4"
  else
    PATTERN="capture-${SCREEN}-*.mp4"
    OUTPUT="$CAPTURE_DIR/${DATE}-${SCREEN}-full.mp4"
  fi

  SEGMENTS=$(find "$DAY_DIR" -name "$PATTERN" -type f | sort | wc -l | tr -d ' ')
  if [ "$SEGMENTS" -eq 0 ]; then
    echo "No segments for $SCREEN on $DATE"
    continue
  fi

  if [ "$SEGMENTS" -eq 1 ]; then
    cp "$DAY_DIR"/$PATTERN "$OUTPUT"
    echo "[$SCREEN] Single segment copied to $OUTPUT"
  else
    CONCAT_LIST="$DAY_DIR/concat-${SCREEN}.txt"
    find "$DAY_DIR" -name "$PATTERN" -type f | sort | while read -r f; do
      echo "file '$f'"
    done > "$CONCAT_LIST"

    ffmpeg -f concat -safe 0 -i "$CONCAT_LIST" -c copy -y "$OUTPUT"
    rm "$CONCAT_LIST"
    echo "[$SCREEN] Stitched $SEGMENTS segments into $OUTPUT"
  fi

  SIZE=$(du -h "$OUTPUT" | cut -f1)
  echo "[$SCREEN] Final video: $OUTPUT ($SIZE)"
done
