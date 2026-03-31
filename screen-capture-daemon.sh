#!/bin/bash
# screen-capture-daemon.sh — Captures all connected screens at 2fps
# Re-enumerates screens on every restart, so it handles:
#   - Screen connect/disconnect
#   - Sleep/wake (ffmpeg dies on sleep, restarts on wake)
#   - Midnight rotation with daily stitching

PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# Prevent duplicate instances and clean up stale locks from crashed runs.
LOCKDIR="/tmp/screen-capture-daemon-$(id -u).lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  LOCK_PID="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    exit 0
  fi
  rm -rf "$LOCKDIR"
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    exit 0
  fi
fi
echo "$$" > "$LOCKDIR/pid"
trap 'rm -rf "$LOCKDIR"' EXIT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CAPTURE_DIR="$HOME/screen-recordings"
LOG_DIR="$CAPTURE_DIR/logs"
mkdir -p "$LOG_DIR"
LOGFILE="$LOG_DIR/daemon-stdout.log"
touch "$LOGFILE"
exec >>"$LOGFILE" 2>&1

FFMPEG_BIN="$(command -v ffmpeg || true)"
if [ -z "$FFMPEG_BIN" ]; then
  echo "[$(date)] ffmpeg not found in PATH=$PATH"
  exit 1
fi

CONFIG_FILE="$HOME/.config/screen-capture/config.env"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

PRIMARY_FPS="${PRIMARY_FPS:-2}"
SECONDARY_FPS="${SECONDARY_FPS:-1/3}"
OUTPUT_WIDTH="${OUTPUT_WIDTH:-1280}"
SEGMENT_SECONDS="${SEGMENT_SECONDS:-900}"

echo "[$(date)] Daemon starting (PID $$) with Primary FPS: $PRIMARY_FPS, Secondary FPS: $SECONDARY_FPS, Width: $OUTPUT_WIDTH, Segment Seconds: $SEGMENT_SECONDS"

# Clean up orphaned capture workers from previous crashed runs for this user.
pkill -U "$(id -u)" -f "$CAPTURE_DIR/.*/capture-screen.*\\.mp4" || true

FFMPEG_PIDS=()

fallback_capture_segment() {
  local duration="$1"
  local outfile="$2"
  local fps="$3"
  local tempdir
  local frame=1
  local interval
  local end_time
  local framefile
  local retries
  local capture_ok=0

  tempdir=$(mktemp -d /tmp/screen-capture-fallback.XXXXXX)
  interval=$(awk "BEGIN { printf \"%.3f\", 1 / $fps }")
  end_time=$(( $(date +%s) + duration ))

  echo "[$(date)] Fallback capture starting -> $(basename "$outfile") at ${fps}fps"

  while [ "$(date +%s)" -lt "$end_time" ]; do
    framefile="$tempdir/frame-$(printf '%06d' "$frame").png"
    retries=0
    while [ "$retries" -lt 5 ]; do
      if screencapture -x "$framefile" >/dev/null 2>&1; then
        capture_ok=1
        break
      fi
      retries=$(( retries + 1 ))
      sleep 1
    done

    if [ "$capture_ok" -eq 0 ]; then
      echo "[$(date)] Fallback screencapture failed repeatedly; aborting segment."
      rm -rf "$tempdir"
      return 1
    fi

    frame=$(( frame + 1 ))
    sleep "$interval"
  done

  "$FFMPEG_BIN" -nostdin -y \
    -framerate "$fps" \
    -pattern_type glob -i "$tempdir/frame-*.png" \
    -vf "scale=${OUTPUT_WIDTH}:-2" \
    -c:v libx264 -preset ultrafast \
    "$outfile" </dev/null >> "$LOG_DIR/${DATE}.log" 2>&1
  local status=$?
  rm -rf "$tempdir"
  return "$status"
}

