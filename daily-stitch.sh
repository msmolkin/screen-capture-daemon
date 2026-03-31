#!/bin/bash
# daily-stitch.sh — Concatenate all screen capture segments from a given day into one video per screen
# Usage: daily-stitch.sh [YYYY-MM-DD] [SCREEN_LABEL]
#   Stitch all screens from the date, or just a specific screen if SCREEN_LABEL is provided
#   SCREEN_LABEL format: "screen1", "screen2", etc. (optional)

set -euo pipefail

PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

FFMPEG_BIN="$(command -v ffmpeg || true)"
if [ -z "$FFMPEG_BIN" ]; then
  echo "ffmpeg not found in PATH=$PATH"
  exit 1
fi
FFPROBE_BIN="$(command -v ffprobe || true)"
if [ -z "$FFPROBE_BIN" ]; then
  echo "ffprobe not found in PATH=$PATH"
  exit 1
fi

CAPTURE_DIR="$HOME/screen-recordings"
DATE="${1:-$(date -v-1d +%Y-%m-%d)}"
SPECIFIC_PREFIX="${2:-}"
DAY_DIR="$CAPTURE_DIR/$DATE"

if [ ! -d "$DAY_DIR" ]; then
  echo "No captures found for $DATE at $DAY_DIR"
  exit 0
fi

# Function to check if an mp4 is valid.
is_valid_mp4() {
  local file="$1"
  if [ ! -s "$file" ]; then
    return 1
  fi
  "$FFPROBE_BIN" -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1 "$file" >/dev/null 2>&1
}

# Identify all groups to stitch.
if [ -n "$SPECIFIC_PREFIX" ]; then
  STITCH_GROUPS="$SPECIFIC_PREFIX"
else
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

  ALL_SEGMENTS=$(find "$DAY_DIR" -name "$PATTERN" -type f | sort)

  VALID_SEGMENTS=()
  for f in $ALL_SEGMENTS; do
    if is_valid_mp4 "$f"; then
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
    done >"$CONCAT_LIST"

    "$FFMPEG_BIN" -nostdin -f concat -safe 0 -i "$CONCAT_LIST" -c copy -y "$OUTPUT" </dev/null
    rm "$CONCAT_LIST"
    echo "[$GROUP] Stitched $SEGMENT_COUNT segments into $OUTPUT"
  fi

  SIZE=$(du -h "$OUTPUT" | cut -f1)
  echo "[$GROUP] Final video: $OUTPUT ($SIZE)"
done
