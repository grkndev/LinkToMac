//! The bytes of one QUIC file stream (stage 2.2 of `docs/plans/2026-11-14-quic-data-plane.md`, Faz 2): one bidirectional stream per file.
//!
//! ```text
//! sender   ->  0x01 (the file channel varint)  ‖  header message
//! receiver ->  {"have":N}  or  {"err":"…","ok":false}          (N = bytes it already holds, 0 <= N <= size)
//! sender   ->  exactly size - have raw bytes, then it closes its side
//! receiver ->  {"ok":true}  (only after the file is in its final place)  or  {"err":"…","ok":false}
//! ```
//!
//! Every message is `u16 BE length ‖ JSON`. This module is the codec and the rules; the Swift twin is `Quic/QuicFileStream.swift` and the Kotlin
//! one `quic/QuicFileStream.kt`, and all three run the `file_stream` section of `protocol-vectors/quic-control.json`. It never touches a file
//! name: the receivers sanitise name and directory themselves; this layer checks syntax and limits only.

use std::time::Duration;

use crate::channel::{ChannelParse, QuicChannel};
use serde_json::{Map, Value};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::time::timeout;

pub const HEADER_MAX_BYTES: usize = 4096;
pub const NAME_MAX_BYTES: usize = 200;
pub const MIME_MAX_BYTES: usize = 255;
/// How long a receiver waits for the first byte of a bidirectional stream before it ignores the stream (Network.framework's reserved,
/// byte-less server-initiated stream, see the plan's stage 2.2 item 7).
pub const FIRST_BYTE_TIMEOUT_MS: u64 = 2000;
/// 2^53 - 1: every JSON library reads it exactly.
pub const SIZE_MAX: u64 = 9_007_199_254_740_991;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Header {
    pub dir: Option<String>,
    pub id: String,
    pub mime: String,
    pub mtime: u64,
    pub name: String,
    pub size: u64,
}

/// The refusal codes on the wire.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WireError {
    Space,
    Busy,
    BadId,
    Write,
    TooMany,
    BadHeader,
    Size,
}

impl WireError {
    pub fn wire(self) -> &'static str {
        match self {
            Self::Space => "space",
            Self::Busy => "busy",
            Self::BadId => "bad-id",
            Self::Write => "write",
            Self::TooMany => "too-many",
            Self::BadHeader => "bad-header",
            Self::Size => "size",
        }
    }

    pub fn from_wire(s: &str) -> Option<Self> {
        [Self::Space, Self::Busy, Self::BadId, Self::Write, Self::TooMany, Self::BadHeader, Self::Size].into_iter().find(|e| e.wire() == s)
    }
}

