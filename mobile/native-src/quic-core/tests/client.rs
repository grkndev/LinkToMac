//! The phone-side client against an in-process quinn server that speaks the Mac's session protocol (stage 1.7): first bidi stream = the 32
//! raw token bytes, `OK\n` / `NO\n` back, `END\n` to end, channel varint on every other stream. No JNI, no device: everything the client
//! decides (error codes, timeouts, batching, closing) is proven here.

use std::net::{SocketAddr, UdpSocket};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use quic_core::channel::QuicChannel;
use quic_core::client::{Client, Event, EventSink, Timeouts};
use quic_core::error::ErrorCode;
use quic_core::params::{encode_token, ConnectParams};
use quic_core::pin::{fingerprint_hex, ALPN};

// ---------------------------------------------------------------- the test server

#[derive(Clone, Copy, PartialEq, Eq)]
enum Behavior {
    /// `OK` for the right token (`NO` for any other), then echo session lines and datagrams; `COUNT` reports finished uni streams.
    Echo,
    /// Reads the token and says nothing.
    SilentAfterToken,
    /// `OK`, then closes the connection abruptly.
    DropAfterOk,
    /// `OK`, then `END`.
    EndAfterOk,
    /// `OK`, then finishes its session stream but keeps the connection (and echoes datagrams).
    FinSessionAfterOk,
    /// `OK`, then opens three uni streams toward the client: screen (3 parts), file (2.1 MB) and an unknown channel.
    SendUni,
}

#[derive(Debug)]
enum Report {
    Closed(quinn::ConnectionError),
    UnknownStreamStopped(Option<u64>),
}

struct TestServer {
    addr: SocketAddr,
    fp: String,
    token: [u8; 32],
    reports: Receiver<Report>,
}

const TOKEN: [u8; 32] = {
    let mut t = [0u8; 32];
    let mut i = 0;
    while i < 32 {
        t[i] = i as u8;
        i += 1;
    }
    t
};

fn file_pattern(len: usize) -> Vec<u8> {
    (0..len).map(|i| (i % 251) as u8).collect()
}

fn start_server(behavior: Behavior) -> TestServer {
    let generated = rcgen::generate_simple_self_signed(vec!["link-to-mac".to_string()]).unwrap();
    let cert_der = generated.cert.der().clone();
    let fp = fingerprint_hex(cert_der.as_ref());
    let key = rustls::pki_types::PrivatePkcs8KeyDer::from(generated.key_pair.serialize_der());
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut tls = rustls::ServerConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(vec![cert_der], key.into())
        .unwrap();
    tls.alpn_protocols = vec![ALPN.to_vec()];
    let quic = quinn::crypto::rustls::QuicServerConfig::try_from(tls).unwrap();
    let config = quinn::ServerConfig::with_crypto(Arc::new(quic));

    let (addr_tx, addr_rx) = mpsc::channel();
    let (report_tx, reports) = mpsc::channel();
    std::thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        runtime.block_on(async move {
            let endpoint = quinn::Endpoint::server(config, "127.0.0.1:0".parse().unwrap()).unwrap();
            addr_tx.send(endpoint.local_addr().unwrap()).unwrap();
            if let Some(incoming) = endpoint.accept().await {
                if let Ok(conn) = incoming.await {
                    serve(conn, behavior, report_tx).await;
                }
            }
            // Without this the endpoint is dropped with the CONNECTION_CLOSE still queued and the client never hears it.
            let _ = tokio::time::timeout(Duration::from_secs(2), endpoint.wait_idle()).await;
        });
    });
    TestServer { addr: addr_rx.recv().unwrap(), fp, token: TOKEN, reports }
}

async fn read_line(recv: &mut quinn::RecvStream, buf: &mut Vec<u8>) -> Option<String> {
    loop {
        if let Some(pos) = buf.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = buf.drain(..=pos).collect();
            return Some(String::from_utf8_lossy(&line[..line.len() - 1]).into_owned());
        }
        match recv.read_chunk(4096, true).await {
            Ok(Some(chunk)) => buf.extend_from_slice(&chunk.bytes),
            _ => return None,
        }
    }
}

