//! The phone-side QUIC client (plan stage 1.7). A library API with no JNI in it: `connect` starts a thread that owns a current-thread
//! tokio runtime and one connection; commands go in through a queue, events come out of one [`EventSink`] in order. The JNI layer is
//! only a translation of this API, which is what lets everything here be tested on the host against an in-process server.
//!
//! The session, as the Mac's listener speaks it (stage 1.6): the first bidirectional stream carries the 32 raw token bytes and is the
//! session stream; the server answers `OK\n` (go on) or `NO\n` + FIN (refused: the client closes by itself, because Network.framework
//! cannot close for us); later it may say `END\n`. Every other stream starts with its channel's varint. Datagrams are plain.
//!
//! Nothing here formats an address, port, fingerprint, token or line into an error or a log: failures are an [`ErrorCode`].

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{mpsc as std_mpsc, Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use bytes::Bytes;
use tokio::sync::mpsc;
use tokio::time::timeout;

use crate::batch::{ChunkBatcher, StreamMode};
use crate::channel::{ChannelParse, QuicChannel};
use crate::error::ErrorCode;
use crate::params::ConnectParams;
use crate::pin::{client_config_with_flag, SERVER_NAME};

/// Application close codes (the peer sees them; they carry no data).
const CLOSE_NORMAL: u32 = 0;
const CLOSE_REFUSED: u32 = 1;
/// A stream we do not understand: STOP_SENDING with this code.
const STOP_UNKNOWN_CHANNEL: u32 = 1;
/// How many parts one `read_chunks` call may take (stage 0.6 finding 20).
const READ_PARTS: usize = 64;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Stats {
    pub rtt_ms: u64,
    pub cwnd: u64,
    pub lost_packets: u64,
    pub congestion_events: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// The server accepted the token (`OK`): the session is open.
    Connected,
    /// The connection could not be opened (or the token was refused). Nothing else follows except `Closed`.
    Failed(ErrorCode),
    /// A line of the session stream that is not protocol (`OK`, `NO` and `END` are handled here).
    SessionLine(String),
    /// The server said `END`: the session is over and the connection is being closed.
    PeerEnded,
    Datagram(Vec<u8>),
    /// A unidirectional stream of a known channel arrived (an unknown channel is refused silently).
    UniStream { id: u64, channel: QuicChannel },
    /// Bytes of that stream; `fin` marks the end. File streams arrive in big pieces, media streams as they come.
    StreamData { id: u64, bytes: Vec<u8>, fin: bool },
    Stats(Stats),
    /// The end. `None`: we or the peer ended it. `Some(LinkLost)`: an open connection was lost.
    Closed(Option<ErrorCode>),
}

/// Where events go. Called on the client's own thread, in order; keep it quick and never block.
pub trait EventSink: Send + Sync + 'static {
    fn event(&self, event: Event);
}

#[derive(Debug, Clone, Copy)]
pub struct Timeouts {
    /// The QUIC + TLS handshake.
    pub connect: Duration,
    /// The server's answer to the token. Longer than the Mac's 5 s token window, so the Mac's own refusal arrives first.
    pub token_reply: Duration,
    pub stats_every: Duration,
    /// How long `close` waits for the CONNECTION_CLOSE to leave the socket.
    pub close_wait: Duration,
}

impl Default for Timeouts {
    fn default() -> Self {
        Self {
            connect: Duration::from_secs(5),
            token_reply: Duration::from_secs(6),
            stats_every: Duration::from_millis(500),
            close_wait: Duration::from_secs(2),
        }
    }
}

enum Command {
    SessionWrite(Vec<u8>),
    Datagram(Vec<u8>),
    OpenUni(QuicChannel, std_mpsc::Sender<Result<u64, ErrorCode>>),
    StreamWrite(u64, Vec<u8>),
    StreamFinish(u64),
    Close(u32),
}

/// One session toward the Mac. Dropping it closes the connection (without waiting); [`Client::close`] waits for the thread.
pub struct Client {
    tx: mpsc::UnboundedSender<Command>,
    thread: Mutex<Option<JoinHandle<()>>>,
}

