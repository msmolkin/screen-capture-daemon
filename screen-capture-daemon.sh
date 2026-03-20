#!/bin/bash
# screen-capture-daemon.sh — Captures all connected screens
# Re-enumerates screens on every restart, so it handles:
#   - Screen connect/disconnect
#   - Sleep/wake (ffmpeg dies on sleep, restarts on wake)
#   - Midnight rotation with daily stitching

# Prevent duplicate instances and handle stale lockfiles
LOCKFILE="/tmp/screen-capture-daemon-$(id -u).lock"
# Simple check for another running instance of this script
# Using pgrep to find other bash processes running this specific script
if pgrep -f "/usr/local/bin/screen-capture-daemon.sh" | grep -v "$$" > /dev/null; then
  echo "[$(date)] Another instance of screen-capture-daemon.sh is already running. Exiting."
  exit 0
fi

# If we reached here, no other daemon is running, so we can clear any stale lock
rmdir "$LOCKFILE" 2>/dev/null
if ! mkdir "$LOCKFILE" 2>/dev/null; then
  # Still failed? Likely a race condition with another starting instance
  exit 0
fi
trap 'rmdir "$LOCKFILE" 2>/dev/null' EXIT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CAPTURE_DIR="$HOME/screen-recordings"
LOG_DIR="$CAPTURE_DIR/logs"
mkdir -p "$LOG_DIR"

# Load FPS configuration if exists
CONFIG_FILE="$HOME/.config/screen-capture/config.env"
if [ -f "$CONFIG_FILE" ]; then
  source "$CONFIG_FILE"
fi

# Set default FPS if not provided by config
PRIMARY_FPS="${PRIMARY_FPS:-2}"
SECONDARY_FPS="${SECONDARY_FPS:-1/3}"

echo "[$(date)] Daemon starting (PID $$) with Primary FPS: $PRIMARY_FPS, Secondary FPS: $SECONDARY_FPS"

FFMPEG_PIDS=()

