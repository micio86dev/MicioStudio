// Embedded UniFFI binding generator. Because it links the same `uniffi` crate
// version as the library, the generated bindings can never skew from the runtime.
// Invoked by scripts/build-core.sh: `cargo run --bin uniffi-bindgen -- generate ...`.
fn main() {
    uniffi::uniffi_bindgen_main()
}