can_screencapture() {
  local probe
  probe="/tmp/screen-capture-probe-$$.png"
  if screencapture -x "$probe" >/dev/null 2>&1; then
    rm -f "$probe"
    return 0
  fi
  rm -f "$probe"
  return 1
}

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
  ( "$FFMPEG_BIN" -nostdin -f avfoundation -list_devices true -i "" </dev/null 2>"$tmpfile" || true ) &
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
    IFS=: read -r COUNTER_DATE COUNTER_VAL < "$COUNTER_FILE" || true
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

  # Rotate in shorter chunks for reliability and easier recovery.
  NOW=$(date +%s)
  MIDNIGHT=$(date -j -f "%Y-%m-%d %H:%M:%S" "$(date -v+1d +%Y-%m-%d) 00:00:00" +%s 2>/dev/null || date -d "tomorrow 00:00" +%s)
  SECONDS_TO_MIDNIGHT=$(( MIDNIGHT - NOW ))
  SEGMENT_DURATION="$SECONDS_TO_MIDNIGHT"
  if [ "$SEGMENT_SECONDS" -gt 0 ] && [ "$SECONDS_TO_MIDNIGHT" -gt "$SEGMENT_SECONDS" ]; then
    SEGMENT_DURATION="$SEGMENT_SECONDS"
  fi

  # Discover available screens
  SCREENS=$(detect_screens)
  if [ -z "$SCREENS" ]; then
    if can_screencapture; then
      SCREEN_COUNT=1
      echo "[$(date)] No AVFoundation screens detected. Falling back to screencapture mode."
      OUTFILE="$OUTPUT_DIR/capture-screen1-${TIMESTAMP}-seg${SEGMENT_COUNTER}.mp4"
      CHUNK_DURATION="$SEGMENT_DURATION"
      if fallback_capture_segment "$CHUNK_DURATION" "$OUTFILE" "$PRIMARY_FPS"; then
        sleep 1
        continue
      fi
      echo "[$(date)] Fallback capture failed. Retrying in 10s..."
    else
      echo "[$(date)] No screens detected. Retrying in 10s..."
    fi
    sleep 10
    continue
  fi

  SCREEN_COUNT=$(echo "$SCREENS" | wc -l | tr -d ' ')
  echo "[$(date)] Detected $SCREEN_COUNT screen(s): $(echo $SCREENS | tr '\n' ' ')"

  # Launch one ffmpeg per screen.
  FFMPEG_PIDS=()
  for DEVICE in $SCREENS; do
    SCREEN_LABEL="screen${DEVICE}"
    # Include segment counter to avoid overwriting if screen reconnects same day
    OUTFILE="$OUTPUT_DIR/capture-${SCREEN_LABEL}-${TIMESTAMP}-seg${SEGMENT_COUNTER}.mp4"
    echo "[$(date)] Starting capture: $SCREEN_LABEL -> $(basename "$OUTFILE")"

    # Determine framerate configured via variables.
    if [ "$DEVICE" = "1" ]; then
      FRAMERATE=$PRIMARY_FPS
      FPS_FILTER="fps=$PRIMARY_FPS"
    else
      FRAMERATE=$SECONDARY_FPS
      FPS_FILTER="fps=$SECONDARY_FPS"
    fi

    # Note: If screen is off/locked, avfoundation will capture black frames.
    # This is expected behavior. The capture will continue when display wakes.
    "$FFMPEG_BIN" -nostdin -f avfoundation -pixel_format uyvy422 -framerate "$FRAMERATE" -capture_cursor 1 -i "${DEVICE}:none" \
      -t "$SEGMENT_DURATION" \
      -vf "${FPS_FILTER},scale=${OUTPUT_WIDTH}:-2" \
      -c:v libx264 -preset ultrafast \
      -y "$OUTFILE" \
      </dev/null >> "$LOG_DIR/${DATE}.log" 2>&1 &
    FFMPEG_PIDS+=($!)
  done

  # Wait for any capture worker to exit, then restart the loop and re-enumerate.
  while true; do
    CAPTURE_EXITED=0
    for i in "${!FFMPEG_PIDS[@]}"; do
      pid="${FFMPEG_PIDS[$i]}"
      if ! kill -0 "$pid" 2>/dev/null; then
        CAPTURE_EXITED=1
        echo "[$(date)] ffmpeg (PID $pid) exited. Restarting capture loop..."
        break
      fi
    done

    if [ "$CAPTURE_EXITED" -eq 1 ]; then
      for p in "${FFMPEG_PIDS[@]}"; do
        kill "$p" 2>/dev/null || true
      done
      sleep 1
      for p in "${FFMPEG_PIDS[@]}"; do
        kill -9 "$p" 2>/dev/null || true
      done
      wait 2>/dev/null
      FFMPEG_PIDS=()
      break
    fi

    sleep 2
  done

  # Check if we crossed midnight — if so, stitch the completed day
  NEW_DATE=$(date +%Y-%m-%d)
  if [ "$NEW_DATE" != "$DATE" ]; then
    echo "[$(date)] Day rolled over. Stitching $DATE..."
    "$SCRIPT_DIR/daily-stitch.sh" "$DATE" >> "$LOG_DIR/${DATE}.log" 2>&1 || true
  fi

  # Brief pause before restarting.
  sleep 1
done
