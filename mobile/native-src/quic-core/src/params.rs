//! What the Kotlin side hands over to connect, validated before anything touches the network. Errors name the kind of mistake and
//! never echo the value (an address, a fingerprint and a token ride in here).

use std::fmt;
use std::net::{IpAddr, SocketAddr};

use crate::pin::{parse_fingerprint_hex, FINGERPRINT_LEN};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParamError {
    Host,
    Port,
    Fingerprint,
    Token,
}

impl fmt::Display for ParamError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            ParamError::Host => "the host is not an IP address",
            ParamError::Port => "the port is not valid",
            ParamError::Fingerprint => "the fingerprint is not 64 lower-case hex characters",
            ParamError::Token => "the token is not 43 canonical base64url characters",
        })
    }
}

impl std::error::Error for ParamError {}

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// The session token as it travels in `q.offer`: unpadded base64url, 32 bytes = exactly 43 characters.
pub fn encode_token(bytes: &[u8; 32]) -> String {
    let mut out = String::with_capacity(43);
    let mut bits: u32 = 0;
    let mut have = 0;
    for &b in bytes {
        bits = (bits << 8) | u32::from(b);
        have += 8;
        while have >= 6 {
            have -= 6;
            out.push(ALPHABET[((bits >> have) & 0x3f) as usize] as char);
        }
        bits &= (1 << have) - 1;
    }
    if have > 0 {
        out.push(ALPHABET[((bits << (6 - have)) & 0x3f) as usize] as char);
    }
    out
}

/// Decodes the canonical form only (what the Mac's `QuicSession.encodeToken` writes and the phone's validation accepts).
pub fn decode_token(text: &str) -> Result<[u8; 32], ParamError> {
    if text.len() != 43 {
        return Err(ParamError::Token);
    }
    let mut bits: u32 = 0;
    let mut have = 0;
    let mut out = Vec::with_capacity(33);
    for c in text.bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'-' => 62,
            b'_' => 63,
            _ => return Err(ParamError::Token),
        };
        bits = (bits << 6) | u32::from(v);
        have += 6;
        if have >= 8 {
            have -= 8;
            out.push((bits >> have) as u8);
            bits &= (1 << have) - 1;
        }
    }
    if bits != 0 {
        return Err(ParamError::Token); // 43 characters carry 258 bits: the 2 spare ones must be zero
    }
    out.try_into().map_err(|_| ParamError::Token)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectParams {
    pub addr: SocketAddr,
    pub fp: [u8; FINGERPRINT_LEN],
    pub tok: [u8; 32],
}

impl ConnectParams {
    /// `host` must be an IP literal: the data plane talks to the very address the LAN link uses, never to a name.
    pub fn parse(host: &str, port: u16, fp_hex: &str, tok_b64: &str) -> Result<Self, ParamError> {
        let ip: IpAddr = host.parse().map_err(|_| ParamError::Host)?;
        if port == 0 {
            return Err(ParamError::Port);
        }
        let fp = parse_fingerprint_hex(fp_hex).map_err(|_| ParamError::Fingerprint)?;
        let tok = decode_token(tok_b64)?;
        Ok(Self { addr: SocketAddr::new(ip, port), fp, tok })
    }
}