cleanup() {
  echo "[$(date)] Stopping screen capture daemon"
  if [ ${#FFMPEG_PIDS[@]} -gt 0 ]; then
    for pid in "${FFMPEG_PIDS[@]}"; do
      kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null
  fi
  exit 0
}
trap cleanup SIGTERM SIGINT

# Discover screen capture devices — returns device indices (e.g. "1 2")
# Uses a timeout to prevent hangs (ffmpeg -list_devices can freeze)
detect_screens() {
  local tmpfile
  tmpfile=$(mktemp)
  ( ffmpeg -f avfoundation -list_devices true -i "" 2>"$tmpfile" || true ) &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null && [ $waited -lt 10 ]; do
    sleep 1
    waited=$(( waited + 1 ))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    echo "[$(date)] WARNING: ffmpeg -list_devices hung (killed after 10s)" >> "$LOG_DIR/daemon-stdout.log"
    rm -f "$tmpfile"
    return
  fi
  wait "$pid" 2>/dev/null || true
  grep "Capture screen" "$tmpfile" | sed -E 's/.*\[([0-9]+)\].*/\1/'
  rm -f "$tmpfile"
}

OUTPUT_DIR_BASE="$CAPTURE_DIR"
COUNTER_FILE="/tmp/screen-capture-segment-counter-$(id -u).txt"

while true; do
  DATE=$(date +%Y-%m-%d)
  TIMESTAMP=$(date +%Y%m%d-%H%M%S)
  OUTPUT_DIR="$OUTPUT_DIR_BASE/$DATE"
  mkdir -p "$OUTPUT_DIR"

  # Load or initialize segment counter (per-day, per-user)
  if [ ! -f "$COUNTER_FILE" ]; then
    SEGMENT_COUNTER=0
    echo "$DATE:1" > "$COUNTER_FILE"
  else
    # Correctly read counter file to avoid errors
    IFS=':' read -r COUNTER_DATE COUNTER_VAL < "$COUNTER_FILE" || true
    if [ "$COUNTER_DATE" = "$DATE" ]; then
      SEGMENT_COUNTER="$COUNTER_VAL"
    else
      # New day, reset counter
      SEGMENT_COUNTER=0
      echo "$DATE:1" > "$COUNTER_FILE"
    fi
  fi
  SEGMENT_COUNTER=$(( SEGMENT_COUNTER + 1 ))
  echo "$DATE:$SEGMENT_COUNTER" > "$COUNTER_FILE"

  # Discover available screens
  SCREENS=$(detect_screens)
  if [ -z "$SCREENS" ]; then
    echo "[$(date)] No screens detected. Retrying in 10s..."
    sleep 10
    continue
  fi

  SCREEN_COUNT=$(echo "$SCREENS" | wc -l | tr -d ' ')
  echo "[$(date)] Detected $SCREEN_COUNT screen(s): $(echo $SCREENS | tr '\n' ' ')"

  # Calculate seconds until midnight
  NOW=$(date +%s)
  MIDNIGHT=$(date -j -f "%Y-%m-%d %H:%M:%S" "$(date -v+1d +%Y-%m-%d) 00:00:00" +%s 2>/dev/null || date -d "tomorrow 00:00" +%s)
  DURATION=$(( MIDNIGHT - NOW ))

  # Launch one ffmpeg per screen
  FFMPEG_PIDS=()
  for DEVICE in $SCREENS; do
    SCREEN_LABEL="screen${DEVICE}"
    # Include segment counter to avoid overwriting if screen reconnects same day
    OUTFILE="$OUTPUT_DIR/capture-${SCREEN_LABEL}-${TIMESTAMP}-seg${SEGMENT_COUNTER}.mp4"
    echo "[$(date)] Starting capture: $SCREEN_LABEL -> $(basename "$OUTFILE")"

    # Determine framerate configured via variables
    if [ "$DEVICE" = "1" ]; then
      FRAMERATE=$PRIMARY_FPS
      FPS_FILTER="fps=$PRIMARY_FPS"
    else
      FRAMERATE=$SECONDARY_FPS
      FPS_FILTER="fps=$SECONDARY_FPS"
    fi

    # Note: If screen is off/locked, avfoundation will capture black frames.
    # This is expected behavior. The capture will continue when display wakes.
    ffmpeg -f avfoundation -framerate "$FRAMERATE" -capture_cursor 1 -i "${DEVICE}:none" \
      -vf "${FPS_FILTER},scale=1920:-2" \
      -c:v libx264 -crf 28 -preset ultrafast -threads 1 \
      -movflags frag_keyframe+empty_moov \
      -t "$DURATION" \
      -y "$OUTFILE" \
      </dev/null >> "$LOG_DIR/${DATE}.log" 2>&1 &
    FFMPEG_PIDS+=($!)
  done

  # Wait for ANY ffmpeg to exit (screen disconnect, sleep, crash, or midnight)
  # Also check for NEW screens connecting (poll every 10 seconds)
  # When something changes, kill all and restart the loop to re-enumerate
  SCREEN_CHECK_COUNTER=0
  while true; do
    # Check if any ffmpeg has exited
    for i in "${!FFMPEG_PIDS[@]}"; do
      pid="${FFMPEG_PIDS[$i]}"
      if ! kill -0 "$pid" 2>/dev/null; then
        echo "[$(date)] ffmpeg (PID $pid) exited. Stopping all captures and re-enumerating..."
        for p in "${FFMPEG_PIDS[@]}"; do
          kill "$p" 2>/dev/null || true
        done
        wait 2>/dev/null
        FFMPEG_PIDS=()
        break 2
      fi
    done

    # Every 10 seconds, check if new screens have appeared
    SCREEN_CHECK_COUNTER=$(( SCREEN_CHECK_COUNTER + 1 ))
    if [ $(( SCREEN_CHECK_COUNTER % 2 )) -eq 0 ]; then
      NEW_SCREENS=$(detect_screens)
      if [ "$NEW_SCREENS" != "$SCREENS" ]; then
        echo "[$(date)] Screen configuration changed: was [$SCREENS] now [$NEW_SCREENS]. Re-enumerating..."

        # If a screen was disconnected, stitch its recording
        # Kill ffmpeg FIRST (before stitching) with SIGKILL fallback
        for p in "${FFMPEG_PIDS[@]}"; do
          kill "$p" 2>/dev/null || true
        done
        sleep 2
        for p in "${FFMPEG_PIDS[@]}"; do
          kill -9 "$p" 2>/dev/null || true
        done
        wait 2>/dev/null
        FFMPEG_PIDS=()

        # Then stitch disconnected screens (ffmpeg is no longer writing)
        for OLD_SCREEN in $SCREENS; do
          FOUND=0
          for NEW_SCREEN in $NEW_SCREENS; do
            if [ "$OLD_SCREEN" = "$NEW_SCREEN" ]; then
              FOUND=1
              break
            fi
          done
          if [ $FOUND -eq 0 ]; then
            echo "[$(date)] Screen $OLD_SCREEN disconnected. Stitching today's segments..."
            "$SCRIPT_DIR/daily-stitch.sh" "$DATE" "screen$OLD_SCREEN" >> "$LOG_DIR/${DATE}.log" 2>&1 || true
          fi
        done

        break
      fi
    fi

    sleep 5

    # Midnight watchdog: ffmpeg -t pauses during sleep, so force rotate at midnight
    CURRENT_DATE=$(date +%Y-%m-%d)
    if [ "$CURRENT_DATE" != "$DATE" ]; then
      echo "[$(date)] Midnight crossed. Rotating..."
      for p in "${FFMPEG_PIDS[@]}"; do
        kill "$p" 2>/dev/null || true
      done
      sleep 2
      for p in "${FFMPEG_PIDS[@]}"; do
        kill -9 "$p" 2>/dev/null || true
      done
      wait 2>/dev/null
      FFMPEG_PIDS=()
      break
    fi
  done

  # Check if we crossed midnight — if so, stitch the completed day
  NEW_DATE=$(date +%Y-%m-%d)
  if [ "$NEW_DATE" != "$DATE" ]; then
    echo "[$(date)] Day rolled over. Stitching $DATE..."
    "$SCRIPT_DIR/daily-stitch.sh" "$DATE" >> "$LOG_DIR/${DATE}.log" 2>&1 || true
  fi

  # Brief pause before restarting (gives time for wake to fully settle)
  sleep 3
done