/// A refusal the peer sent: a code we know, or one a newer peer invented (or none at all).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    Known(WireError),
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HeaderInvalid {
    /// The first varint names another channel: not ours, nothing is answered.
    NotFile,
    /// Anything wrong with the structure or the limits.
    BadHeader,
    /// The structure is fine but `id` is not 8 lower-case hex (checked last).
    BadId,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HeaderResult {
    NeedMore,
    /// The header, and how many bytes it used; later bytes belong to the body.
    Header(Header, usize),
    Invalid(HeaderInvalid),
}

/// Feeds the bytes the way a stream delivers them. The answer for the bytes so far; an `Invalid` is final, `NeedMore` is not.
#[derive(Debug, Default)]
pub struct HeaderDecoder {
    buffer: Vec<u8>,
}

impl HeaderDecoder {
    pub fn new() -> Self {
        Self::default()
    }

    /// Everything fed so far (the bytes after a decoded header belong to the file body).
    pub fn buffered(&self) -> &[u8] {
        &self.buffer
    }

    pub fn feed(&mut self, bytes: &[u8]) -> HeaderResult {
        self.buffer.extend_from_slice(bytes);
        decode_header(&self.buffer)
    }
}

// ---- header -----------------------------------------------------------------------------------------------------------------------------

/// What a sender writes first: the file channel varint and the header message (canonical JSON). The sender keeps the header within the limits.
pub fn encode_header(h: &Header) -> Vec<u8> {
    let mut json = String::from("{");
    if let Some(dir) = &h.dir {
        json.push_str("\"dir\":");
        json.push_str(&quoted(dir));
        json.push(',');
    }
    json.push_str(&format!(
        "\"id\":{},\"mime\":{},\"mtime\":{},\"name\":{},\"size\":{}}}",
        quoted(&h.id),
        quoted(&h.mime),
        h.mtime,
        quoted(&h.name),
        h.size
    ));
    let mut out = QuicChannel::File.header();
    out.extend(message(&json));
    out
}

/// The answer for ALL the bytes received so far.
pub fn decode_header(bytes: &[u8]) -> HeaderResult {
    let channel_length = match QuicChannel::parse(bytes) {
        ChannelParse::NeedMoreBytes => return HeaderResult::NeedMore,
        ChannelParse::Unknown(_, _) => return HeaderResult::Invalid(HeaderInvalid::NotFile),
        ChannelParse::Known(QuicChannel::File, consumed) => consumed,
        ChannelParse::Known(_, _) => return HeaderResult::Invalid(HeaderInvalid::NotFile),
    };
    if bytes.len() < channel_length + 2 {
        return HeaderResult::NeedMore;
    }
    let length = (usize::from(bytes[channel_length]) << 8) | usize::from(bytes[channel_length + 1]);
    if length == 0 || length > HEADER_MAX_BYTES {
        return HeaderResult::Invalid(HeaderInvalid::BadHeader); // known as soon as the two length bytes are
    }
    let end = channel_length + 2 + length;
    if bytes.len() < end {
        return HeaderResult::NeedMore;
    }
    let Some(header) = parse_header_body(&bytes[channel_length + 2..end]) else { return HeaderResult::Invalid(HeaderInvalid::BadHeader) };
    if !is_id(&header.id) {
        return HeaderResult::Invalid(HeaderInvalid::BadId);
    }
    HeaderResult::Header(header, end)
}

/// Structure and limits. The id's PATTERN is checked by the caller afterwards so that a structural fault wins over a bad id.
fn parse_header_body(body: &[u8]) -> Option<Header> {
    let o = json_object(body)?;
    let name = o.get("name")?.as_str()?;
    if !(1..=NAME_MAX_BYTES).contains(&name.len()) {
        return None;
    }
    let mime = o.get("mime")?.as_str()?;
    if !(1..=MIME_MAX_BYTES).contains(&mime.len()) {
        return None;
    }
    let size = integer(o.get("size"))?;
    let mtime = integer(o.get("mtime"))?;
    let id = o.get("id")?.as_str()?;
    let dir = match o.get("dir") {
        None => None,
        Some(v) => Some(v.as_str()?.to_string()),
    };
    Some(Header { dir, id: id.to_string(), mime: mime.to_string(), mtime, name: name.to_string(), size })
}

fn is_id(s: &str) -> bool {
    s.len() == 8 && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

// ---- answers ----------------------------------------------------------------------------------------------------------------------------

pub fn encode_have(have: u64) -> Vec<u8> {
    message(&format!("{{\"have\":{have}}}"))
}

/// `{"ok":true}`, or a refusal with its code (`{"err":"space","ok":false}`).
pub fn encode_result(ok: bool, err: Option<WireError>) -> Vec<u8> {
    match (ok, err) {
        (true, _) => message("{\"ok\":true}"),
        (false, Some(e)) => message(&format!("{{\"err\":\"{}\",\"ok\":false}}", e.wire())),
        (false, None) => message("{\"ok\":false}"),
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HaveResult {
    Have(u64),
    Refused(Refusal),
    Invalid,
}

/// The first answer, as ONE complete message; `size` is the file's size (a `have` beyond it is invalid).
pub fn parse_have(bytes: &[u8], size: u64) -> HaveResult {
    let Some(o) = message_body(bytes).and_then(json_object) else { return HaveResult::Invalid };
    if let Some(ok) = o.get("ok") {
        return match ok.as_bool() {
            Some(false) => HaveResult::Refused(refusal(o.get("err"))), // `ok:true` is not an answer to the header
            _ => HaveResult::Invalid,
        };
    }
    match integer(o.get("have")) {
        Some(have) if have <= size => HaveResult::Have(have),
        _ => HaveResult::Invalid,
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FinalResult {
    Ok,
    Refused(Refusal),
    Invalid,
}

/// The last answer, as ONE complete message.
pub fn parse_result(bytes: &[u8]) -> FinalResult {
    let Some(o) = message_body(bytes).and_then(json_object) else { return FinalResult::Invalid };
    match o.get("ok").and_then(Value::as_bool) {
        Some(true) => FinalResult::Ok,
        Some(false) => FinalResult::Refused(refusal(o.get("err"))),
        None => FinalResult::Invalid,
    }
}

// ---- the body ---------------------------------------------------------------------------------------------------------------------------

/// How many raw bytes follow the first answer, or `None` when `have` is outside `0..=size`.
pub fn body_length(size: i64, have: i64) -> Option<u64> {
    (size >= 0 && have >= 0 && have <= size).then(|| (size - have) as u64)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Ok,
    SizeMismatch,
}

/// The sender closed its side after `received` bytes while `expected` were due.
pub fn finish_verdict(expected: i64, received: i64) -> Verdict {
    if expected == received {
        Verdict::Ok
    } else {
        Verdict::SizeMismatch
    }
}

// ---- framing and JSON -------------------------------------------------------------------------------------------------------------------

/// How long the whole message is, once its two length bytes are known (`None` before that).
pub fn message_length(prefix: &[u8]) -> Option<usize> {
    (prefix.len() >= 2).then(|| 2 + ((usize::from(prefix[0]) << 8) | usize::from(prefix[1])))
}

fn message(json: &str) -> Vec<u8> {
    let body = json.as_bytes();
    let mut out = vec![(body.len() >> 8) as u8, (body.len() & 0xff) as u8];
    out.extend_from_slice(body);
    out
}

/// The JSON of ONE complete message (length prefix matching the bytes), or `None`.
fn message_body(bytes: &[u8]) -> Option<&[u8]> {
    let total = message_length(bytes)?;
    (total == bytes.len() && total > 2 && total - 2 <= HEADER_MAX_BYTES).then(|| &bytes[2..])
}

/// A JSON object and nothing after it (`serde_json` rejects trailing text).
fn json_object(body: &[u8]) -> Option<Map<String, Value>> {
    match serde_json::from_slice::<Value>(body).ok()? {
        Value::Object(map) => Some(map),
        _ => None,
    }
}

/// A JSON integer literal 0..=SIZE_MAX: not a boolean, not a float (`5.0` and `1e3` are floats), not a string, not beyond 64 bits.
fn integer(v: Option<&Value>) -> Option<u64> {
    v?.as_u64().filter(|n| *n <= SIZE_MAX)
}

fn refusal(v: Option<&Value>) -> Refusal {
    v.and_then(Value::as_str).and_then(WireError::from_wire).map(Refusal::Known).unwrap_or(Refusal::Unknown)
}

/// Canonical JSON string: `"` `\` and control characters escaped (`\b \f \n \r \t` short, the rest `\u00xx` lower case), everything else raw.
fn quoted(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

// ---- the drivers: one file over a bidirectional stream (generic over tokio's I/O traits, so quinn streams and in-memory pipes both work) -----

/// What an incoming bidirectional stream turned out to be, judged from its FIRST byte(s).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Incoming {
    /// A file stream; the bytes already read (the channel varint) are the seed for [`receive_file`].
    File(Vec<u8>),
    /// Another channel (the bytes already read).
    Other(Vec<u8>),
    /// No first byte within the time, or the stream ended without one: Network.framework's reserved, byte-less server-initiated stream (plan
    /// stage 2.2, item 7). It is ignored; real streams are served in parallel and never wait for it.
    Ignored,
}

/// Reads the channel varint of an incoming stream, waiting at most `first_byte_timeout` for each byte.
pub async fn classify_incoming<R: AsyncRead + Unpin>(recv: &mut R, first_byte_timeout: Duration) -> Incoming {
    let Ok(Ok(first)) = timeout(first_byte_timeout, recv.read_u8()).await else { return Incoming::Ignored };
    let mut prefix = vec![first];
    for _ in 0..(1usize << (first >> 6)) - 1 {
        let Ok(Ok(next)) = timeout(first_byte_timeout, recv.read_u8()).await else { return Incoming::Ignored };
        prefix.push(next);
    }
    match QuicChannel::parse(&prefix) {
        ChannelParse::Known(QuicChannel::File, _) => Incoming::File(prefix),
        _ => Incoming::Other(prefix),
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SendError {
    /// The receiver said no (or, at the end, that the file is not in place).
    Refused(Refusal),
    /// The peer's answer was not a valid message.
    Protocol,
    /// The source has fewer bytes than the header's `size` (the stream is closed so the receiver does not wait for the rest).
    SourceTooShort,
    Io(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Sent {
    /// How many bytes the receiver already held.
    pub have: u64,
    /// How many raw bytes crossed the stream (`size - have`).
    pub bytes_written: u64,
}

/// Sends one file: header, wait for `have`, skip what the receiver holds, write the rest, close the sending side, wait for the receipt.
/// `Ok` means the receiver said the file is in its final place; nothing earlier is a delivery.
pub async fn send_file<S, Rv, R>(send: &mut S, recv: &mut Rv, header: &Header, reader: &mut R) -> Result<Sent, SendError>
where
    S: AsyncWrite + Unpin,
    Rv: AsyncRead + Unpin,
    R: AsyncRead + Unpin,
{
    send.write_all(&encode_header(header)).await.map_err(io)?;
    send.flush().await.map_err(io)?;
    let have = match parse_have(&read_message(recv).await?, header.size) {
        HaveResult::Have(n) => n,
        HaveResult::Refused(r) => return Err(SendError::Refused(r)),
        HaveResult::Invalid => return Err(SendError::Protocol),
    };
    let skipped = tokio::io::copy(&mut (&mut *reader).take(have), &mut tokio::io::sink()).await.map_err(io)?;
    if skipped != have {
        return Err(SendError::SourceTooShort);
    }
    let body = header.size - have;
    let written = tokio::io::copy(&mut (&mut *reader).take(body), send).await.map_err(io)?;
    send.shutdown().await.map_err(io)?; // closes the sending side: the receiver sees the end of the body
    if written != body {
        return Err(SendError::SourceTooShort);
    }
    match parse_result(&read_message(recv).await?) {
        FinalResult::Ok => Ok(Sent { have, bytes_written: written }),
        FinalResult::Refused(r) => Err(SendError::Refused(r)),
        FinalResult::Invalid => Err(SendError::Protocol),
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReceiveError {
    /// The first varint was another channel: nothing was answered.
    NotFile,
    /// We refused (and told the sender): the header, the target, the size or the disk.
    Refused(WireError),
    Io(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Received {
    pub header: Header,
    /// How many bytes we already held (answered to the sender).
    pub have: u64,
    /// How many raw bytes crossed the stream.
    pub bytes_received: u64,
}

/// Receives one file whose channel varint [`classify_incoming`] already read (`seed`).
///
/// `accept` looks at the header and returns how many bytes we already hold and the writer for the rest, or the refusal to send; the writer
/// must already be positioned (appending after `have`). `finalize` runs when exactly `size - have` bytes arrived and the sender closed its
/// side: it puts the file in its final place, and only when it returns `Ok` is `{"ok":true}` sent. A stream that ends short or carries more is
/// refused with `size`, a writer that fails with `write`. After a refusal the caller should also stop reading the stream.
pub async fn receive_file<Rv, S, W, A, F>(recv: &mut Rv, send: &mut S, seed: &[u8], accept: A, finalize: F) -> Result<Received, ReceiveError>
where
    Rv: AsyncRead + Unpin,
    S: AsyncWrite + Unpin,
    W: AsyncWrite + Unpin,
    A: FnOnce(&Header) -> Result<(u64, W), WireError>,
    F: FnOnce(W, &Header) -> Result<(), WireError>,
{
    let mut decoder = HeaderDecoder::new();
    let mut verdict = decoder.feed(seed);
    let mut buf = vec![0u8; 64 * 1024];
    let (header, consumed) = loop {
        match verdict {
            HeaderResult::Header(h, consumed) => break (h, consumed),
            HeaderResult::Invalid(HeaderInvalid::NotFile) => return Err(ReceiveError::NotFile),
            HeaderResult::Invalid(HeaderInvalid::BadHeader) => return refuse(send, WireError::BadHeader).await,
            HeaderResult::Invalid(HeaderInvalid::BadId) => return refuse(send, WireError::BadId).await,
            HeaderResult::NeedMore => {}
        }
        let n = recv.read(&mut buf).await.map_err(|e| ReceiveError::Io(e.to_string()))?;
        if n == 0 {
            return Err(ReceiveError::Io("the stream ended inside the header".into()));
        }
        verdict = decoder.feed(&buf[..n]);
    };
    let mut pending = decoder.buffered()[consumed..].to_vec(); // body bytes that came with the header

    let (have, mut writer) = match accept(&header) {
        Ok((have, writer)) if have <= header.size => (have, writer),
        Ok(_) => return refuse(send, WireError::Write).await, // a `have` beyond the size is a bug in the receiver, not something to send
        Err(code) => return refuse(send, code).await,
    };
    send.write_all(&encode_have(have)).await.map_err(|e| ReceiveError::Io(e.to_string()))?;
    send.flush().await.map_err(|e| ReceiveError::Io(e.to_string()))?;

    let expected = header.size - have;
    let mut got = 0u64;
    loop {
        if !pending.is_empty() {
            let room = expected.saturating_sub(got);
            let take = (pending.len() as u64).min(room) as usize;
            if writer.write_all(&pending[..take]).await.is_err() {
                return refuse(send, WireError::Write).await;
            }
            got += take as u64;
            if take < pending.len() {
                return refuse(send, WireError::Size).await; // more bytes than the size says
            }
            pending.clear();
        }
        let n = recv.read(&mut buf).await.map_err(|e| ReceiveError::Io(e.to_string()))?;
        if n == 0 {
            break; // the sender closed its side
        }
        pending.extend_from_slice(&buf[..n]);
    }
    if finish_verdict(expected as i64, got as i64) != Verdict::Ok {
        return refuse(send, WireError::Size).await;
    }
    if writer.flush().await.is_err() {
        return refuse(send, WireError::Write).await;
    }
    if let Err(code) = finalize(writer, &header) {
        return refuse(send, code).await;
    }
    send.write_all(&encode_result(true, None)).await.map_err(|e| ReceiveError::Io(e.to_string()))?;
    send.shutdown().await.map_err(|e| ReceiveError::Io(e.to_string()))?;
    Ok(Received { header, have, bytes_received: got })
}

/// Tells the sender no and closes our side.
async fn refuse<S: AsyncWrite + Unpin, T>(send: &mut S, code: WireError) -> Result<T, ReceiveError> {
    let _ = send.write_all(&encode_result(false, Some(code))).await;
    let _ = send.shutdown().await;
    Err(ReceiveError::Refused(code))
}

/// One complete message (`u16 BE length ‖ JSON`) from the stream.
async fn read_message<Rv: AsyncRead + Unpin>(recv: &mut Rv) -> Result<Vec<u8>, SendError> {
    let mut length = [0u8; 2];
    recv.read_exact(&mut length).await.map_err(io)?;
    let body_len = (usize::from(length[0]) << 8) | usize::from(length[1]);
    if body_len == 0 || body_len > HEADER_MAX_BYTES {
        return Err(SendError::Protocol);
    }
    let mut message = Vec::with_capacity(2 + body_len);
    message.extend_from_slice(&length);
    message.resize(2 + body_len, 0);
    recv.read_exact(&mut message[2..]).await.map_err(io)?;
    Ok(message)
}

fn io(e: std::io::Error) -> SendError {
    SendError::Io(e.to_string())
}
