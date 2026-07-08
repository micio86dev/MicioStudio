# MicioStudio — build status & handoff

Branch: `feat/phase-2-library` (all work here). **No git remote configured → I could not
`git push`. Add a remote (`git remote add origin <url>` then `git push -u origin`) to push.**

## Verified automatically
- **Rust core: 34 `cargo test` green** — event log, template model (+scenes, migration),
  SQLite library, auto-zoom engine. 0 warnings.
- **Compositor renderer: validated headlessly** — rendered real + placeholder frames;
  per-scene render + fade/swipe transition blends produce correct composites.
- **App: builds clean (Debug + Release), 0 warnings.**

## Features built (need your runtime testing)
1. **Studio main window** — large editable preview; drag/resize elements; select one to
   change its source (webcam/screen/image) inline, during recording. No global Sources panel.
2. **Scenes** — a template holds N scenes (SceneBar: select/add/rename/delete). Switch live
   via chips or **number keys 1–9**; switches are recorded and re-applied in the export with
   a **transition** (cut / fade / slide / swipe — picker next to the SceneBar). One mandatory
   background per scene.
3. **Webcam virtual background** — per camera layer: blur (light/medium/strong) or a cover
   image, via Vision person segmentation (Inspector → Background).
4. **Soundboard** — background music + one-shot SFX; import/persist in App Support/MicioStudio/
   Audio; transport + loop modes (stop-at-end / repeat-one / repeat-all / auto-next) + effects
   grid. Plays through system output → captured into the recording automatically.
5. **Window capture** — Capture picker: full display or a single app window (Chrome etc.);
   the window's audio is captured via the system-audio track.
6. Editor polish: flicker-free drag, aspect-locked resize (⌥ = crop), color picker + alpha.
7. **Real composite export** (`composed.mov`) via AVVideoCompositing when a template is active.

## ⚠️ Could NOT verify (needs you at runtime — I can't drive the app or its webcam)
- `composed.mov` actual output (AVAssetExportSession hangs headless — works in-app).
- Virtual-background segmentation quality (needs a live webcam frame with a person).
- Soundboard playback + capture-into-recording; scene switching feel; window capture.

## How to test (tomorrow)
1. Install from the .dmg (drag to Applications). It's **self-signed** ("MicioDev Local
   Signing") → first launch: **right-click the app → Open** to bypass Gatekeeper. Grant
   Screen Recording + Accessibility, then relaunch.
2. Pick a template → editable canvas. Add scenes; switch with 1–9; pick a transition.
3. Add camera layers, set a virtual background; add music/SFX in the Soundboard.
4. Record ~20s (switch scenes, play a sound) → confirm `composed.mov` looks right.

## Remaining ideas (optional)
- Per-scene audio triggers; transition duration control; window audio true per-app isolation;
  export settings (codec/bitrate/fps) + render queue (SPEC Phase 5).
