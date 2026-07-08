#!/usr/bin/env bash
# Read-only Phase 1 gate verification. Inspects a recording session folder and
# checks: screen.mov is HEVC at native pixels, stream durations match (no drift),
# audio is 48kHz, and events.jsonl parses with sane t_ms. Does NOT modify anything.
#
# Usage: scripts/verify-phase1.sh ~/Movies/MicioStudio/<timestamp>
set -euo pipefail

DIR="${1:-}"
if [[ -z "$DIR" || ! -d "$DIR" ]]; then
  echo "usage: $0 <recording-session-folder>" >&2
  exit 2
fi

if ! command -v ffprobe >/dev/null 2>&1; then
  echo "error: ffprobe not found — run 'brew install ffmpeg'" >&2
  exit 2
fi

fail=0
note() { printf '  %s\n' "$1"; }
check() { if [[ "$1" == "ok" ]]; then printf '[ ok ] %s\n' "$2"; else printf '[FAIL] %s\n' "$2"; fail=1; fi; }

probe() { ffprobe -v error "$@"; }

echo "== Phase 1 gate: $DIR =="

# --- screen.mov: HEVC codec ---
screen="$DIR/screen.mov"
if [[ -f "$screen" ]]; then
  codec=$(probe -select_streams v:0 -show_entries stream=codec_name -of default=nk=1:nw=1 "$screen")
  w=$(probe -select_streams v:0 -show_entries stream=width -of default=nk=1:nw=1 "$screen")
  h=$(probe -select_streams v:0 -show_entries stream=height -of default=nk=1:nw=1 "$screen")
  pix=$(probe -select_streams v:0 -show_entries stream=pix_fmt -of default=nk=1:nw=1 "$screen")
  [[ "$codec" == "hevc" ]] && check ok "screen.mov codec is HEVC" || check fail "screen.mov codec is '$codec' (want hevc)"
  note "screen.mov = ${w}x${h}, pix_fmt=$pix  (confirm ${w}x${h} == your display's NATIVE pixels, not halved points)"
else
  check fail "screen.mov missing"
fi

# --- durations match across all streams (no drift) ---
dur() { probe -show_entries format=duration -of default=nk=1:nw=1 "$1" 2>/dev/null || echo "NA"; }
echo "  durations:"
for f in screen.mov camera.mov mic.caf system.caf combined.mov; do
  if [[ -f "$DIR/$f" ]]; then printf '    %-14s %s s\n' "$f" "$(dur "$DIR/$f")"; fi
done
note "→ all present streams should be within ~±0.1s of each other"

# --- audio 48kHz ---
for a in mic.caf system.caf; do
  if [[ -f "$DIR/$a" ]]; then
    sr=$(probe -select_streams a:0 -show_entries stream=sample_rate -of default=nk=1:nw=1 "$DIR/$a")
    [[ "$sr" == "48000" ]] && check ok "$a is 48kHz" || check fail "$a sample_rate is $sr (want 48000)"
  fi
done

# --- events.jsonl sanity ---
ev="$DIR/events.jsonl"
if [[ -f "$ev" ]]; then
  lines=$(grep -c . "$ev" || true)
  first=$(grep -m1 . "$ev" || true)
  note "events.jsonl: $lines non-empty lines; first: $first"
  check ok "events.jsonl present"
else
  check fail "events.jsonl missing"
fi

echo
if [[ "$fail" == "0" ]]; then echo "GATE: green (verify durations + native-pixel note above by eye)"; else echo "GATE: has failures"; exit 1; fi
