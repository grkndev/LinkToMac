//! The shared QUIC control-plane vectors (`protocol-vectors/quic-control.json`, plan stage 1.5). Swift (`QuicControlVectorTests`) and Kotlin
//! (`QuicControlVectorTest`) run the whole file; the Rust core only owns one value of it, the TLS ALPN id. It must match the Mac's
//! listener and the phone's constants byte for byte, or no handshake ever completes (the failure is a TLS `no_application_protocol` alert,
//! far from where the typo is).

use quic_core::pin::ALPN;
use std::path::PathBuf;

fn constants() -> serde_json::Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../protocol-vectors/quic-control.json");
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));
    let doc: serde_json::Value = serde_json::from_str(&text).expect("quic-control.json is valid JSON");
    doc["constants"]["values"].clone()
}

#[test]
fn alpn_matches_the_shared_vector_file() {
    let values = constants();
    let expected = values["alpn"].as_str().expect("constants.values.alpn is a string");
    assert_eq!(ALPN, expected.as_bytes(), "ALPN differs from protocol-vectors/quic-control.json");
}

#[test]
fn the_vector_file_still_carries_the_other_constants() {
    // The Rust core does not use these today, but a vector file that lost them would silently stop pinning the Swift/Kotlin side.
    let values = constants();
    assert_eq!(values["max_action_bytes"].as_i64(), Some(4096));
    assert_eq!(values["accept_timeout_ms"].as_i64(), Some(60_000));
}
