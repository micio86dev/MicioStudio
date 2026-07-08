# MicioStudio — SPEC (source of truth)

> Native, ultra-light macOS screen recorder for YouTube tutorials (MicioDev brand).
> **Product name:** `MicioStudio` — renamable in one place: `PRODUCT_NAME` in `app/Config.swift` + bundle id.
> The full narrative mega-prompt lives at `docs/PROMPT.md`; this SPEC is the implementation contract.

## 0. Goal
A native app that records screen + webcam + audio at **native Retina resolution**, applies a
**customizable layered template** (floating screen with shadow/rounded corners, webcam overlay,
images/logo, blurred backdrop), adds **cinematic auto-zoom on clicks**, and exports to
**high-quality configurable HEVC** — no external editor.

Non-goals v1: auto captions, 9:16 vertical, iPhone device frame, simultaneous multi-monitor.

## 1. Architecture (fixed)
| Area | Choice |
|---|---|
| UI | SwiftUI (+ AppKit where needed); Metal preview via `NSViewRepresentable` + `CAMetalLayer` |
| Core logic | Rust, linked via UniFFI (portable, testable, no system APIs) |
| Rust↔Swift | UniFFI **proc-macro mode** (no hand-written `.udl`/C ABI) |
| Persistence | SQLite via `rusqlite` in the Rust core; template as JSON column |
| Screen capture | ScreenCaptureKit (zero-copy IOSurface, system audio, macOS 13+) |
| Webcam capture | AVFoundation (`AVCaptureSession`) |
| Click capture | Global `CGEventTap` (Accessibility permission) |
| Compositing | Core Image + Metal (live preview on `CAMetalLayer`) |
| Encoding | VideoToolbox HW HEVC + `AVAssetWriter` |
| Audio | `AVCaptureSession` + SCK, 48kHz, separate mic + system tracks |

**Golden rule:** the Rust core touches **no system APIs** — pure data only. Portable to Win/Linux;
only native backends + UI get rewritten.

## 2. Quality requirements
### 2.1 Video — sharpness lives in the pipeline, not the bitrate
- **ALWAYS capture at the display's native pixel resolution (Retina 2×).** `SCStreamConfiguration.width/height`
  = display dimensions in **pixels** (not points).
- Pipeline order: full-res source texture → zoom/pan transform → downscale to output → encode.
  Never downscale before zoom.
- `SCStreamConfiguration.showsCursor = false` → we draw the cursor ourselves later (styled sprite).
- Preserve display gamma/color space; no destructive conversions.

### 2.2 Audio
- 48kHz, **separate** mic + system tracks (mix at export, not at capture).
- Configurable per-track gain; synced to the same clock as video.
- Optional noise reduction (`AUVoiceProcessing`, Phase 5).

### 2.3 Export (Phase 5)
- Codec HEVC (default) | ProRes 422. Bitrate default 16 Mbps (12–20). Resolution 1080p|1440p|4K; fps 30|60.
- **M1 8GB dev note:** iterate at 1080/1440p; keep 4K tests occasional. Dev loop at 30fps.

## 3. Data model
### 3.1 SQLite `library` schema (Phase 2)
Tables: `templates`, `projects`, `recordings`, `render_jobs`, `app_settings`. See `docs/PROMPT.md §3.1`.
`recordings` stores per-stream paths (`screen_path`, `camera_path`, `audio_mic_path`, `audio_sys_path`,
`event_log_path`) + `capture_w`/`capture_h` in native pixels.

### 3.2 Template JSON (Phase 2) — normalized geometry 0..1
Layers: `background` (screen-blur/color/image), `screen` (rect+cornerRadius+shadow), `camera`, `image`.
Invariants: one active `background` at a time (core-validated); uniform style; optional `visible` window.
See `docs/PROMPT.md §3.2`.

### 3.3 Config domain (Rust structs, serde → JSON) — Phase 4/5
`ZoomConfig`, `ExportConfig`, `AudioConfig`. See `docs/PROMPT.md §3.3`.

## 4. Auto-zoom engine (Rust core, Phase 4)
Input `Vec<InputEvent{t_ms,x,y,kind}>` (coords normalized 0..1) → output `Vec<ZoomKeyframe>`.
Deterministic, 100% testable offline. Algorithm + mandatory TDD cases: `docs/PROMPT.md §4`.

## 5. Capture & synchronization
### 5.1 Recording (canonical model — light, compositing deferred to the editor)
During recording, save **separate** artifacts:
- `screen.mov` — HEVC full-res Retina (HW).
- `camera.mov` — HEVC webcam.
- `mic.caf` / `system.caf` — separate 48kHz audio.
- `events.jsonl` — clicks (from `CGEventTap`) + cursor sampled at 60Hz, each timestamped.

### 5.2 Single clock (do this FIRST)
- At record start, fix `t0` = host time (`CMClockGetHostTimeClock` / `mach_absolute_time`).
- `CMSampleBuffer` (SCK/AVFoundation) PTS is on the host-time clock → `offset = pts − t0`.
- `CGEvent` timestamps are in mach ticks → convert via `mach_timebase_info`, subtract `t0`.
- **All `events.jsonl` entries are offsets in ms from `t0`.** The Rust core works only on these offsets.
- Acceptance (Phase 4): a real click at a known instant → keyframe within ±1 frame.

## 6. Phases (each has a GATE; do not advance until green — stop and report)
- **Phase 1 — Native-Retina capture + clean export (no effects).** SCK screen at native pixels;
  AVCaptureSession webcam; mic+system audio; `AVAssetWriter` HEVC. Gate: record 10s → sharp full-res
  output, audio in sync, no drift; `core` compiles + `cargo test` passes; UniFFI generates bindings.
- **Phase 2 — SQLite library + template schema + SwiftUI panel.**
- **Phase 3 — Core Image compositor from layers (no zoom).**
- **Phase 4 — Auto-zoom engine (Rust) + live Metal preview.**
- **Phase 5 — Advanced audio + configurable export + render queue.**

Full gate details: `docs/PROMPT.md §6`.

## 7. Reconciliation note — separate streams vs. Phase 1 "side-by-side" (IMPORTANT)
`docs/PROMPT.md` contains an internal tension:
- **§5.1** says record **separate** streams; compositing is deferred to the editor (Phase 3).
- **§6 Phase 1 gate** says produce "one HEVC file that places raw screen and webcam side by side + mixed audio."

**Resolution (this SPEC):** the **separate streams of §5.1 are the canonical, durable artifacts** that the
rest of the app (Phase 3 compositor, Phase 4 zoom) depends on. The Phase 1 "side-by-side" file (`combined.mov`)
is a **derived, throwaway verification artifact** produced by post-processing the separate streams — it exists
only to make the gate visually verifiable and is not a product feature. Phase 1 therefore:
1. Records `screen.mov` / `camera.mov` / `mic.caf` / `system.caf` / `events.jsonl` (canonical, §5.1).
2. Post-processes them into `combined.mov` (two-up layout + mixed audio) for the gate demo, using
   `AVAssetReader` + `AVAssetWriter` (NOT `AVAssetExportSession`, which can silently transcode/downscale and
   would violate the sharpness gate). The gate tests the **capture** sharpness (`screen.mov` at native pixels),
   not the combined file's resolution.
