//! Certificate pinning for the phone's QUIC client.
//!
//! The Mac presents a self-signed certificate (written by hand on the Mac side). The phone does **not** validate it
//! against any CA, hostname or clock: it trusts exactly one fact, the SHA-256 of the certificate's DER, which reaches
//! the phone in `q.offer` over the already end-to-end encrypted control channel. So a connection is accepted only when
//! `SHA-256(end-entity DER) == pinned fingerprint`. The TLS handshake signature is still verified (with the key inside
//! that very certificate) so the peer must also hold the matching private key.
//!
//! Never logs or formats a fingerprint into an error: the error types carry no data.

use std::fmt;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use quinn::crypto::rustls::QuicClientConfig;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::{verify_tls12_signature, verify_tls13_signature, CryptoProvider, WebPkiSupportedAlgorithms};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{CertificateError, DigitallySignedStruct, Error, SignatureScheme};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

/// The ALPN protocol id of the Link To Mac data plane. Version changes bump the suffix.
pub const ALPN: &[u8] = b"ltm/1";

/// Length of a SHA-256 fingerprint in bytes.
pub const FINGERPRINT_LEN: usize = 32;

/// Name sent as SNI. Irrelevant for trust (the pin is the only check) but rustls needs a syntactically valid name.
pub const SERVER_NAME: &str = "link-to-mac";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PinError {
    /// A fingerprint must be exactly 32 bytes (64 hex characters).
    BadLength,
    /// A fingerprint on the wire is lowercase hex only.
    BadHex,
    /// The TLS or QUIC client configuration could not be built.
    Config,
}

impl fmt::Display for PinError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            PinError::BadLength => "fingerprint has the wrong length",
            PinError::BadHex => "fingerprint is not lowercase hex",
            PinError::Config => "could not build the TLS client configuration",
        })
    }
}

impl std::error::Error for PinError {}

/// SHA-256 of a certificate's DER encoding.
pub fn fingerprint(der: &[u8]) -> [u8; FINGERPRINT_LEN] {
    Sha256::digest(der).into()
}

/// The fingerprint as 64 lowercase hex characters (the wire form).
pub fn fingerprint_hex(der: &[u8]) -> String {
    fingerprint(der).iter().map(|b| format!("{b:02x}")).collect()
}

/// Parses the wire form: exactly 64 lowercase hex characters.
pub fn parse_fingerprint_hex(text: &str) -> Result<[u8; FINGERPRINT_LEN], PinError> {
    if text.len() != FINGERPRINT_LEN * 2 {
        return Err(PinError::BadLength);
    }
    let mut out = [0u8; FINGERPRINT_LEN];
    for (i, chunk) in text.as_bytes().chunks(2).enumerate() {
        let hi = nibble(chunk[0]).ok_or(PinError::BadHex)?;
        let lo = nibble(chunk[1]).ok_or(PinError::BadHex)?;
        out[i] = (hi << 4) | lo;
    }
    Ok(out)
}

fn nibble(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        _ => None, // uppercase is rejected on purpose: one canonical spelling
    }
}

/// Accepts a server certificate only if its SHA-256 equals the pinned fingerprint.
#[derive(Debug)]
pub struct PinnedFingerprintVerifier {
    expected: [u8; FINGERPRINT_LEN],
    algorithms: WebPkiSupportedAlgorithms,
    /// Raised the moment a certificate does not match the pin. A failed handshake alone can have many causes; this is how the
    /// client tells "wrong certificate" (`FpMismatch`) apart without parsing an error message.
    mismatch: Arc<AtomicBool>,
}

impl PinnedFingerprintVerifier {
    /// Uses the ring provider's signature algorithms.
    pub fn new(expected: &[u8]) -> Result<Self, PinError> {
        Self::with_provider(expected, &rustls::crypto::ring::default_provider())
    }

    pub fn with_provider(expected: &[u8], provider: &CryptoProvider) -> Result<Self, PinError> {
        let expected: [u8; FINGERPRINT_LEN] = expected.try_into().map_err(|_| PinError::BadLength)?;
        Ok(Self { expected, algorithms: provider.signature_verification_algorithms, mismatch: Arc::new(AtomicBool::new(false)) })
    }

    /// The flag that goes up when a presented certificate does not match (shared, so it outlives the verifier handed to rustls).
    pub fn mismatch_flag(&self) -> Arc<AtomicBool> {
        Arc::clone(&self.mismatch)
    }
}

impl ServerCertVerifier for PinnedFingerprintVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, Error> {
        // Constant-time: do not leak how many leading bytes of a guessed fingerprint were right.
        let actual = fingerprint(end_entity.as_ref());
        if bool::from(actual.ct_eq(&self.expected)) {
            Ok(ServerCertVerified::assertion())
        } else {
            self.mismatch.store(true, Ordering::SeqCst);
            Err(Error::InvalidCertificate(CertificateError::ApplicationVerificationFailure))
        }
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        verify_tls12_signature(message, cert, dss, &self.algorithms)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        verify_tls13_signature(message, cert, dss, &self.algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.algorithms.supported_schemes()
    }
}

/// A quinn client configuration that trusts only `expected` (a 32-byte SHA-256), speaks TLS 1.3 only and offers
/// ALPN [`ALPN`]. Transport: QUIC keep-alive every 5 s (the plan's per-session value) and a 30 s idle timeout.
pub fn client_config(expected: &[u8]) -> Result<quinn::ClientConfig, PinError> {
    client_config_with_flag(expected).map(|(config, _)| config)
}

/// Same, plus the verifier's mismatch flag (see [`PinnedFingerprintVerifier::mismatch_flag`]).
pub fn client_config_with_flag(expected: &[u8]) -> Result<(quinn::ClientConfig, Arc<AtomicBool>), PinError> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let pinned = PinnedFingerprintVerifier::with_provider(expected, &provider)?;
    let flag = pinned.mismatch_flag();
    let verifier = Arc::new(pinned);

    let mut tls = rustls::ClientConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])
        .map_err(|_| PinError::Config)?
        .dangerous()
        .with_custom_certificate_verifier(verifier)
        .with_no_client_auth();
    tls.alpn_protocols = vec![ALPN.to_vec()];

    let quic = QuicClientConfig::try_from(tls).map_err(|_| PinError::Config)?;
    let mut config = quinn::ClientConfig::new(Arc::new(quic));

    let mut transport = quinn::TransportConfig::default();
    transport.keep_alive_interval(Some(Duration::from_secs(5)));
    transport.max_idle_timeout(Some(Duration::from_secs(30).try_into().map_err(|_| PinError::Config)?));
    config.transport_config(Arc::new(transport));
    Ok((config, flag))
}
