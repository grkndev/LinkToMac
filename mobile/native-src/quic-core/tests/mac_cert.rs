//! Cross-language check of the Mac's QUIC server certificate (plan stage 0.2).
//!
//! `fixtures/mac-cert.der` was written by the Mac's hand-rolled DER encoder (`mac/Sources/LinkToMac/Quic/`) from a
//! throwaway key, `fixtures/mac-cert.sha256` is the fingerprint the Mac computes with CryptoKit. The phone side
//! (quinn, stage 1.7) must be able to read what the Mac writes, and the two sides must compute the SAME fingerprint:
//! that value is the only thing the phone pins, so any disagreement would make every connection fail.
//! To regenerate the fixtures see `fixtures/README.md`.

use sha2::{Digest, Sha256};
use x509_parser::oid_registry::{OID_EC_P256, OID_KEY_TYPE_EC_PUBLIC_KEY, OID_SIG_ECDSA_WITH_SHA256};
use x509_parser::prelude::*;

const CERT: &[u8] = include_bytes!("fixtures/mac-cert.der");
const FINGERPRINT: &str = include_str!("fixtures/mac-cert.sha256");

fn parse() -> X509Certificate<'static> {
    let (rest, cert) = X509Certificate::from_der(CERT).expect("the Mac's certificate must parse");
    assert!(rest.is_empty(), "no trailing bytes after the certificate");
    cert
}

#[test]
fn is_a_v3_self_issued_certificate_named_linktomac() {
    let cert = parse();
    assert_eq!(cert.version(), X509Version::V3);
    let cn = cert.subject().iter_common_name().next().expect("subject has a CN");
    assert_eq!(cn.as_str().unwrap(), "LinkToMac");
    // Self-issued: issuer and subject are the very same Name.
    assert_eq!(cert.issuer().as_raw(), cert.subject().as_raw());
}

#[test]
fn carries_a_p256_public_key() {
    let cert = parse();
    let spki = cert.public_key();
    assert_eq!(spki.algorithm.algorithm, OID_KEY_TYPE_EC_PUBLIC_KEY);
    let curve = spki
        .algorithm
        .parameters
        .as_ref()
        .and_then(|p| p.as_oid().ok())
        .expect("named curve parameter");
    assert_eq!(curve, OID_EC_P256);
    // Uncompressed point: 04 || X(32) || Y(32).
    let point = spki.subject_public_key.data.as_ref();
    assert_eq!(point.len(), 65);
    assert_eq!(point[0], 0x04);
}

#[test]
fn is_signed_with_ecdsa_sha256_and_the_signature_verifies() {
    let cert = parse();
    assert_eq!(cert.signature_algorithm.algorithm, OID_SIG_ECDSA_WITH_SHA256);
    assert!(
        cert.signature_algorithm.parameters.is_none(),
        "RFC 5758: ecdsa-with-SHA256 parameters are absent, not NULL"
    );
    // Self-signed: verify against its own public key.
    cert.verify_signature(None).expect("the self-signature must verify");
}

#[test]
fn serial_is_sixteen_positive_bytes() {
    let cert = parse();
    let serial = cert.raw_serial();
    assert_eq!(serial.len(), 16, "no sign pad, no truncation");
    assert!(serial[0] >= 0x40 && serial[0] < 0x80, "first byte 0x40-0x7F: positive and non-zero");
}

#[test]
fn validity_is_ten_years_starting_a_day_ago() {
    let cert = parse();
    let validity = cert.validity();
    let span_days = (validity.not_after.timestamp() - validity.not_before.timestamp()) as f64 / 86_400.0;
    // now-1d .. now+10y: 10 calendar years (3652 or 3653 days) plus the one day of back-dating.
    assert!((3652.0..=3655.0).contains(&span_days), "unexpected validity span: {span_days} days");
}

#[test]
fn has_no_extensions() {
    assert!(parse().extensions().is_empty());
}

#[test]
fn sha2_fingerprint_equals_the_one_cryptokit_wrote() {
    let expected = FINGERPRINT.trim();
    assert_eq!(expected.len(), 64);
    assert!(expected.chars().all(|c| matches!(c, '0'..='9' | 'a'..='f')), "lowercase hex");
    let digest = Sha256::digest(CERT);
    let actual: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    assert_eq!(actual, expected, "Swift (CryptoKit) and Rust (sha2) must agree on the fingerprint");
}
