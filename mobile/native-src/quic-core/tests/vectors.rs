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

// ---- the QUIC file stream (plan stage 2.2, Faz 2): the `file_stream` section --------------------------------------------------------------
// Swift (`QuicFileStreamTests`) and Kotlin (`QuicFileStreamVectorTest`) run the same cases, so every byte on a file stream is pinned three times.

mod file_stream {
    use super::*;
    use quic_core::file::{
        body_length, decode_header, encode_have, encode_header, encode_result, finish_verdict, message_length, parse_have, parse_result,
        FinalResult, HaveResult, Header, HeaderDecoder, HeaderInvalid, HeaderResult, Refusal, Verdict, WireError, FIRST_BYTE_TIMEOUT_MS,
        HEADER_MAX_BYTES, MIME_MAX_BYTES, NAME_MAX_BYTES, SIZE_MAX,
    };
    use serde_json::Value;

    fn doc() -> Value {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../protocol-vectors/quic-control.json");
        serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
    }

    fn cases(kind: &str) -> Vec<Value> {
        doc()["file_stream"]["cases"].as_array().expect("file_stream.cases").iter().filter(|c| c["kind"] == kind).cloned().collect()
    }

    fn name(c: &Value) -> String {
        c["name"].as_str().unwrap_or("?").to_string()
    }

    fn header(o: &Value) -> Header {
        Header {
            dir: o.get("dir").and_then(|v| v.as_str()).map(str::to_string),
            id: o["id"].as_str().unwrap().to_string(),
            mime: o["mime"].as_str().unwrap().to_string(),
            mtime: o["mtime"].as_u64().unwrap(),
            name: o["name"].as_str().unwrap().to_string(),
            size: o["size"].as_u64().unwrap(),
        }
    }

    fn expected_decode(e: &Value) -> HeaderResult {
        match e["result"].as_str().unwrap() {
            "header" => HeaderResult::Header(header(&e["header"]), e["consumed"].as_u64().unwrap() as usize),
            "needMore" => HeaderResult::NeedMore,
            _ => HeaderResult::Invalid(match e["code"].as_str().unwrap() {
                "bad-id" => HeaderInvalid::BadId,
                "not-file" => HeaderInvalid::NotFile,
                _ => HeaderInvalid::BadHeader,
            }),
        }
    }

    fn refusal(s: Option<&str>) -> Refusal {
        s.and_then(WireError::from_wire).map(Refusal::Known).unwrap_or(Refusal::Unknown)
    }

    #[test]
    fn the_vector_file_has_the_cases_this_suite_runs() {
        for kind in ["header_encode", "header_parse", "have_parse", "result_parse", "have_encode", "result_encode", "body_length", "finish_verdict"] {
            assert!(!cases(kind).is_empty(), "{kind}");
        }
        assert!(cases("header_parse").len() >= 60);
    }

    #[test]
    fn the_limits_are_one_number_on_every_side() {
        let v = doc()["constants"]["values"].clone();
        assert_eq!(v["file_header_max_bytes"].as_u64(), Some(HEADER_MAX_BYTES as u64));
        assert_eq!(v["file_name_max_bytes"].as_u64(), Some(NAME_MAX_BYTES as u64));
        assert_eq!(v["file_mime_max_bytes"].as_u64(), Some(MIME_MAX_BYTES as u64));
        assert_eq!(v["file_first_byte_timeout_ms"].as_u64(), Some(FIRST_BYTE_TIMEOUT_MS));
        assert_eq!(v["file_size_max"].as_u64(), Some(SIZE_MAX));
    }

    #[test]
    fn header_encode_vectors() {
        for c in cases("header_encode") {
            let h = header(&c["header"]);
            let want = hex(c["hex"].as_str().unwrap());
            assert_eq!(encode_header(&h), want, "{}", name(&c));
            assert_eq!(decode_header(&want), HeaderResult::Header(h, want.len()), "{} round trip", name(&c));
        }
    }

    #[test]
    fn header_parse_vectors() {
        for c in cases("header_parse") {
            assert_eq!(decode_header(&hex(c["hex"].as_str().unwrap())), expected_decode(&c["expect"]), "{}", name(&c));
        }
    }

    /// A stream delivers bytes in pieces: whatever the split, the answer must be the same, and an early answer must already be the final one.
    #[test]
    fn header_parse_gives_the_same_answer_wherever_the_bytes_are_split() {
        for c in cases("header_parse") {
            let all = hex(c["hex"].as_str().unwrap());
            let want = expected_decode(&c["expect"]);
            for cut in 0..=all.len() {
                let mut d = HeaderDecoder::new();
                let first = d.feed(&all[..cut]);
                if first != HeaderResult::NeedMore {
                    assert_eq!(first, want, "{} decided too early at {cut}", name(&c));
                }
                assert_eq!(d.feed(&all[cut..]), want, "{} split at {cut}", name(&c));
            }
            let mut d = HeaderDecoder::new();
            let mut last = HeaderResult::NeedMore;
            for b in &all {
                last = d.feed(&[*b]);
            }
            assert_eq!(last, want, "{} byte by byte", name(&c));
        }
    }

    #[test]
    fn have_parse_vectors() {
        for c in cases("have_parse") {
            let got = parse_have(&hex(c["hex"].as_str().unwrap()), c["size"].as_u64().unwrap());
            let e = &c["expect"];
            let want = match e["result"].as_str().unwrap() {
                "have" => HaveResult::Have(e["have"].as_u64().unwrap()),
                "err" => HaveResult::Refused(refusal(e["err"].as_str())),
                _ => HaveResult::Invalid,
            };
            assert_eq!(got, want, "{}", name(&c));
        }
    }

    #[test]
    fn result_parse_vectors() {
        for c in cases("result_parse") {
            let got = parse_result(&hex(c["hex"].as_str().unwrap()));
            let e = &c["expect"];
            let want = match e["result"].as_str().unwrap() {
                "ok" => FinalResult::Ok,
                "err" => FinalResult::Refused(refusal(e["err"].as_str())),
                _ => FinalResult::Invalid,
            };
            assert_eq!(got, want, "{}", name(&c));
        }
    }

    #[test]
    fn have_and_result_encode_vectors() {
        for c in cases("have_encode") {
            assert_eq!(encode_have(c["have"].as_u64().unwrap()), hex(c["hex"].as_str().unwrap()), "{}", name(&c));
        }
        for c in cases("result_encode") {
            let err = c.get("err").and_then(|e| e.as_str()).and_then(WireError::from_wire);
            assert_eq!(encode_result(c["ok"].as_bool().unwrap(), err), hex(c["hex"].as_str().unwrap()), "{}", name(&c));
        }
    }

    #[test]
    fn body_length_and_finish_verdict_vectors() {
        for c in cases("body_length") {
            let want = if c["expect"].is_null() { None } else { c["expect"].as_u64() };
            assert_eq!(body_length(c["size"].as_i64().unwrap(), c["have"].as_i64().unwrap()), want, "{}", name(&c));
        }
        for c in cases("finish_verdict") {
            let want = if c["expect"] == "ok" { Verdict::Ok } else { Verdict::SizeMismatch };
            assert_eq!(finish_verdict(c["expected"].as_i64().unwrap(), c["received"].as_i64().unwrap()), want, "{}", name(&c));
        }
    }

    #[test]
    fn a_message_is_two_length_bytes_plus_its_body() {
        assert_eq!(message_length(&[]), None);
        assert_eq!(message_length(&[0]), None);
        assert_eq!(message_length(&[0, 12]), Some(14));
        assert_eq!(message_length(&[0x10, 0x00, 1, 2, 3]), Some(4098));
    }
}