impl Client {
    /// Starts connecting. The outcome arrives as `Connected` or `Failed(code)`.
    pub fn connect(params: ConnectParams, sink: Arc<dyn EventSink>, timeouts: Timeouts) -> Client {
        let (tx, rx) = mpsc::unbounded_channel();
        let failed_sink = Arc::clone(&sink);
        let thread = std::thread::Builder::new().name("quic-core".into()).spawn(move || {
            let Ok(runtime) = tokio::runtime::Builder::new_current_thread().enable_all().build() else {
                sink.event(Event::Failed(ErrorCode::Internal));
                return;
            };
            runtime.block_on(run(params, sink, timeouts, rx));
        });
        let thread = match thread {
            Ok(handle) => Some(handle),
            Err(_) => {
                failed_sink.event(Event::Failed(ErrorCode::Internal));
                None
            }
        };
        Client { tx, thread: Mutex::new(thread) }
    }

    /// A line on the session stream (the newline is added). False when the client is gone.
    pub fn session_write(&self, line: &str) -> bool {
        let mut bytes = line.as_bytes().to_vec();
        bytes.push(b'\n');
        self.tx.send(Command::SessionWrite(bytes)).is_ok()
    }

    pub fn send_datagram(&self, bytes: &[u8]) -> bool {
        self.tx.send(Command::Datagram(bytes.to_vec())).is_ok()
    }

    /// Opens a unidirectional stream of `channel` and returns its id (waits at most 2 s: the peer may be out of stream credit).
    pub fn open_uni(&self, channel: QuicChannel) -> Result<u64, ErrorCode> {
        let (reply, answer) = std_mpsc::channel();
        self.tx.send(Command::OpenUni(channel, reply)).map_err(|_| ErrorCode::LinkLost)?;
        answer.recv_timeout(Duration::from_secs(2)).map_err(|_| ErrorCode::Timeout)?
    }

    pub fn stream_write(&self, id: u64, bytes: &[u8]) -> bool {
        self.tx.send(Command::StreamWrite(id, bytes.to_vec())).is_ok()
    }

    pub fn stream_finish(&self, id: u64) -> bool {
        self.tx.send(Command::StreamFinish(id)).is_ok()
    }

    /// Closes the connection and waits for the client thread (which gives the CONNECTION_CLOSE time to leave).
    pub fn close(&self, code: u32) {
        let _ = self.tx.send(Command::Close(code));
        let handle = self.thread.lock().ok().and_then(|mut slot| slot.take());
        if let Some(handle) = handle {
            let _ = handle.join();
        }
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        let _ = self.tx.send(Command::Close(CLOSE_NORMAL));
    }
}

fn classify(error: &quinn::ConnectionError, mismatch: &AtomicBool) -> ErrorCode {
    if mismatch.load(Ordering::SeqCst) {
        return ErrorCode::FpMismatch;
    }
    match error {
        quinn::ConnectionError::TimedOut => ErrorCode::Timeout,
        quinn::ConnectionError::TransportError(_) | quinn::ConnectionError::VersionMismatch => ErrorCode::Protocol,
        _ => ErrorCode::LinkLost,
    }
}

/// Reads newline-terminated lines from a stream.
struct LineReader {
    recv: quinn::RecvStream,
    buf: Vec<u8>,
}

impl LineReader {
    fn new(recv: quinn::RecvStream) -> Self {
        Self { recv, buf: Vec::new() }
    }

    /// The next line, or `None` when the stream ended without one.
    async fn next_line(&mut self) -> Result<Option<String>, quinn::ReadError> {
        loop {
            if let Some(pos) = self.buf.iter().position(|&b| b == b'\n') {
                let line: Vec<u8> = self.buf.drain(..=pos).collect();
                return Ok(Some(String::from_utf8_lossy(&line[..line.len() - 1]).into_owned()));
            }
            match self.recv.read_chunk(4096, true).await? {
                Some(chunk) => self.buf.extend_from_slice(&chunk.bytes),
                None => return Ok(None),
            }
        }
    }
}

async fn finish_connection(conn: &quinn::Connection, endpoint: &quinn::Endpoint, code: u32, wait: Duration) {
    conn.close(code.into(), b"");
    let _ = timeout(wait, endpoint.wait_idle()).await;
}

