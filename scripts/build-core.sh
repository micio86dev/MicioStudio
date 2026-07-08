#!/usr/bin/env bash
# Build the Rust core static lib and (re)generate the Swift UniFFI bindings.
# Runs standalone AND as an Xcode pre-build phase. Library mode reads metadata
# from the built .dylib; the app links the .a. The bindgen is embedded in the
# crate, so it can never skew from the uniffi runtime version.
set -euo pipefail

# Resolve the repo root. Under Xcode the script is inlined, so BASH_SOURCE points
# into DerivedData — use $SRCROOT (the app/ dir) instead. Standalone runs use the
# script's own location.
if [[ -n "${SRCROOT:-}" ]]; then
  ROOT="$(cd "$SRCROOT/.." && pwd)"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
CORE_MANIFEST="$ROOT/core/Cargo.toml"
OUT_DIR="$ROOT/app/Generated"

# Ensure a real cargo is on PATH even when invoked from Xcode's minimal env.
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

echo "==> Building micio_core (release)"
cargo build --release --manifest-path "$CORE_MANIFEST"

DYLIB="$ROOT/core/target/release/libmicio_core.dylib"
if [[ ! -f "$DYLIB" ]]; then
  echo "error: expected $DYLIB (crate must build a cdylib)" >&2
  exit 1
fi

echo "==> Generating Swift bindings via embedded uniffi-bindgen"
mkdir -p "$OUT_DIR"
# Run from the workspace dir: uniffi's library mode shells out to `cargo metadata`,
# which resolves the manifest from the CURRENT directory (not --manifest-path).
( cd "$ROOT/core" && cargo run --release --bin uniffi-bindgen -- \
    generate --library "$DYLIB" \
    --language swift \
    --out-dir "$OUT_DIR" )

echo "==> Generated in app/Generated:"
/bin/ls -1 "$OUT_DIR"
