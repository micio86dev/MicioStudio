# MicioStudio — Spec & Claude Code Mega-Prompt

> **Working name:** `MicioStudio` (native macOS screen recorder for YouTube tutorials, MicioDev brand).
> Renamable in a single place: `PRODUCT_NAME` in `Config.swift` + bundle id.
>
> **Author:** Alessandro Micelli (MicioDev) — **Target dev machine:** Mac M1 8GB.
> **Methodology:** SDD + TDD, Git Flow, Conventional Commits, AGENTS.md-driven.

---

## 0. Goal in one sentence

A **native, ultra-light** macOS app that records screen + webcam + audio at **native Retina resolution**, applies a **customizable layered template** (floating screen with shadow/rounded corners, webcam overlay, images/logo, blurred backdrop), adds **cinematic auto-zoom on clicks**, and exports to **high-quality configurable HEVC** — with no external editor like Filmora.

Non-goals for v1: auto captions, 9:16 vertical format, iPhone device frame, simultaneous multi-monitor. (All addable later thanks to the layered architecture.)

---

## 1. Architectural decisions (fixed — not renegotiable in v1)

| Area | Choice | Why |
|---|---|---|
| UI | **SwiftUI** (+ AppKit where needed) | Native, light, Metal preview via `NSViewRepresentable` + `CAMetalLayer`. |
| Core logic | **Rust**, linked via **UniFFI** | Auto-zoom engine + template model + persistence: pure, testable, **portable** to Windows/Linux as-is. |
| Rust↔Swift binding | **UniFFI** (Mozilla) | Generates the Swift wrapper from the Rust core; no hand-written `objc2`/C ABI FFI. |
| Persistence | **SQLite** (via `rusqlite` in the Rust core) | Projects/recordings/renders library = relational. Templates stored as a JSON column (versionable/exportable). |
| Screen capture | **ScreenCaptureKit** | Zero-copy IOSurface → GPU, system audio included (macOS 13+). |
| Webcam capture | **AVFoundation** (`AVCaptureSession`) | IOSurface, same clock. |
| Click capture | **Global `CGEventTap`** (Accessibility permission) | Maximum precision required. |
| Compositing | **Core Image + Metal** | Ready GPU filters (blur/shadow/rounded), live preview on `CAMetalLayer`. |
| Encoding | **VideoToolbox** (HW HEVC) + `AVAssetWriter` | Maximum quality, hardware encoding on Apple Silicon. |
| Audio | `AVCaptureSession` + SCK, 48kHz, separate tracks | Mic + system separated, optional noise reduction. |

### 1.1 Core (Rust) ↔ native (Swift) boundary

```
┌─────────────────────────── SwiftUI app (macOS) ───────────────────────────┐
│  Views · Timeline · Template panel · Preview (CAMetalLayer)                │
│  Native backends:  ScreenCaptureKit · AVFoundation · CoreImage/Metal ·     │
│                    VideoToolbox · CGEventTap                               │
└───────────────────────────────┬───────────────────────────────────────────┘
                                 │ UniFFI (generated Swift bindings)
┌───────────────────────────────┴───────────────────────────────────────────┐
│                         core (Rust, PORTABLE)                              │
│  · zoom_engine   (click/cursor events → zoom keyframes, deterministic)     │
│  · template      (layer schema, serde, validation)                         │
│  · library       (SQLite via rusqlite: projects/recordings/renders)        │
│  · timeline      (orchestration, template→compositor command mapping)      │
└────────────────────────────────────────────────────────────────────────────┘
```

**Golden rule:** the Rust core touches **no system APIs**. Pure data only. When Windows/Linux comes, the core migrates intact; only the native backends + UI get rewritten (unavoidable work with any technology).

---

## 2. QUALITY requirements (the two critical points)

### 2.1 Video quality — sharpness lives in the pipeline, not the bitrate

**Non-negotiable rule: ALWAYS CAPTURE AT THE DISPLAY'S NATIVE PIXEL RESOLUTION (Retina 2×).**

