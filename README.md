# MicioStudio

Native, ultra-light macOS screen recorder for YouTube tutorials. SwiftUI app + a portable
Rust core linked via UniFFI. See `SPEC.md` for the contract and `AGENTS.md` for the rules.

**Status:** Phase 1 — native-Retina capture + clean HEVC export (no effects/zoom yet).

## One-time setup
```bash
# Build tooling
brew install xcodegen ffmpeg     # xcodegen: generates the .xcodeproj; ffmpeg: ffprobe for gate checks

# Rust: cargo 1.89+ (Homebrew or rustup both work — the bindgen is embedded, no version skew)
cargo --version
```
Requirements: macOS 14+ (developed on macOS 26 / Xcode 26 / Swift 6.3 / Apple Silicon).

## Repo layout
```
core/      Rust workspace — event_log (Phase 1); zoom_engine/template/library (later). No system APIs.
app/       SwiftUI macOS app (project.yml → XcodeGen). UniFFI bindings land in app/Generated/ (gitignored).
scripts/   build-core.sh (build core + generate bindings), verify-phase1.sh (gate checks)
templates/ builtin .json templates (Phase 2)
docs/      PROMPT.md (full mega-prompt / narrative spec)
```

## Build & test
```bash
# 1. Rust core: run the TDD suite
cargo test --manifest-path core/Cargo.toml

# 2. Build the Rust static lib + generate the Swift UniFFI bindings into app/Generated/
bash scripts/build-core.sh

# 3. Generate the Xcode project and build the app
cd app && xcodegen generate
xcodebuild -project MicioStudio.xcodeproj -scheme MicioStudio -configuration Debug build
```
Note: Xcode also runs `scripts/build-core.sh` as a pre-build phase, so the bindings stay current on every
build. `ENABLE_USER_SCRIPT_SANDBOXING` is off so that script can read `core/target` and write `app/Generated`.

## Phase 1 gate (manual)
1. Launch the app. Grant **Camera** and **Microphone** when prompted.
2. Grant **Screen Recording** and **Accessibility** in System Settings ▸ Privacy & Security, then **relaunch**
   (these grants do not apply to an already-running process).
3. Click **Record**, click around the screen for ~10s, click **Stop**.
4. The app writes the canonical separate streams to `~/Movies/MicioStudio/<timestamp>/`:
   `screen.mov`, `camera.mov`, `mic.caf`, `system.caf`, `events.jsonl` (SPEC §5.1). It does NOT write a
   combined file — that throwaway preview is derived by the verify script below.
5. Verify (auto-selects the latest session; also builds the side-by-side `combined.mov` preview with ffmpeg):
   ```bash
   bash scripts/verify-phase1.sh "$(ls -1dt ~/Movies/MicioStudio/*/ | head -1)"
   ```
   Green when: `screen.mov` is HEVC at native display pixels, stream durations agree within 0.5s (no drift),
   audio is 48kHz, `events.jsonl` is non-empty, and — by eye in the generated `combined.mov` — the click
   action lines up with the audio.

## Conventions
- **TDD** on the Rust core (test first). **Git Flow** (branch per phase, e.g. `feat/phase-1-capture`).
  **Conventional Commits.** Do not advance past a phase gate without review.
