//! The error codes the phone-side client reports. Names go to logs and numbers cross the JNI boundary, so both are fixed here and
//! pinned by `tests/params.rs`. A code carries no data: never an address, port, fingerprint or token.

use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorCode {
    /// The server's certificate is not the one `q.offer` pinned.
    FpMismatch = 1,
    /// The server answered the session token with `NO`.
    TokenRejected = 2,
    /// No connection, or no answer to the token, in time.
    Timeout = 3,
    /// An established connection was lost.
    LinkLost = 4,
    /// The peer broke the session protocol.
    Protocol = 5,
    /// Anything that is our own fault (runtime, panic).
    Internal = 6,
}

impl ErrorCode {
    pub fn as_i32(self) -> i32 {
        self as i32
    }

    pub fn from_i32(value: i32) -> Option<Self> {
        Some(match value {
            1 => Self::FpMismatch,
            2 => Self::TokenRejected,
            3 => Self::Timeout,
            4 => Self::LinkLost,
            5 => Self::Protocol,
            6 => Self::Internal,
            _ => return None,
        })
    }

    /// The name used in logs.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::FpMismatch => "FpMismatch",
            Self::TokenRejected => "TokenRejected",
            Self::Timeout => "Timeout",
            Self::LinkLost => "LinkLost",
            Self::Protocol => "Protocol",
            Self::Internal => "Internal",
        }
    }
}

impl fmt::Display for ErrorCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}