- `SCStreamConfiguration.width/height` = display dimensions **in pixels** (not points).
- Pipeline order: **full-res source texture → zoom/pan transform → downscale to output → encode.** Never downscale *before* the zoom, or a 2× zoom magnifies pixels that don't exist and text goes soft.
- `SCStreamConfiguration.showsCursor = false` → we draw the cursor ourselves (styled, smoothed sprite).
- Color: preserve display gamma/color space; no destructive conversions.

### 2.2 Audio quality

- 48kHz, **separate** mic + system tracks (mix at export, not at capture).
- Configurable per-track gain; synced to the same clock as video.
- **Optional noise reduction** (on/off): system `AUVoiceProcessing` for v1. Honest: no software miracle on a poor mic — perceived quality depends mostly on mic and room.

### 2.3 Configurable export

- Codec: HEVC (default) | ProRes 422 (max-quality intermediate, for re-editing).
- Bitrate: default **16 Mbps** for code screencasts (range 12–20). ProRes = codec-managed.
- Output resolution: 1080p | 1440p | 4K (2160p). fps: 30 | 60.

> **M1 8GB note (dev):** develop and iterate at **1080/1440p**; keep 4K export tests as occasional runs, outside the dev loop. Core Image + AVFoundation stay lighter than a hand-rolled Metal compositor because they lean on optimized Apple pipelines.

---

## 3. Data model

### 3.1 SQLite (`library` schema)

```sql
CREATE TABLE templates (
  id          TEXT PRIMARY KEY,          -- uuid
  name        TEXT NOT NULL,
  definition  TEXT NOT NULL,             -- JSON (see 3.2)
  is_builtin  INTEGER NOT NULL DEFAULT 0,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);

CREATE TABLE projects (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  template_id   TEXT REFERENCES templates(id),
  zoom_config   TEXT NOT NULL,           -- JSON ZoomConfig
  export_config TEXT NOT NULL,           -- JSON ExportConfig
  audio_config  TEXT NOT NULL,           -- JSON AudioConfig
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL
);

CREATE TABLE recordings (
  id             TEXT PRIMARY KEY,
  project_id     TEXT REFERENCES projects(id) ON DELETE CASCADE,
  screen_path    TEXT NOT NULL,          -- HEVC full-res Retina
  camera_path    TEXT,                   -- HEVC webcam
  audio_mic_path TEXT,
  audio_sys_path TEXT,
  event_log_path TEXT NOT NULL,          -- clicks + sampled cursor (see 5.1)
  duration_ms    INTEGER NOT NULL,
  capture_w      INTEGER NOT NULL,       -- native pixels
  capture_h      INTEGER NOT NULL,
  created_at     INTEGER NOT NULL
);

CREATE TABLE render_jobs (
  id          TEXT PRIMARY KEY,
  project_id  TEXT REFERENCES projects(id) ON DELETE CASCADE,
  status      TEXT NOT NULL,             -- queued|running|done|error
  progress    REAL NOT NULL DEFAULT 0,   -- 0..1
  output_path TEXT,
  settings    TEXT NOT NULL,             -- JSON snapshot of export/zoom/template
  error       TEXT,
  created_at  INTEGER NOT NULL,
  finished_at INTEGER
);

CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
```

Rationale: template as a document (JSON, versionable/exportable `.json`), everything else relational and queryable. Persistence in the Rust core → portable.

### 3.2 Template JSON (visual schema — normalized geometry 0..1)

