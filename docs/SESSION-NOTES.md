# MicioStudio — build status & handoff

Branches: `feat/phase-1-capture` → `feat/phase-2-library` (current has everything).

## Built & how verified
- **Core (Rust, 31 `cargo test` green — fully verified):**
  - `event_log` (InputEvent/JSONL), `template` (model + validation, `deviceId` per layer),
    `library` (SQLite via rusqlite: template CRUD), `zoom` (Phase 4 auto-zoom engine).
- **Compositor (Phase 3) — renderer verified headlessly (rendered a real recording → correct
  composite: blurred bg, rounded+shadow floating screen, camera overlay):**
  - `TemplateRenderer` (Core Image), `CompositePreview` (editor live preview),
    `TemplateVideoExporter` (custom `AVVideoCompositing` → composed.mov). Metal-backed.
- **App UI (compiles clean; NOT runtime-verified by me — needs your testing):**
  - Main-window **studio layout**: large editable canvas — drag/resize elements, select one to
    change its source (webcam/screen/image) + style inline, during recording. No global Sources
    panel. Audio (mic + meters) stays global.
  - Template editor sheet: canvas (flicker-free, aspect-locked resize, ⌥=crop), inspector
    (per-layer source, color picker+alpha, cornerRadius/opacity/mirror), JSON export/import.
  - Capture: multi-camera (camera.mov, camera-1.mov… + sources.json), mic device picker, timer,
    mic-noise fix, stable code-signing (grants persist), app icon.
  - In-app export after Stop: real composite (composed.mov) if a template is active, else the
    ffmpeg side-by-side preview; progress bar + auto-open.

## ⚠️ NEEDS YOUR TESTING (built ahead of verification)
1. Relaunch the fresh build. If the Dock icon looks stale: `killall Dock`.
2. Pick a template → the big editable canvas appears. Drag/resize elements; select one → change
   its webcam/screen/image + style. Confirm it feels right.
3. Record ~10s with a template selected → confirm `composed.mov` is the real composite (this is
   the one thing I could NOT verify headlessly — AVAssetExportSession needs the app run loop).
4. Confirm mic audio is clean; confirm the editor "Preview" toggle renders.

## Remaining backlog (my recommended order; all requested)
1. **Scenes**: template contains N scenes (one background each, mandatory); switch via buttons +
   shortcuts with transitions (fade/slide/swipe). Big model change (Rust+Swift) — do the model in
   TDD first.
2. **Webcam virtual background**: blur (3 levels / none) + cover image (Vision person segmentation).
3. **Audio soundboard**: load/save music + SFX; playback controls (loop one/all, auto-next, stop
   at end); recorded into the export as its own track.
4. **Window + app-audio capture**: capture a specific Chrome/app window with its audio (SCK
   per-window + per-app audio).

Recommendation: TEST items 1–4 above before I build more on top — several earlier "non funziona"
reports were likely stale builds. Then I continue the backlog in the order above.
