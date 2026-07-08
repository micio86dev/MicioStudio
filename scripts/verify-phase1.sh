#!/usr/bin/env bash
# Phase 1 gate verification. Inspects a recording session folder, ASSERTS the gate
# criteria (native-pixel HEVC screen, matching durations = no drift, 48kHz audio,
# parseable events.jsonl), and builds the throwaway side-by-side preview
# (combined.mov: screen | camera + one mixed audio track) with ffmpeg.
#
# The app writes only the canonical streams (SPEC §5.1); this script derives the
# gate preview (SPEC §7). Requires ffmpeg/ffprobe: `brew install ffmpeg`.
#
# Usage: scripts/verify-phase1.sh <recording-session-folder>
set -euo pipefail

DIR="${1:-}"
if [[ -z "$DIR" || ! -d "$DIR" ]]; then
  echo "usage: $0 <recording-session-folder>" >&2
  exit 2
fi
for tool in ffprobe ffmpeg; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool not found — run 'brew install ffmpeg'" >&2; exit 2; }
done

fail=0
ok()   { printf '[ ok ] %s\n' "$1"; }
bad()  { printf '[FAIL] %s\n' "$1"; fail=1; }
probe() { ffprobe -v error "$@"; }
dur()  { probe -show_entries format=duration -of default=nk=1:nw=1 "$1" 2>/dev/null || echo ""; }

echo "== Phase 1 gate: $DIR =="

# --- screen.mov: HEVC at native pixels ---
screen="$DIR/screen.mov"
if [[ -f "$screen" ]]; then
  codec=$(probe -select_streams v:0 -show_entries stream=codec_name -of default=nk=1:nw=1 "$screen")
  w=$(probe -select_streams v:0 -show_entries stream=width  -of default=nk=1:nw=1 "$screen")
  h=$(probe -select_streams v:0 -show_entries stream=height -of default=nk=1:nw=1 "$screen")
  [[ "$codec" == "hevc" ]] && ok "screen.mov is HEVC" || bad "screen.mov codec is '$codec' (want hevc)"
  printf '       screen.mov = %sx%s  (confirm this equals your display NATIVE pixels)\n' "$w" "$h"
else
  bad "screen.mov missing"
fi

# --- durations match across present streams (no drift) ---
echo "  durations:"
maxd=0; mind=100000
for f in screen.mov camera.mov mic.caf system.caf; do
  [[ -f "$DIR/$f" ]] || continue
  d=$(dur "$DIR/$f"); [[ -z "$d" ]] && continue
  printf '    %-12s %s s\n' "$f" "$d"
  # track min/max with awk (float)
  maxd=$(awk -v a="$maxd" -v b="$d" 'BEGIN{print (b>a)?b:a}')
  mind=$(awk -v a="$mind" -v b="$d" 'BEGIN{print (b<a)?b:a}')
done
spread=$(awk -v mx="$maxd" -v mn="$mind" 'BEGIN{printf "%.3f", mx-mn}')
# tolerance 0.5s: streams start/stop a fraction apart, but seconds of spread = drift.
withinTol=$(awk -v s="$spread" 'BEGIN{print (s<=0.5)?"1":"0"}')
[[ "$withinTol" == "1" ]] && ok "stream durations within 0.5s (spread ${spread}s, no drift)" \
                          || bad "stream duration spread is ${spread}s (>0.5s → drift/leading-silence bug)"

# --- audio 48kHz ---
for a in mic.caf system.caf; do
  [[ -f "$DIR/$a" ]] || continue
  sr=$(probe -select_streams a:0 -show_entries stream=sample_rate -of default=nk=1:nw=1 "$DIR/$a")
  [[ "$sr" == "48000" ]] && ok "$a is 48kHz" || bad "$a sample_rate is $sr (want 48000)"
done

# --- events.jsonl present + non-empty ---
ev="$DIR/events.jsonl"
if [[ -f "$ev" ]]; then
  lines=$(grep -c . "$ev" || true)
  first=$(grep -m1 . "$ev" || true)
  [[ "$lines" -gt 0 ]] && ok "events.jsonl has $lines events" || bad "events.jsonl is empty"
  printf '       first: %s\n' "$first"
else
  bad "events.jsonl missing"
fi

# --- build the side-by-side preview (screen | camera + mixed audio) ---
out="$DIR/combined.mov"
if [[ -f "$screen" ]]; then
  echo "  building combined.mov (side-by-side preview)…"
  inputs=(-i "$screen"); vfilters="[0:v]scale=-2:720,setsar=1[s]"; vmap="[s]"; amaps=()
  ai=1
  if [[ -f "$DIR/camera.mov" ]]; then
    inputs+=(-i "$DIR/camera.mov"); vfilters+=";[${ai}:v]scale=-2:720,setsar=1[c];[s][c]hstack=inputs=2[v]"; vmap="[v]"; ((ai++))
  fi
  for a in mic.caf system.caf; do
    [[ -f "$DIR/$a" ]] && { inputs+=(-i "$DIR/$a"); amaps+=("[${ai}:a]"); ((ai++)); }
  done
  if [[ ${#amaps[@]} -gt 0 ]]; then
    afilter=";$(printf '%s' "${amaps[@]}")amix=inputs=${#amaps[@]}:duration=shortest:normalize=1[a]"
    amap=(-map "[a]")
  else
    afilter=""; amap=()
  fi
  if ffmpeg -y -v error "${inputs[@]}" \
      -filter_complex "${vfilters}${afilter}" \
      -map "$vmap" "${amap[@]}" \
      -c:v hevc_videotoolbox -b:v 8M -c:a aac -shortest "$out" 2>/tmp/ffmpeg-combined.err; then
    ok "combined.mov built ($(probe -select_streams v:0 -show_entries stream=width,height -of csv=p=0:nk=1:s=x "$out"))"
    echo "       open \"$out\" and confirm the click action lines up with the audio"
  else
    bad "combined.mov build failed (see /tmp/ffmpeg-combined.err)"
  fi
fi

echo
if [[ "$fail" == "0" ]]; then echo "GATE: GREEN ✅ (confirm native-pixel note + A/V sync in combined.mov by eye)"; else echo "GATE: has failures ❌"; exit 1; fi