```json
{
  "version": 1,
  "canvas": { "width": 1920, "height": 1080 },
  "layers": [
    { "type": "background", "source": "screen", "blur": 55, "darken": 0.35 },
    { "type": "background", "source": "color", "color": "#0B0B0F" },
    { "type": "background", "source": "image", "path": "assets/bg.png", "fit": "cover" },

    { "type": "screen",
      "rect": { "x": 0.03, "y": 0.12, "w": 0.72, "h": 0.76 },
      "cornerRadius": 16,
      "shadow": { "radius": 40, "opacity": 0.45, "dy": 12 } },

    { "type": "camera",
      "rect": { "x": 0.77, "y": 0.62, "w": 0.20, "h": 0.26 },
      "cornerRadius": 20, "mirror": true,
      "shadow": { "radius": 30, "opacity": 0.5 } },

    { "type": "image",
      "path": "assets/miciodev-logo.png",
      "rect": { "x": 0.80, "y": 0.04, "w": 0.16, "h": 0.10 },
      "opacity": 0.9,
      "visible": { "start_ms": 0, "end_ms": null } }
  ]
}
```

**Invariants:** only one active `background` layer at a time (core-validated); style (`cornerRadius`/`shadow`/`opacity`) uniform across all types; optional `visible` (default always) enables intro/outro and timed logos. Adding a new type = one `case` in the compositor, zero refactor.

### 3.3 Config domain (Rust structs, serde → JSON)

```rust
pub struct ZoomConfig {
    pub enabled: bool,          // default true
    pub level: f32,             // 1.5..2.5, default 2.0
    pub ease_ms: u32,           // ease in/out, default 450
    pub curve: EaseCurve,       // EaseInOut (default) | EaseOut | Smooth
    pub hold_ms: u32,           // default 1800 (high: code needs to be read)
    pub debounce_ms: u32,       // < threshold = a single zoom, default 500
    pub max_zooms_per_10s: u8,  // anti-pinball, default 4
}

pub struct ExportConfig {
    pub codec: Codec,           // Hevc (default) | ProRes422
    pub bitrate_mbps: u16,      // default 16
    pub width: u32, pub height: u32, // default 1920x1080
    pub fps: u8,                // 30 | 60, default 30
}

pub struct AudioConfig {
    pub sample_rate: u32,       // 48000
    pub mic_gain_db: f32,       // default 0
    pub system_gain_db: f32,    // default -6
    pub noise_reduction: bool,  // default false
}
```

---

## 4. Auto-zoom engine (Rust core — where the feel is everything)

**Input:** `Vec<InputEvent { t_ms: u64, x: f32, y: f32, kind: Click|Move }>` (coordinates normalized 0..1 on the screen frame).
**Output:** `Vec<ZoomKeyframe { t_ms, center: (f32,f32), scale: f32, curve }>` that the compositor interpolates.

Algorithm (deterministic, 100% testable without the OS):
1. Filter `Click` events. Cluster clicks within `debounce_ms` and spatially close → a single event (center = mean).
2. For each cluster generate: **zoom-in** at `t_click − lead` (lead ~150ms), toward `center`, `scale = level`.
3. **Hold** for `hold_ms`. If another click arrives before the hold ends → the target moves *without* zooming out (continuous glide), avoiding the yo-yo.
4. No click within `hold_ms` → **zoom-out** to `scale = 1.0`.
5. Respect `max_zooms_per_10s`: if exceeded, drop the lowest-"importance" clusters (fewer clicks) in that window.
6. Clamp `center` so the zoomed rect never leaves the frame (no black bars).

**Mandatory tests (TDD):** single click → in/hold/out; double click <debounce → single zoom; burst → cap respected; edge clicks → no overflow; zoom-in interrupted by new click → glide without zoom-out. Snapshot the generated keyframes.

---

## 5. Capture & synchronization (the nastiest bug)

### 5.1 Recording (light, compositing deferred to the editor)

During recording, save:
- **screen.mov** — HEVC full-res Retina (HW encoding, nearly free).
- **camera.mov** — HEVC webcam.
- **mic.caf / system.caf** — separate 48kHz audio.
- **events.jsonl** — clicks (from `CGEventTap`) + cursor sampled at 60Hz, each with a timestamp.

### 5.2 Single clock (do this first, or zooms fire off-time)

