//! Connection parameters and error codes (stage 1.7): what the Kotlin side hands over, validated before anything touches the network.

use quic_core::error::ErrorCode;
use quic_core::params::{decode_token, encode_token, ConnectParams, ParamError};

const TOK: &str = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
const FP: &str = "abababababababababababababababababababababababababababababababab";

#[test]
fn the_token_decodes_like_the_mac_encodes_it() {
    let expected: Vec<u8> = (0..32).collect();
    assert_eq!(decode_token(TOK).unwrap().to_vec(), expected);
    assert_eq!(decode_token("-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_s").unwrap().to_vec(), vec![0xFB; 32]);
}

#[test]
fn encoding_and_decoding_are_inverse() {
    for seed in 0u8..=255 {
        let bytes: [u8; 32] = std::array::from_fn(|i| seed.wrapping_mul(7).wrapping_add((i as u8).wrapping_mul(13)));
        assert_eq!(decode_token(&encode_token(&bytes)).unwrap(), bytes);
        assert_eq!(encode_token(&bytes).len(), 43);
    }
}

#[test]
fn a_token_that_is_not_canonical_or_not_the_right_size_is_refused() {
    assert_eq!(decode_token(""), Err(ParamError::Token));
    assert_eq!(decode_token("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh"), Err(ParamError::Token)); // 42 characters
    assert_eq!(decode_token(&format!("{TOK}A")), Err(ParamError::Token)); // 44
    assert_eq!(decode_token("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh9"), Err(ParamError::Token)); // trailing bits set
    assert_eq!(decode_token("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh+"), Err(ParamError::Token)); // standard base64, not url-safe
    assert_eq!(decode_token("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh="), Err(ParamError::Token)); // padding
}

#[test]
fn good_parameters_parse_for_both_address_families() {
    let v4 = ConnectParams::parse("192.168.1.10", 53125, FP, TOK).unwrap();
    assert_eq!(v4.addr.to_string(), "192.168.1.10:53125");
    assert_eq!(v4.fp, [0xab; 32]);
    assert_eq!(v4.tok.to_vec(), (0..32).collect::<Vec<u8>>());
    let v6 = ConnectParams::parse("::1", 1024, FP, TOK).unwrap();
    assert_eq!(v6.addr.port(), 1024);
    assert!(v6.addr.is_ipv6());
}

#[test]
fn a_host_must_be_an_ip_address_never_a_name() {
    // No DNS on the data plane: the address is the very one the LAN link talks to.
    for host in ["example.com", "localhost", "", "999.1.1.1", "192.168.8", "192.168.1.10:53125", " 192.168.1.10"] {
        assert_eq!(ConnectParams::parse(host, 53125, FP, TOK).err(), Some(ParamError::Host), "{host:?}");
    }
}

#[test]
fn the_port_is_a_real_port() {
    assert_eq!(ConnectParams::parse("10.0.0.1", 0, FP, TOK).err(), Some(ParamError::Port));
    assert!(ConnectParams::parse("10.0.0.1", 1, FP, TOK).is_ok());
    assert!(ConnectParams::parse("10.0.0.1", 65535, FP, TOK).is_ok());
}

#[test]
fn a_fingerprint_must_be_64_lower_case_hex_characters() {
    for fp in [&FP[..63], &format!("{FP}a"), &FP.to_uppercase(), "", &"g".repeat(64)] {
        assert_eq!(ConnectParams::parse("10.0.0.1", 53125, fp, TOK).err(), Some(ParamError::Fingerprint), "{fp:?}");
    }
}

#[test]
fn a_bad_token_is_refused_with_its_own_error() {
    assert_eq!(ConnectParams::parse("10.0.0.1", 53125, FP, "short").err(), Some(ParamError::Token));
}

#[test]
fn errors_name_the_kind_and_never_the_value() {
    for err in [ParamError::Host, ParamError::Port, ParamError::Fingerprint, ParamError::Token] {
        let text = err.to_string();
        assert!(!text.contains(FP) && !text.contains(TOK) && !text.contains("10.0.0.1"), "{text}");
    }
}

#[test]
fn error_codes_have_stable_names_and_numbers() {
    // These names go to logs and these numbers cross the JNI boundary: neither may drift.
    let table = [
        (ErrorCode::FpMismatch, 1, "FpMismatch"),
        (ErrorCode::TokenRejected, 2, "TokenRejected"),
        (ErrorCode::Timeout, 3, "Timeout"),
        (ErrorCode::LinkLost, 4, "LinkLost"),
        (ErrorCode::Protocol, 5, "Protocol"),
        (ErrorCode::Internal, 6, "Internal"),
    ];
    for (code, number, name) in table {
        assert_eq!(code.as_i32(), number);
        assert_eq!(code.as_str(), name);
        assert_eq!(ErrorCode::from_i32(number), Some(code));
    }
    assert_eq!(ErrorCode::from_i32(0), None);
    assert_eq!(ErrorCode::from_i32(7), None);
}