async fn serve(conn: quinn::Connection, behavior: Behavior, report: Sender<Report>) {
    let Ok((mut send, mut recv)) = conn.accept_bi().await else { return };
    let mut token = [0u8; 32];
    if recv.read_exact(&mut token).await.is_err() {
        return;
    }
    let reporter = conn.clone();
    let closed_report = report.clone();
    tokio::spawn(async move {
        let reason = reporter.closed().await;
        let _ = closed_report.send(Report::Closed(reason));
    });
    if behavior == Behavior::SilentAfterToken {
        conn.closed().await;
        return;
    }
    if token != TOKEN {
        let _ = send.write_all(b"NO\n").await;
        let _ = send.finish();
        conn.closed().await;
        return;
    }
    let _ = send.write_all(b"OK\n").await;
    match behavior {
        Behavior::DropAfterOk => {
            tokio::time::sleep(Duration::from_millis(100)).await;
            conn.close(7u32.into(), b"");
            conn.closed().await;
            return;
        }
        Behavior::EndAfterOk => {
            let _ = send.write_all(b"END\n").await;
            conn.closed().await;
            return;
        }
        Behavior::SendUni => {
            send_uni_streams(&conn, &report).await;
        }
        Behavior::FinSessionAfterOk => {
            let _ = send.finish();
        }
        _ => {}
    }
    // Echo: datagrams, uni stream counting, session lines.
    let counted = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let dg = conn.clone();
    tokio::spawn(async move {
        while let Ok(d) = dg.read_datagram().await {
            let _ = dg.send_datagram(d);
        }
    });
    let uni = conn.clone();
    let uni_count = Arc::clone(&counted);
    tokio::spawn(async move {
        while let Ok(mut s) = uni.accept_uni().await {
            let count = Arc::clone(&uni_count);
            tokio::spawn(async move {
                let mut sink = Vec::new();
                loop {
                    match s.read_chunk(65536, true).await {
                        Ok(Some(c)) => sink.extend_from_slice(&c.bytes),
                        Ok(None) => break,
                        Err(_) => return,
                    }
                }
                count.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            });
        }
    });
    let mut buf = Vec::new();
    while let Some(line) = read_line(&mut recv, &mut buf).await {
        let reply = if line == "COUNT" { format!("COUNT {}", counted.load(std::sync::atomic::Ordering::SeqCst)) } else { line };
        if send.write_all(format!("{reply}\n").as_bytes()).await.is_err() {
            return;
        }
    }
    conn.closed().await;
}

async fn send_uni_streams(conn: &quinn::Connection, report: &Sender<Report>) {
    // 1: screen (immediate delivery): the channel byte, then three parts.
    if let Ok(mut s) = conn.open_uni().await {
        let _ = s.write_all(&[2]).await;
        for part in [b"aaa".as_slice(), b"bbb", b"ccc"] {
            let _ = s.write_all(part).await;
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        let _ = s.finish();
    }
    // 2: file (batched): 2.1 MB written in packet-sized parts.
    if let Ok(mut s) = conn.open_uni().await {
        let _ = s.write_all(&[1]).await;
        for chunk in file_pattern(2_100_000).chunks(1400) {
            let _ = s.write_all(chunk).await;
        }
        let _ = s.finish();
    }
    // 3: a channel nobody knows: the client must refuse it (STOP_SENDING), and we report what we saw.
    if let Ok(mut s) = conn.open_uni().await {
        let _ = s.write_all(&[0x3f, 1, 2, 3]).await;
        let stopped = tokio::time::timeout(Duration::from_secs(3), s.stopped()).await;
        let code = match stopped {
            Ok(Ok(Some(code))) => Some(u64::from(code)),
            _ => None,
        };
        let _ = report.send(Report::UnknownStreamStopped(code));
    }
}

// ---------------------------------------------------------------- the test client side

struct Collector(Mutex<Sender<Event>>);

impl EventSink for Collector {
    fn event(&self, event: Event) {
        let _ = self.0.lock().unwrap().send(event);
    }
}

struct Events {
    rx: Receiver<Event>,
    seen: Vec<Event>,
}

impl Events {
    /// Waits for an event the predicate accepts; everything that arrives meanwhile is kept in `seen`.
    fn wait(&mut self, within: Duration, pred: impl Fn(&Event) -> bool) -> Option<Event> {
        let deadline = Instant::now() + within;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match self.rx.recv_timeout(left) {
                Ok(event) => {
                    let hit = pred(&event);
                    self.seen.push(event.clone());
                    if hit {
                        return Some(event);
                    }
                }
                Err(_) => return None,
            }
        }
    }
}