- At record start, fix `t0` = host time (`CMClockGetHostTimeClock` / `mach_absolute_time`).
- `CMSampleBuffer` (SCK/AVFoundation) PTS is on the host-time clock → offset = `pts − t0`.
- `CGEvent` timestamps are in mach ticks → convert with `mach_timebase_info` and subtract `t0`.
- **All events in `events.jsonl` are offsets in ms from `t0`.** The Rust core works only on these offsets, clock-agnostic.

> ⚠️ Dedicated acceptance test in Phase 4: a real click at a known instant → keyframe within ±1 frame of the target.

---

## 6. PHASES (for debuggability — the scope is EVERYTHING, phases just isolate failures)

Each phase has a **verification gate**: you don't move to the next until the test is green.

### Phase 1 — Native-Retina capture + clean export *(no effects)*
- SCK captures screen at native pixels; AVCaptureSession webcam; mic+system audio.
- `AVAssetWriter` → one HEVC file that places raw screen and webcam side by side + mixed audio.
- **Gate:** record 10s, output is sharp at full resolution, audio in sync, no drift. `core` crate compiles and `cargo test` (empty ok) passes. UniFFI generates the bindings.

### Phase 2 — SQLite library + template schema + SwiftUI panel
- Core: `library` (rusqlite, migrations), `template` (serde + invariant validation from 3.2).
- UI: projects/recordings list; template editor (add/move/style layers, drag on the 0..1 canvas, import images into `assets/`); save template as a SQLite row + `.json` export.
- **Gate:** create a template from the panel, save it, reopen the app, it's still there; `.json` export/import roundtrip is identical. Rust tests on template validation + CRUD.

### Phase 3 — Core Image compositor from layers *(still no zoom)*
- Custom `AVVideoCompositing` (or `applyingCIFiltersWithHandler`) that reads the template from the core and composes bottom→top: background (blur+darken / color / image), floating screen (rounded + shadow), camera overlay, images.
- **Gate:** given screen.mov + camera.mov + a template, the export shows framed rectangles with shadow/rounded corners and a correct blurred backdrop. Changing the template changes the render. Static preview correct.

### Phase 4 — Auto-zoom engine (Rust) + live Metal preview
- Core `zoom_engine` (sec. 4) with its TDD suite.
- The compositor applies `ZoomKeyframe` as a transform on the **full-res screen texture before downscale** (sec. 2.1).
- Real-time preview on `CAMetalLayer` in SwiftUI (`NSViewRepresentable`).
- **Gate:** recording with real clicks → zooms on time (±1 frame), sharp (text readable at 2×), smooth curves, anti-pinball active. Dedicated sync test (sec. 5.2).

### Phase 5 — Advanced audio + configurable export + render queue
- Separate tracks, per-track gain, noise reduction on/off (`AUVoiceProcessing`).
- Full `ExportConfig` (codec/bitrate/resolution/fps); `render_jobs` with progress in the UI.
- **Gate:** HEVC 16Mbps 1080p and ProRes 1440p exports both valid; noise reduction audible on/off; real progress bar.

---

## 7. AGENTS.md (rules for Claude Code)

