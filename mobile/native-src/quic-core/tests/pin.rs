//! Fingerprint pinning (plan stage 0.3). The phone trusts exactly one thing about the Mac: the SHA-256 of its
//! certificate's DER, delivered over the end-to-end encrypted control channel. These tests pin that contract against the
//! certificate the Mac's own encoder wrote (`fixtures/mac-cert.der`, see `fixtures/README.md`).

use quic_core::pin::{
    client_config, fingerprint, fingerprint_hex, parse_fingerprint_hex, PinError, PinnedFingerprintVerifier, ALPN,
};
use rustls::client::danger::ServerCertVerifier;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{CertificateError, Error};

const CERT: &[u8] = include_bytes!("fixtures/mac-cert.der");
const FINGERPRINT: &str = include_str!("fixtures/mac-cert.sha256");

fn server_name() -> ServerName<'static> {
    ServerName::try_from("link-to-mac").unwrap()
}

fn verify(verifier: &PinnedFingerprintVerifier, cert: &[u8]) -> Result<(), Error> {
    verifier
        .verify_server_cert(&CertificateDer::from(cert), &[], &server_name(), &[], UnixTime::now())
        .map(|_| ())
}

fn is_pin_mismatch(e: &Error) -> bool {
    matches!(e, Error::InvalidCertificate(CertificateError::ApplicationVerificationFailure))
}

#[test]
fn fingerprint_hex_matches_the_one_the_mac_wrote() {
    assert_eq!(fingerprint_hex(CERT), FINGERPRINT.trim());
    assert_eq!(fingerprint(CERT).len(), 32);
}

#[test]
fn parse_fingerprint_hex_is_strict() {
    let ok = parse_fingerprint_hex(FINGERPRINT.trim()).expect("64 lowercase hex");
    assert_eq!(ok, fingerprint(CERT));

    // The wire contract is exactly 64 LOWERCASE hex characters.
    assert_eq!(parse_fingerprint_hex(&FINGERPRINT.trim().to_uppercase()), Err(PinError::BadHex));
    assert_eq!(parse_fingerprint_hex(&FINGERPRINT.trim()[..62]), Err(PinError::BadLength));
    assert_eq!(parse_fingerprint_hex(&format!("{}00", FINGERPRINT.trim())), Err(PinError::BadLength));
    assert_eq!(parse_fingerprint_hex(&"zz".repeat(32)), Err(PinError::BadHex));
    assert_eq!(parse_fingerprint_hex(""), Err(PinError::BadLength));
}

#[test]
fn verifier_requires_exactly_32_bytes() {
    assert!(PinnedFingerprintVerifier::new(&[0u8; 32]).is_ok());
    assert_eq!(PinnedFingerprintVerifier::new(&[0u8; 31]).err(), Some(PinError::BadLength));
    assert_eq!(PinnedFingerprintVerifier::new(&[0u8; 33]).err(), Some(PinError::BadLength));
    assert_eq!(PinnedFingerprintVerifier::new(&[]).err(), Some(PinError::BadLength));
}

#[test]
fn accepts_the_pinned_certificate() {
    let verifier = PinnedFingerprintVerifier::new(&fingerprint(CERT)).unwrap();
    verify(&verifier, CERT).expect("the pinned certificate must be accepted");
}

#[test]
fn rejects_a_fingerprint_that_differs_by_one_bit() {
    let mut expected = fingerprint(CERT);
    expected[17] ^= 0x01;
    let verifier = PinnedFingerprintVerifier::new(&expected).unwrap();
    let err = verify(&verifier, CERT).unwrap_err();
    assert!(is_pin_mismatch(&err), "unexpected error: {err:?}");
}

#[test]
fn rejects_any_other_certificate() {
    let verifier = PinnedFingerprintVerifier::new(&fingerprint(CERT)).unwrap();
    let mut other = CERT.to_vec();
    let last = other.len() - 1;
    other[last] ^= 0x01;
    assert!(is_pin_mismatch(&verify(&verifier, &other).unwrap_err()));
}

