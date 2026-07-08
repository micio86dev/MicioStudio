# Session notes — overnight autonomous work

Branch: `feat/phase-2-library` (Phase 1 work is on `feat/phase-1-capture`, already committed).

## What I fixed / added this session

### Audio (your "rumore assurdo" — the real bug)
- Diagnosed it: the volume meter worked during capture (raw buffers were fine), but
  `mic.caf` was **broadband noise** (spectrogram confirmed). Root cause: the mic delivers
  32-bit float; the 16-bit writer wrote those bytes **without converting** → noise.
- **Fix:** `AVCaptureAudioDataOutput.audioSettings` now forces 16-bit mono 48kHz delivery,
  so the writer receives the exact format it writes (`app/Sources/Capture/AudioCapturer.swift`).
- ⚠️ **NEEDS YOUR TEST**: record ~8s speaking, then open `combined.mov`. If the mic is now
  clean, done. If the **system audio** (speakers) is also noisy, it needs the same treatment
  (SCK can't set the format, so its writer would need passthrough — a quick follow-up).

### In-app preview + progress (your requests)
- `combined.mov` is now built **inside the app** after Stop, with a **% progress bar**, and
  **auto-opens** when done (`CombinedExporter.swift`). It's 16:9 with the camera as a
  picture-in-picture, and the mic is denoised + loudness-normalized.

### App icon (your logo + red webcam badge)
- Done: `scripts/make-icon.swift` composited `~/Documents/logo_miciodev.jpg` + a red webcam
  badge (bottom-right) into `app/Assets.xcassets`. It's in the built bundle (`AppIcon.icns`).
- If you don't see it: macOS caches Dock icons — quit the app fully and relaunch the fresh
  build; it should show the neon-cat logo with the red camera badge.

### Also added earlier this session
- Monitor picker (you have 2 displays), microphone picker, live mic + system **level meters**,
  recording **timer**, stable self-signed code-signing (so TCC grants survive rebuilds —
  no more "grant every time"), and the single-clock capture alignment work.

## Phase 2 — STARTED (Rust core, fully tested)
The core (portable, no system APIs) now has, with **23 passing `cargo test`**:
- `template.rs` — the template document model + validation (SPEC §3.2): at most one
  background, normalized rects, positive canvas. FFI: `validateTemplateJson`,
  `normalizeTemplateJson`.
- `library.rs` — SQLite (rusqlite, bundled) with the full §3.1 schema + template CRUD
  (`Library.openInMemory/open`, `upsertTemplate`, `getTemplate`, `listTemplates`,
  `deleteTemplate`). Timestamps are caller-provided (deterministic).
- UniFFI bindings regenerated; the app compiles against them.

## What to test when you wake up
1. Relaunch the fresh build (no re-grant needed — stable signing).
2. Record ~8s **speaking** → watch the timer + meters → Stop → the progress bar builds
   `combined.mov` → it opens automatically. **Confirm the mic audio is clean.**
3. Confirm the app icon shows the logo + red webcam badge.
4. Optional gate check: `bash scripts/verify-phase1.sh "$(ls -1dt ~/Movies/MicioStudio/*/ | head -1)"`

## Open items / next
- **Verify the audio fix** (above) — the one thing I can't test without a mic.
- Mic still records ~2–3s longer than the video (trailing). The streams are aligned at the
  start (in sync during the video; the preview is trimmed with `-shortest`), so it's not a
  playback-sync problem, but the canonical `mic.caf` length differs. Diagnostic in each
  session's `sync-debug.txt`.
- **Phase 2 remaining:** SwiftUI panel (projects/recordings list + template editor) on top of
  the now-ready core; wire `Library` + template validation into the UI.
- **Phase 3:** Core Image compositor (the real 16:9 composite with rounded corners/shadow/
  blur + custom layout — this replaces the ffmpeg preview).
- **Phases 4–5:** auto-zoom engine (Rust) + Metal preview; advanced audio (proper
  AUVoiceProcessing noise reduction) + configurable export + render queue.