```markdown
# AGENTS.md — MicioStudio

## Stack (fixed)
- App: SwiftUI + AppKit (macOS 14+ target). Core: Rust (stable) via UniFFI.
- Persistence: SQLite (rusqlite) IN THE CORE. Template = JSON column.
- Capture: ScreenCaptureKit + AVFoundation + CGEventTap.
- Compositing: Core Image + Metal. Encoding: VideoToolbox via AVAssetWriter.

## Non-negotiable rules
- The `core` crate imports NO system APIs. Pure data + rusqlite only. It must
  compile on any OS. If a syscall is needed, it lives on the Swift side.
- Screen capture ALWAYS at native Retina pixel resolution. Downscale AFTER zoom.
- All event timestamps = offset in ms from t0 (host clock). See SPEC 5.2.
- Auto-zoom: logic only in the Rust core, covered by tests. No heuristics in Swift.

## Workflow
- SDD: implement against SPEC.md. TDD on the core (write the test first).
- Git Flow: branch per phase (`feat/phase-1-capture`, ...). Conventional Commits.
- Do not move to phase N+1 until phase N's GATE is green. Stop and report at the
  gate, do NOT proceed autonomously past the gate.
- Each phase ends with: green tests + a reproducible demo (command/steps) + commit.

## Definition of Done (per phase)
1. Code compiles (app + `cargo test`).
2. Phase gate verified with reproducible steps written in the PR.
3. No new warnings. UniFFI bindings regenerated if the core changed.
4. Conventional commit, one branch per phase.

## Repo layout
/core            # Rust crate (zoom_engine, template, library, timeline) + UniFFI udl
/app             # SwiftUI Xcode project
/app/Native      # backends: Capture/, Compositor/, Encoder/, Audio/, EventTap/
/templates       # builtin .json templates
/SPEC.md
/AGENTS.md
```

---

## 8. MEGA-PROMPT for Claude Code (copy-paste)

> Run it on the Mac in Claude Code Max, with `SPEC.md` and `AGENTS.md` in the root.

```
You are the implementer of MicioStudio. Read SPEC.md and AGENTS.md and treat them
as the source of truth. Build a native macOS app: a screen recorder for YouTube
tutorials with a layered template, effects (rounded corners, shadow, blurred
backdrop), auto-zoom on clicks, and configurable high-quality HEVC export.

CONSTRAINTS (from SPEC):
- SwiftUI + Rust core via UniFFI. SQLite (rusqlite) in the core. The core imports
  no system APIs: it must compile cross-OS (future Win/Linux portability).
- Screen capture at NATIVE Retina PIXEL resolution; downscale ONLY after zoom.
- Event timestamps = offset in ms from t0 (host clock), see SPEC 5.2.
- Auto-zoom: logic only in the Rust core, with tests (TDD). Configurable params
  (level, ease, curve, hold, debounce, max_zooms_per_10s).
- Quality: HW HEVC via VideoToolbox, configurable bitrate; 48kHz audio with
  separate mic+system tracks, optional noise reduction.

WAY OF WORKING:
- Proceed BY PHASES (SPEC sec. 6), one at a time. TDD on the core.
- At the end of EACH phase: verify the GATE with reproducible steps, commit
  (Conventional Commits, branch per phase), then STOP and show me how to verify.
  Do NOT proceed past the gate without my go-ahead.
- Git Flow, one branch per phase.

START WITH PHASE 1:
1. Scaffold: Rust workspace `/core` with UniFFI (minimal udl), SwiftUI Xcode
   project `/app` linking the core.
2. Implement ScreenCaptureKit capture (native pixels, showsCursor=false),
   AVCaptureSession webcam, mic+system audio, and an AVAssetWriter HEVC export
   that places raw screen+webcam side by side with mixed audio.
3. Fix t0 and the single clock NOW (SPEC 5.2), even though zoom lands in Phase 4:
   already write events.jsonl with ms offsets.
4. PHASE 1 GATE: record 10s, verify full-res sharpness, audio in sync, no drift;
   `cargo test` green; UniFFI generates the bindings. Show me the steps and stop.

Before writing code: list the files you'll create for Phase 1 and wait for my ok.
```

---

## 9. Suggested order of attack (for you, not the agent)

1. **First thing of all:** the single clock + `events.jsonl` (Phase 1) — it's the foundation of sync and the worst bug if deferred.
2. Then the **pure-Rust `zoom_engine`** you can write/test *in parallel* even without the rest: synthetic inputs → keyframes, all offline. It's the piece where starting early pays off most.
3. The **compositor** is the moat: spend the time on the *feel* (soft shadows, text hold time), not on the feature list.

If anything in the spec turns out different from what you had in mind (template format, config split, UniFFI vs hand-rolled C ABI), tell me and I'll adjust it before you launch the agent.