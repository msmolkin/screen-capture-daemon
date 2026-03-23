#!/bin/bash
# daily-stitch.sh — Concatenate all screen and webcam segments from a given day into full videos
# Usage: daily-stitch.sh [YYYY-MM-DD] [PREFIX]
#   Stitch all screen/webcam groups from the date, or just a specific prefix if provided
#   PREFIX examples: "screen1", "webcam" (optional)

set -euo pipefail

CAPTURE_DIR="$HOME/screen-recordings"
DATE="${1:-$(date -v-1d +%Y-%m-%d)}"
SPECIFIC_PREFIX="${2:-}"
DAY_DIR="$CAPTURE_DIR/$DATE"

if [ ! -d "$DAY_DIR" ]; then
  echo "No captures found for $DATE at $DAY_DIR"
  exit 0
fi

# Function to check if an mp4 is valid (not 0-byte or corrupted)
is_valid_mp4() {
  local file="$1"
  if [ ! -s "$file" ]; then return 1; fi
  ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1 "$file" >/dev/null 2>&1
}

# Identify all groups to stitch (screens and webcams)
if [ -n "$SPECIFIC_PREFIX" ]; then
  # Ensure prefix matches the internal labeling logic
  if [[ "$SPECIFIC_PREFIX" == screen* ]]; then
    STITCH_GROUPS="$SPECIFIC_PREFIX"
  else
    STITCH_GROUPS="$SPECIFIC_PREFIX"
  fi
else
  # Find all unique screen labels (e.g. "screen1", "screen5") and "webcam"
  SCREEN_STITCH_GROUPS=$(find "$DAY_DIR" -name "capture-screen*-*.mp4" -type f | sed -E 's/.*capture-(screen[0-9]+)-.*/\1/' | sort -u)
  WEBCAM_STITCH_GROUPS=$(find "$DAY_DIR" -name "webcam-*.mp4" -type f | sed -E 's/.*webcam-.*/webcam/' | sort -u)
  STITCH_GROUPS=$(echo -e "$SCREEN_STITCH_GROUPS\n$WEBCAM_STITCH_GROUPS" | grep . || echo "")
fi

if [ -z "$STITCH_GROUPS" ]; then
  echo "No recordable segments found for $DATE"
  exit 0
fi

for GROUP in $STITCH_GROUPS; do
  if [[ "$GROUP" == screen* ]]; then
    PATTERN="capture-${GROUP}-*.mp4"
    OUTPUT="$CAPTURE_DIR/${DATE}-${GROUP}-full.mp4"
  elif [[ "$GROUP" == "webcam" ]]; then
    PATTERN="webcam-*.mp4"
    OUTPUT="$CAPTURE_DIR/${DATE}-webcam-full.mp4"
  else
    continue
  fi

  # Find all potential segments for this group
  ALL_SEGMENTS=$(find "$DAY_DIR" -name "$PATTERN" -type f | sort)
  
  # Filter out corrupted segments automatically
  VALID_SEGMENTS=()
  for f in $ALL_SEGMENTS; do
    if is_valid_mp4 "$f" ; then
      VALID_SEGMENTS+=("$f")
    else
      echo "[$GROUP] WARNING: Skipping corrupted or empty segment: $(basename "$f")"
    fi
  done

  SEGMENT_COUNT=${#VALID_SEGMENTS[@]}
  if [ "$SEGMENT_COUNT" -eq 0 ]; then
    echo "[$GROUP] No valid segments for $GROUP on $DATE"
    continue
  fi

  if [ "$SEGMENT_COUNT" -eq 1 ]; then
    cp "${VALID_SEGMENTS[0]}" "$OUTPUT"
    echo "[$GROUP] Single segment copied to $OUTPUT"
  else
    CONCAT_LIST="$DAY_DIR/concat-${GROUP}.txt"
    for f in "${VALID_SEGMENTS[@]}"; do
      echo "file '$f'"
    done > "$CONCAT_LIST"

    ffmpeg -f concat -safe 0 -i "$CONCAT_LIST" -c copy -y "$OUTPUT"
    rm "$CONCAT_LIST"
    echo "[$GROUP] Stitched $SEGMENT_COUNT segments into $OUTPUT"
  fi

  SIZE=$(du -h "$OUTPUT" | cut -f1)
  echo "[$GROUP] Final video: $OUTPUT ($SIZE)"
done