fn fast() -> Timeouts {
    Timeouts { connect: Duration::from_secs(3), token_reply: Duration::from_secs(2), stats_every: Duration::from_millis(150), close_wait: Duration::from_secs(2) }
}

fn start_client(addr: SocketAddr, fp: &str, token: &[u8; 32], timeouts: Timeouts) -> (Client, Events) {
    let (tx, rx) = mpsc::channel();
    let params = ConnectParams::parse(&addr.ip().to_string(), addr.port(), fp, &encode_token(token)).unwrap();
    let client = Client::connect(params, Arc::new(Collector(Mutex::new(tx))), timeouts);
    (client, Events { rx, seen: Vec::new() })
}

const WAIT: Duration = Duration::from_secs(5);

fn is_stats(e: &Event) -> bool {
    matches!(e, Event::Stats(_))
}

// ---------------------------------------------------------------- tests

#[test]
fn a_session_opens_and_echoes_lines_datagrams_and_counts_uni_streams() {
    let server = start_server(Behavior::Echo);
    let (client, mut events) = start_client(server.addr, &server.fp, &server.token, fast());
    assert_eq!(events.wait(WAIT, |e| *e == Event::Connected), Some(Event::Connected));

    assert!(client.session_write("hello"));
    assert!(events.wait(WAIT, |e| *e == Event::SessionLine("hello".into())).is_some());

    assert!(client.send_datagram(&[1, 2, 3]));
    assert!(events.wait(WAIT, |e| *e == Event::Datagram(vec![1, 2, 3])).is_some());

    let id = client.open_uni(QuicChannel::Screen).unwrap();
    assert!(client.stream_write(id, b"xyz"));
    assert!(client.stream_finish(id));
    // The server counts a stream once it has read it to the end: ask until it reports one.
    let mut counted = false;
    for _ in 0..20 {
        client.session_write("COUNT");
        if events.wait(Duration::from_millis(300), |e| *e == Event::SessionLine("COUNT 1".into())).is_some() {
            counted = true;
            break;
        }
    }
    assert!(counted, "the server never counted the uni stream");
    client.close(0);
}

#[test]
fn the_wrong_certificate_is_a_fingerprint_mismatch() {
    let server = start_server(Behavior::Echo);
    let mut wrong = server.fp.clone();
    wrong.replace_range(0..1, if wrong.starts_with('a') { "b" } else { "a" });
    let (_client, mut events) = start_client(server.addr, &wrong, &server.token, fast());
    assert_eq!(events.wait(WAIT, |e| matches!(e, Event::Failed(_))), Some(Event::Failed(ErrorCode::FpMismatch)));
    assert!(!events.seen.contains(&Event::Connected));
}

#[test]
fn the_wrong_token_is_refused_and_the_client_closes_the_connection_itself() {
    let server = start_server(Behavior::Echo);
    let mut wrong = server.token;
    wrong[31] ^= 1;
    let (_client, mut events) = start_client(server.addr, &server.fp, &wrong, fast());
    assert_eq!(events.wait(WAIT, |e| matches!(e, Event::Failed(_))), Some(Event::Failed(ErrorCode::TokenRejected)));
    // The server cannot close for us (Network.framework): it must SEE the client close, with the refusal code.
    let closed = server.reports.recv_timeout(Duration::from_secs(3)).expect("the server never saw the connection close");
    assert!(matches!(&closed, Report::Closed(quinn::ConnectionError::ApplicationClosed(c)) if u64::from(c.error_code) == 1), "{closed:?}");
}

#[test]
fn a_server_that_never_answers_the_token_is_a_timeout() {
    let server = start_server(Behavior::SilentAfterToken);
    let mut t = fast();
    t.token_reply = Duration::from_millis(500);
    let started = Instant::now();
    let (_client, mut events) = start_client(server.addr, &server.fp, &server.token, t);
    assert_eq!(events.wait(WAIT, |e| matches!(e, Event::Failed(_))), Some(Event::Failed(ErrorCode::Timeout)));
    assert!(started.elapsed() < Duration::from_secs(3));
}