async fn run(params: ConnectParams, sink: Arc<dyn EventSink>, timeouts: Timeouts, mut rx: mpsc::UnboundedReceiver<Command>) {
    let Ok((config, mismatch)) = client_config_with_flag(&params.fp) else {
        sink.event(Event::Failed(ErrorCode::Internal));
        return;
    };
    let bind: SocketAddr = if params.addr.is_ipv6() { ([0u16; 8], 0).into() } else { ([0u8; 4], 0).into() };
    let Ok(mut endpoint) = quinn::Endpoint::client(bind) else {
        sink.event(Event::Failed(ErrorCode::Internal));
        return;
    };
    endpoint.set_default_client_config(config);
    let Ok(connecting) = endpoint.connect(params.addr, SERVER_NAME) else {
        sink.event(Event::Failed(ErrorCode::Internal));
        return;
    };
    let conn = match timeout(timeouts.connect, connecting).await {
        Err(_) => {
            sink.event(Event::Failed(ErrorCode::Timeout));
            return;
        }
        Ok(Err(error)) => {
            sink.event(Event::Failed(classify(&error, &mismatch)));
            return;
        }
        Ok(Ok(conn)) => conn,
    };

    // The session stream: token out, `OK`/`NO` back.
    let Ok((mut session_tx, session_rx)) = conn.open_bi().await else {
        sink.event(Event::Failed(ErrorCode::LinkLost));
        return;
    };
    if session_tx.write_all(&params.tok).await.is_err() {
        sink.event(Event::Failed(ErrorCode::LinkLost));
        return;
    }
    let mut lines = LineReader::new(session_rx);
    let verdict = match timeout(timeouts.token_reply, lines.next_line()).await {
        Err(_) => Err(ErrorCode::Timeout),
        Ok(Err(_)) => Err(ErrorCode::LinkLost),
        Ok(Ok(Some(line))) if line == "OK" => Ok(()),
        Ok(Ok(Some(line))) if line == "NO" => Err(ErrorCode::TokenRejected),
        Ok(Ok(_)) => Err(ErrorCode::Protocol),
    };
    if let Err(code) = verdict {
        // A refusal is the end: the server cannot close the connection for us, so we do it ourselves.
        finish_connection(&conn, &endpoint, CLOSE_REFUSED, timeouts.close_wait).await;
        sink.event(Event::Failed(code));
        return;
    }
    sink.event(Event::Connected);

    let next_id = Arc::new(AtomicU64::new(1));
    let (ended_tx, mut ended_rx) = mpsc::unbounded_channel::<()>();
    spawn_session_reader(lines, Arc::clone(&sink), ended_tx);
    spawn_datagram_reader(conn.clone(), Arc::clone(&sink));
    spawn_uni_acceptor(conn.clone(), Arc::clone(&sink), Arc::clone(&next_id));
    spawn_stats(conn.clone(), Arc::clone(&sink), timeouts.stats_every);

    let mut streams: HashMap<u64, quinn::SendStream> = HashMap::new();
    let mut close_code = CLOSE_NORMAL;
    let outcome = loop {
        tokio::select! {
            command = rx.recv() => match command {
                None => break None,
                Some(Command::Close(code)) => { close_code = code; break None; }
                Some(Command::SessionWrite(bytes)) => {
                    if session_tx.write_all(&bytes).await.is_err() { break Some(ErrorCode::LinkLost); }
                }
                Some(Command::Datagram(bytes)) => {
                    // A datagram is best effort: too big or not ready is dropped, not an error of the session.
                    let _ = conn.send_datagram(Bytes::from(bytes));
                }
                Some(Command::OpenUni(channel, reply)) => {
                    let result = open_uni(&conn, channel, &next_id, &mut streams).await;
                    let _ = reply.send(result);
                }
                Some(Command::StreamWrite(id, bytes)) => {
                    if let Some(stream) = streams.get_mut(&id) {
                        if stream.write_all(&bytes).await.is_err() { streams.remove(&id); }
                    }
                }
                Some(Command::StreamFinish(id)) => {
                    if let Some(mut stream) = streams.remove(&id) { let _ = stream.finish(); }
                }
            },
            // Only a real END ends the session cleanly. The reader task also drops its sender when the connection dies; that closed channel
            // must not look like an END (the pattern disables this branch then, and `conn.closed()` reports the loss).
            Some(()) = ended_rx.recv() => break None,
            _ = conn.closed() => break Some(ErrorCode::LinkLost),
        }
    };
    if outcome.is_none() {
        finish_connection(&conn, &endpoint, close_code, timeouts.close_wait).await;
    }
    sink.event(Event::Closed(outcome));
}

async fn open_uni(
    conn: &quinn::Connection,
    channel: QuicChannel,
    next_id: &AtomicU64,
    streams: &mut HashMap<u64, quinn::SendStream>,
) -> Result<u64, ErrorCode> {
    let mut stream = timeout(Duration::from_secs(2), conn.open_uni())
        .await
        .map_err(|_| ErrorCode::Timeout)?
        .map_err(|_| ErrorCode::LinkLost)?;
    stream.write_all(&channel.header()).await.map_err(|_| ErrorCode::LinkLost)?;
    let id = next_id.fetch_add(1, Ordering::SeqCst);
    streams.insert(id, stream);
    Ok(id)
}

