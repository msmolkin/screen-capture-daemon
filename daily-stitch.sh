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

# Function to check if an mp4 is valid (not 0-byte or corrupted)
is_valid_mp4() {
  local file="$1"
  if [ ! -s "$file" ]; then return 1; fi
  # Fast check with ffprobe for moov atom/headers
  ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1 "$file" >/dev/null 2>&1
}

for SCREEN in $SCREENS; do
  if [ "$SCREEN" = "all" ]; then
    PATTERN="capture-*.mp4"
    OUTPUT="$CAPTURE_DIR/${DATE}-full.mp4"
  else
    PATTERN="capture-${SCREEN}-*.mp4"
    OUTPUT="$CAPTURE_DIR/${DATE}-${SCREEN}-full.mp4"
  fi

  # Find all potential segments
  ALL_SEGMENTS=$(find "$DAY_DIR" -name "$PATTERN" -type f | sort)
  
  # Filter out corrupted segments automatically
  VALID_SEGMENTS=()
  for f in $ALL_SEGMENTS; do
    if is_valid_mp4 "$f" ; then
      VALID_SEGMENTS+=("$f")
    else
      echo "[$SCREEN] WARNING: Skipping corrupted or empty segment: $(basename "$f")"
    fi
  done

  SEGMENT_COUNT=${#VALID_SEGMENTS[@]}
  if [ "$SEGMENT_COUNT" -eq 0 ]; then
    echo "[$SCREEN] No valid segments for $SCREEN on $DATE"
    continue
  fi

  if [ "$SEGMENT_COUNT" -eq 1 ]; then
    cp "${VALID_SEGMENTS[0]}" "$OUTPUT"
    echo "[$SCREEN] Single segment copied to $OUTPUT"
  else
    CONCAT_LIST="$DAY_DIR/concat-${SCREEN}.txt"
    for f in "${VALID_SEGMENTS[@]}"; do
      echo "file '$f'"
    done > "$CONCAT_LIST"

    ffmpeg -f concat -safe 0 -i "$CONCAT_LIST" -c copy -y "$OUTPUT"
    rm "$CONCAT_LIST"
    echo "[$SCREEN] Stitched $SEGMENT_COUNT segments into $OUTPUT"
  fi

  SIZE=$(du -h "$OUTPUT" | cut -f1)
  echo "[$SCREEN] Final video: $OUTPUT ($SIZE)"
done