#[test]
fn nobody_there_is_a_timeout() {
    // A socket that is bound and never answers: the handshake can neither finish nor fail.
    let silent = UdpSocket::bind("127.0.0.1:0").unwrap();
    let addr = silent.local_addr().unwrap();
    let mut t = fast();
    t.connect = Duration::from_millis(600);
    let (_client, mut events) = start_client(addr, &"ab".repeat(32), &TOKEN, t);
    assert_eq!(events.wait(WAIT, |e| matches!(e, Event::Failed(_))), Some(Event::Failed(ErrorCode::Timeout)));
}

#[test]
fn a_connection_lost_after_the_session_opened_is_link_lost() {
    let server = start_server(Behavior::DropAfterOk);
    let (_client, mut events) = start_client(server.addr, &server.fp, &server.token, fast());
    assert!(events.wait(WAIT, |e| *e == Event::Connected).is_some());
    let closed = events.wait(WAIT, |e| matches!(e, Event::Closed(_)));
    assert_eq!(closed, Some(Event::Closed(Some(ErrorCode::LinkLost))), "events seen: {:?}", events.seen);
}

#[test]
fn the_server_saying_end_ends_the_session_cleanly() {
    let server = start_server(Behavior::EndAfterOk);
    let (_client, mut events) = start_client(server.addr, &server.fp, &server.token, fast());
    assert!(events.wait(WAIT, |e| *e == Event::Connected).is_some());
    assert!(events.wait(WAIT, |e| *e == Event::PeerEnded).is_some());
    assert_eq!(events.wait(WAIT, |e| matches!(e, Event::Closed(_))), Some(Event::Closed(None)));
    let pos = |wanted: &Event| events.seen.iter().position(|e| e == wanted).unwrap();
    assert!(pos(&Event::PeerEnded) < pos(&Event::Closed(None)), "PeerEnded must come before Closed");
}

#[test]
fn closing_puts_the_connection_close_on_the_wire() {
    // Stage 1.6 lesson: a process that exits right after `close()` leaves the peer waiting. `Client::close` waits for the datagram to go.
    let server = start_server(Behavior::Echo);
    let (client, mut events) = start_client(server.addr, &server.fp, &server.token, fast());
    assert!(events.wait(WAIT, |e| *e == Event::Connected).is_some());
    let started = Instant::now();
    client.close(5);
    let closed = server.reports.recv_timeout(Duration::from_secs(2)).expect("the server never saw the close");
    assert!(matches!(&closed, Report::Closed(quinn::ConnectionError::ApplicationClosed(c)) if u64::from(c.error_code) == 5), "{closed:?}");
    assert!(started.elapsed() < Duration::from_secs(2));
    assert_eq!(events.wait(WAIT, |e| matches!(e, Event::Closed(_))), Some(Event::Closed(None)));
}

#[test]
fn statistics_arrive_regularly() {
    let server = start_server(Behavior::Echo);
    let (client, mut events) = start_client(server.addr, &server.fp, &server.token, fast());
    assert!(events.wait(WAIT, |e| *e == Event::Connected).is_some());
    assert!(events.wait(WAIT, is_stats).is_some());
    assert!(events.wait(WAIT, is_stats).is_some());
    if let Some(Event::Stats(s)) = events.seen.iter().rev().find(|e| is_stats(e)) {
        assert!(s.cwnd > 0, "a congestion window of 0 means the stats are not read from the connection");
    }
    client.close(0);
}