fn spawn_session_reader(mut lines: LineReader, sink: Arc<dyn EventSink>, ended: mpsc::UnboundedSender<()>) {
    tokio::spawn(async move {
        loop {
            match lines.next_line().await {
                Ok(Some(line)) if line == "END" => {
                    sink.event(Event::PeerEnded);
                    let _ = ended.send(());
                    return;
                }
                Ok(Some(line)) => sink.event(Event::SessionLine(line)),
                // The session stream closing or failing is the connection's business (`conn.closed()` reports it).
                Ok(None) | Err(_) => return,
            }
        }
    });
}

fn spawn_datagram_reader(conn: quinn::Connection, sink: Arc<dyn EventSink>) {
    tokio::spawn(async move {
        while let Ok(datagram) = conn.read_datagram().await {
            sink.event(Event::Datagram(datagram.to_vec()));
        }
    });
}

fn spawn_stats(conn: quinn::Connection, sink: Arc<dyn EventSink>, every: Duration) {
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(every);
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        ticker.tick().await; // the first tick is immediate
        loop {
            ticker.tick().await;
            if conn.close_reason().is_some() {
                return;
            }
            let path = conn.stats().path;
            sink.event(Event::Stats(Stats {
                rtt_ms: path.rtt.as_millis() as u64,
                cwnd: path.cwnd,
                lost_packets: path.lost_packets,
                congestion_events: path.congestion_events,
            }));
        }
    });
}

fn spawn_uni_acceptor(conn: quinn::Connection, sink: Arc<dyn EventSink>, next_id: Arc<AtomicU64>) {
    tokio::spawn(async move {
        while let Ok(recv) = conn.accept_uni().await {
            let id = next_id.fetch_add(1, Ordering::SeqCst);
            tokio::spawn(read_uni(recv, id, Arc::clone(&sink)));
        }
    });
}

/// One incoming unidirectional stream: its channel first, then its bytes (batched for files, immediate for media).
async fn read_uni(mut recv: quinn::RecvStream, id: u64, sink: Arc<dyn EventSink>) {
    let mut head: Vec<u8> = Vec::new();
    let (channel, rest) = loop {
        match recv.read_chunk(4096, true).await {
            Ok(Some(chunk)) => head.extend_from_slice(&chunk.bytes),
            _ => return, // ended before saying what it is
        }
        match QuicChannel::parse(&head) {
            ChannelParse::NeedMoreBytes => continue,
            ChannelParse::Unknown(..) => {
                let _ = recv.stop(STOP_UNKNOWN_CHANNEL.into());
                return;
            }
            ChannelParse::Known(channel, consumed) => break (channel, head.split_off(consumed)),
        }
    };
    sink.event(Event::UniStream { id, channel });
    match StreamMode::for_channel(channel) {
        StreamMode::Immediate => {
            if !rest.is_empty() {
                sink.event(Event::StreamData { id, bytes: rest, fin: false });
            }
            loop {
                match recv.read_chunk(64 * 1024, true).await {
                    Ok(Some(chunk)) => sink.event(Event::StreamData { id, bytes: chunk.bytes.to_vec(), fin: false }),
                    Ok(None) => break,
                    Err(_) => return,
                }
            }
            sink.event(Event::StreamData { id, bytes: Vec::new(), fin: true });
        }
        StreamMode::Batched(threshold) => {
            let mut batcher = ChunkBatcher::new(threshold);
            if let Some(piece) = batcher.push(rest) {
                sink.event(Event::StreamData { id, bytes: piece, fin: false });
            }
            let mut parts = vec![Bytes::new(); READ_PARTS];
            loop {
                match recv.read_chunks(&mut parts).await {
                    Ok(Some(count)) => {
                        for part in &parts[..count] {
                            if let Some(piece) = batcher.push_slice(part) {
                                sink.event(Event::StreamData { id, bytes: piece, fin: false });
                            }
                        }
                    }
                    Ok(None) => break,
                    Err(_) => return,
                }
            }
            // The end of the stream releases what is left, together with the end marker.
            sink.event(Event::StreamData { id, bytes: batcher.finish().unwrap_or_default(), fin: true });
        }
    }
}
