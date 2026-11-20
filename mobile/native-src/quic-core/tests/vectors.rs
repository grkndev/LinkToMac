//! The shared QUIC control-plane vectors (`protocol-vectors/quic-control.json`, plan stage 1.5). Swift (`QuicControlVectorTests`) and Kotlin
//! (`QuicControlVectorTest`) run the whole file; the Rust core only owns one value of it, the TLS ALPN id. It must match the Mac's
//! listener and the phone's constants byte for byte, or no handshake ever completes (the failure is a TLS `no_application_protocol` alert,
//! far from where the typo is).

use quic_core::channel::{ChannelParse, QuicChannel};
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

fn hex(text: &str) -> Vec<u8> {
    (0..text.len() / 2).map(|i| u8::from_str_radix(&text[i * 2..i * 2 + 2], 16).unwrap()).collect()
}

fn channels() -> Vec<serde_json::Value> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../protocol-vectors/quic-control.json");
    let doc: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    doc["channels"]["cases"].as_array().expect("channels.cases").clone()
}

fn channel(name: &str) -> QuicChannel {
    match name {
        "file" => QuicChannel::File,
        "screen" => QuicChannel::Screen,
        "camera" => QuicChannel::Camera,
        other => panic!("unknown channel {other}"),
    }
}

#[test]
fn channel_header_vectors() {
    let cases: Vec<_> = channels().into_iter().filter(|c| c["kind"] == "header").collect();
    assert!(!cases.is_empty());
    for c in cases {
        let ch = channel(c["channel"].as_str().unwrap());
        assert_eq!(ch.header(), hex(c["hex"].as_str().unwrap()), "{}", c["name"]);
        assert_eq!(ch.is_bidirectional(), c["direction"] == "bidi", "{}", c["name"]);
    }
}

#[test]
fn channel_parse_vectors() {
    let cases: Vec<_> = channels().into_iter().filter(|c| c["kind"] == "parse").collect();
    assert!(!cases.is_empty());
    for c in cases {
        let expect = &c["expect"];
        let parsed = QuicChannel::parse(&hex(c["hex"].as_str().unwrap()));
        let want = match expect["result"].as_str().unwrap() {
            "channel" => ChannelParse::Known(channel(expect["channel"].as_str().unwrap()), expect["consumed"].as_u64().unwrap() as usize),
            "unknown" => ChannelParse::Unknown(expect["value"].as_u64().unwrap(), expect["consumed"].as_u64().unwrap() as usize),
            "needMoreBytes" => ChannelParse::NeedMoreBytes,
            other => panic!("unknown expected result {other}"),
        };
        assert_eq!(parsed, want, "{}", c["name"]);
    }
}