#[test]
fn incoming_streams_are_batched_for_files_immediate_for_media_and_refused_for_unknown_channels() {
    let server = start_server(Behavior::SendUni);
    let (client, mut events) = start_client(server.addr, &server.fp, &server.token, fast());
    assert!(events.wait(WAIT, |e| *e == Event::Connected).is_some());

    // Wait until both known streams ended (a StreamData with fin for each).
    let fins = |events: &Events| events.seen.iter().filter(|e| matches!(e, Event::StreamData { fin: true, .. })).count();
    let deadline = Instant::now() + Duration::from_secs(15);
    while fins(&events) < 2 && Instant::now() < deadline {
        events.wait(Duration::from_millis(200), |_| false);
    }
    assert_eq!(fins(&events), 2, "both known streams must finish");

    let mut screen_id = None;
    let mut file_id = None;
    for e in &events.seen {
        if let Event::UniStream { id, channel } = e {
            match channel {
                QuicChannel::Screen => screen_id = Some(*id),
                QuicChannel::File => file_id = Some(*id),
                QuicChannel::Camera => panic!("no camera stream was sent"),
            }
        }
    }
    let (screen_id, file_id) = (screen_id.expect("no screen stream"), file_id.expect("no file stream"));
    assert_eq!(events.seen.iter().filter(|e| matches!(e, Event::UniStream { .. })).count(), 2, "the unknown channel must not surface");

    let data = |wanted: u64| -> Vec<(Vec<u8>, bool)> {
        events.seen.iter().filter_map(|e| match e {
            Event::StreamData { id, bytes, fin } if *id == wanted => Some((bytes.clone(), *fin)),
            _ => None,
        }).collect()
    };

    // Media: delivered as it comes, never collected: the three parts of 3 bytes are not one 9-byte piece.
    let screen = data(screen_id);
    let screen_bytes: Vec<u8> = screen.iter().flat_map(|(b, _)| b.clone()).collect();
    assert_eq!(screen_bytes, b"aaabbbccc");
    assert!(screen.iter().filter(|(b, _)| !b.is_empty()).count() >= 2, "media must not be batched: {} pieces", screen.len());
    assert!(screen.last().unwrap().1, "the last piece carries the end marker");

    // File: complete, in order, in big pieces (at least 1 MiB each except the last).
    let file = data(file_id);
    let file_bytes: Vec<u8> = file.iter().flat_map(|(b, _)| b.clone()).collect();
    assert!(file_bytes == file_pattern(2_100_000), "the file differs or is out of order ({} bytes)", file_bytes.len());
    for (bytes, fin) in &file[..file.len() - 1] {
        assert!(!fin);
        assert!(bytes.len() >= 1024 * 1024, "a piece of {} bytes: the batching is not working", bytes.len());
    }
    assert!(file.last().unwrap().1);
    assert!(file.len() <= 4, "{} deliveries for 2.1 MB", file.len());

    // The unknown channel was refused with STOP_SENDING.
    let mut stopped = None;
    while let Ok(report) = server.reports.recv_timeout(Duration::from_secs(4)) {
        if let Report::UnknownStreamStopped(code) = report {
            stopped = Some(code);
            break;
        }
    }
    assert_eq!(stopped, Some(Some(1)), "the unknown stream must be refused with the unknown-channel code");
    client.close(0);
}

#[test]
fn a_client_that_is_dropped_closes_quietly() {
    let server = start_server(Behavior::Echo);
    let (client, mut events) = start_client(server.addr, &server.fp, &server.token, fast());
    assert!(events.wait(WAIT, |e| *e == Event::Connected).is_some());
    drop(client);
    let closed = server.reports.recv_timeout(Duration::from_secs(3));
    assert!(matches!(closed, Ok(Report::Closed(_))), "{closed:?}");
}

#[test]
fn a_session_stream_that_ends_while_the_connection_lives_is_not_the_end_of_the_session() {
    // Only `END` (or a lost connection) ends a session. The session stream alone finishing says nothing about the connection:
    // the datagram path must keep working and no `Closed` may be reported.
    let server = start_server(Behavior::FinSessionAfterOk);
    let (client, mut events) = start_client(server.addr, &server.fp, &server.token, fast());
    assert!(events.wait(WAIT, |e| *e == Event::Connected).is_some());
    assert!(events.wait(Duration::from_millis(700), |e| matches!(e, Event::Closed(_))).is_none(), "{:?}", events.seen);
    assert!(client.send_datagram(&[9, 9]));
    assert!(events.wait(WAIT, |e| *e == Event::Datagram(vec![9, 9])).is_some(), "the connection died with its session stream");
    client.close(0);
}
