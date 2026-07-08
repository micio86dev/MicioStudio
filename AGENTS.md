# AGENTS.md — MicioStudio

## Stack (fixed)
- App: SwiftUI + AppKit (macOS 14+ target). Core: Rust (stable) via UniFFI.
- Persistence: SQLite (rusqlite) IN THE CORE. Template = JSON column. (Phase 2+)
- Capture: ScreenCaptureKit + AVFoundation + CGEventTap.
- Compositing: Core Image + Metal. Encoding: VideoToolbox via AVAssetWriter.

## Non-negotiable rules
- The `core` crate imports NO system APIs. Pure data + rusqlite only. It must
  compile on any OS. If a syscall is needed, it lives on the Swift side.
- Screen capture ALWAYS at native Retina pixel resolution. Downscale AFTER zoom.
- All event timestamps = offset in ms from t0 (host clock). See SPEC 5.2.
- Auto-zoom: logic only in the Rust core, covered by tests. No heuristics in Swift.

## UniFFI binding rule (project convention)
- Bindings use UniFFI proc-macro mode (no hand-written `.udl`). This satisfies the
  SPEC constraint "UniFFI, no hand-written C ABI" with the current supported path.
- The `uniffi-bindgen` binary is EMBEDDED in the crate (`src/bin/uniffi-bindgen.rs`)
  and invoked via `cargo run --bin uniffi-bindgen`. Never `cargo install` a floating
  bindgen — the embedded one is always version-locked to the `uniffi` dependency.
- Regenerate bindings with `scripts/build-core.sh` whenever the core changes.

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
/core            # Rust workspace (event_log now; zoom_engine, template, library, timeline later) + embedded bindgen
/app             # SwiftUI Xcode project (generated from project.yml via XcodeGen)
/app/Sources     # backends: App/, Capture/, Encoder/, Permissions/
/scripts         # build-core.sh (build + generate bindings), verify-phase1.sh
/templates       # builtin .json templates (Phase 2)
/SPEC.md
/AGENTS.md