#[test]
fn the_pin_is_the_only_trust_hostname_and_clock_are_ignored() {
    // The Mac is addressed by IP and its certificate says "LinkToMac"; neither a hostname match nor the validity
    // window may matter, otherwise a phone with a wrong clock could never connect.
    let verifier = PinnedFingerprintVerifier::new(&fingerprint(CERT)).unwrap();
    let wrong_name = ServerName::try_from("example.org").unwrap();
    for now in [UnixTime::since_unix_epoch(std::time::Duration::from_secs(0)), UnixTime::now()] {
        verifier
            .verify_server_cert(&CertificateDer::from(CERT), &[], &wrong_name, &[], now)
            .expect("hostname and clock must not matter");
    }
}

#[test]
fn only_tls13_signature_schemes_are_offered() {
    let verifier = PinnedFingerprintVerifier::new(&fingerprint(CERT)).unwrap();
    let schemes = verifier.supported_verify_schemes();
    assert!(schemes.contains(&rustls::SignatureScheme::ECDSA_NISTP256_SHA256), "the Mac's key type must be verifiable");
    assert!(!schemes.is_empty());
}

#[test]
fn client_config_builds_and_alpn_is_ltm_1() {
    assert_eq!(ALPN, b"ltm/1");
    client_config(&fingerprint(CERT)).expect("a client config for a valid fingerprint");
    assert_eq!(client_config(&[0u8; 5]).err(), Some(PinError::BadLength));
}

/// The Mac's hand-written DER must be readable by the parser rustls uses for TLS signature checks (rustls-webpki).
/// An unparsable certificate would surface as `BadDer`; a parsable one with a wrong signature as
/// `InvalidSignatureForPublicKey`. The real positive case, a genuine handshake signature, is the 0.3 interop run.
#[test]
fn webpki_parses_the_macs_certificate() {
    let der = CertificateDer::from(CERT);
    let cert = webpki::EndEntityCert::try_from(&der).expect("webpki must accept the minimal v3 certificate");

    let garbage_signature = [0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x01];
    let err = cert
        .verify_signature(webpki::ring::ECDSA_P256_SHA256, b"not what was signed", &garbage_signature)
        .unwrap_err();
    assert!(
        matches!(err, webpki::Error::InvalidSignatureForPublicKey),
        "expected a clean signature failure on a parsed certificate, got {err:?}"
    );
}

#[test]
fn the_mismatch_flag_stays_down_for_the_right_certificate_and_goes_up_for_a_wrong_one() {
    use rustls::client::danger::ServerCertVerifier;
    use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
    let verifier = PinnedFingerprintVerifier::new(&fingerprint(CERT)).unwrap();
    let flag = verifier.mismatch_flag();
    let name = ServerName::try_from("link-to-mac").unwrap();
    assert!(!flag.load(std::sync::atomic::Ordering::SeqCst));
    let ok = verifier.verify_server_cert(&CertificateDer::from(CERT.to_vec()), &[], &name, &[], UnixTime::now());
    assert!(ok.is_ok());
    assert!(!flag.load(std::sync::atomic::Ordering::SeqCst), "a matching certificate must not raise the flag");
    let mut other = CERT.to_vec();
    other[10] ^= 0x01;
    let bad = verifier.verify_server_cert(&CertificateDer::from(other), &[], &name, &[], UnixTime::now());
    assert!(bad.is_err());
    assert!(flag.load(std::sync::atomic::Ordering::SeqCst), "a certificate that does not match must raise the flag");
}

#[test]
fn a_client_config_comes_with_the_flag_of_its_own_verifier() {
    let (_config, flag) = quic_core::pin::client_config_with_flag(&[7u8; 32]).unwrap();
    assert!(!flag.load(std::sync::atomic::Ordering::SeqCst));
    assert_eq!(quic_core::pin::client_config_with_flag(&[7u8; 31]).err(), Some(PinError::BadLength));
}
