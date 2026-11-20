//! A small QUIC client for the Mac's session server (plan stage 1.6): proves the listener without a phone.
//!
//!   echo_client --addr 127.0.0.1:53125 --fp <64 hex> --tok <43 chars base64url> --scenario <name> [--count N] [--wait SECS] [--expect-block]
//!
//! The wire format is the one stage 1.7's real client will speak: the first bidirectional stream carries the 32 raw token bytes
//! (no type byte); the server answers `OK\n`, or `NO\n` + FIN when it refuses. After `OK` the debug `echo` kind echoes every line of the
//! session stream and every datagram, answers `COUNT\n` with `COUNT <finished uni streams>\n`, and sends `END\n` when it ends the session.
//! Other streams start with their channel's varint (1 file, 2 screen, 3 camera).
//!
//! Scenarios (one `RESULT <name> PASS|FAIL <ms>ms <detail>` line each; exit 0 only on PASS):
//!   happy        correct fp + tok: OK, session lines echoed, one datagram echoed
//!   early-datagram  a datagram sent BEFORE the token is dropped (no echo), one sent after it is echoed (stage 0.4 finding 11)
//!   wrong-tok    last token byte flipped: `NO` within 1 s, then this client closes the connection itself
//!   wrong-fp     fingerprint flipped: the TLS handshake is refused
//!   streams      --count N short uni streams; none may block and COUNT must report N (with --expect-block: the sender MUST stall)
//!   chatter      one echoed line per second for --wait SECS (default 6), then silence: `END` must follow 2.5-4.5 s after the last echoed line
//!                (meant for a server with a 3 s idle limit: traffic must keep the session alive, silence must end it)
//!   idle         authenticate and stay silent: the server ends the session with `END` after about 30 s (--wait SECS, default 40)
//!   hold         authenticate and wait up to --wait SECS (default 15) for `END` (the Mac ended the session)
//!   linger       authenticate, then stay connected and never read the session stream for --wait SECS (default 8), then close
//!   second-conn  a second connection with the SAME token must not get `OK`
//!
//! Not part of the Android library: an example, built only with `cargo build --example echo_client`.

use std::net::SocketAddr;
use std::process::ExitCode;
use std::time::{Duration, Instant};

use quic_core::params::decode_token;
use quic_core::pin::{client_config, parse_fingerprint_hex, FINGERPRINT_LEN, SERVER_NAME};
use tokio::time::timeout;

type Res<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

#[derive(Debug, Default)]
struct Args {
    addr: Option<SocketAddr>,
    fp: Option<[u8; FINGERPRINT_LEN]>,
    tok: Option<[u8; 32]>,
    scenario: String,
    count: u32,
    wait: Option<u64>,
    expect_block: bool,
}

fn parse_args() -> Result<Args, String> {
    let mut args = Args { scenario: "happy".into(), ..Args::default() };
    let mut it = std::env::args().skip(1);
    while let Some(flag) = it.next() {
        if flag == "--expect-block" {
            args.expect_block = true;
            continue;
        }
        let value = it.next().ok_or(format!("{flag} needs a value"))?;
        match flag.as_str() {
            "--addr" => args.addr = Some(value.parse().map_err(|e| format!("--addr: {e}"))?),
            "--fp" => args.fp = Some(parse_fingerprint_hex(&value).map_err(|e| format!("--fp: {e:?}"))?),
            "--tok" => args.tok = Some(decode_token(&value).map_err(|e| e.to_string())?),
            "--scenario" => args.scenario = value,
            "--count" => args.count = value.parse().map_err(|e| format!("--count: {e}"))?,
            "--wait" => args.wait = Some(value.parse().map_err(|e| format!("--wait: {e}"))?),
            other => return Err(format!("unknown flag {other}")),
        }
    }
    Ok(args)
}

async fn connect(addr: SocketAddr, fp: &[u8]) -> Res<(quinn::Endpoint, quinn::Connection)> {
    let mut endpoint = quinn::Endpoint::client("0.0.0.0:0".parse()?)?;
    endpoint.set_default_client_config(client_config(fp)?);
    let conn = endpoint.connect(addr, SERVER_NAME)?.await?;
    Ok((endpoint, conn))
}

async fn read_line(recv: &mut quinn::RecvStream, buf: &mut Vec<u8>) -> Res<String> {
    loop {
        if let Some(pos) = buf.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = buf.drain(..=pos).collect();
            return Ok(String::from_utf8_lossy(&line[..line.len() - 1]).into_owned());
        }
        match recv.read_chunk(4096, true).await? {
            Some(chunk) => buf.extend_from_slice(&chunk.bytes),
            None => return Err("session stream closed before a full line".into()),
        }
    }
}

struct Session {
    conn: quinn::Connection,
    endpoint: quinn::Endpoint,
    send: quinn::SendStream,
    recv: quinn::RecvStream,
    lines: Vec<u8>,
}

/// Connects, writes the token on the first bidi stream and returns the server's first line with the open streams.
async fn open(addr: SocketAddr, fp: &[u8], tok: &[u8; 32]) -> Res<(Session, String)> {
    let (endpoint, conn) = connect(addr, fp).await?;
    let (mut send, mut recv) = conn.open_bi().await?;
    send.write_all(tok).await?;
    let mut lines = Vec::new();
    let first = read_line(&mut recv, &mut lines).await?;
    Ok((Session { conn, endpoint, send, recv, lines }, first))
}

async fn authenticate(addr: SocketAddr, fp: &[u8], tok: &[u8; 32]) -> Res<Session> {
    let (session, first) = open(addr, fp, tok).await?;
    if first != "OK" {
        return Err(format!("the server answered {first:?}, expected OK").into());
    }
    Ok(session)
}

/// Closes the connection and gives the endpoint a moment to actually put the CONNECTION_CLOSE on the wire: a process that exits right
/// after `close()` would leave the peer waiting for a connection that is already gone (the phone's process keeps running, this one ends).
async fn shutdown(conn: &quinn::Connection, endpoint: &quinn::Endpoint, code: u32, reason: &[u8]) {
    conn.close(code.into(), reason);
    let _ = timeout(Duration::from_secs(2), endpoint.wait_idle()).await;
}

async fn happy(args: &Args) -> Res<String> {
    let (addr, fp, tok) = need(args)?;
    let mut s = authenticate(addr, &fp, &tok).await?;
    for i in 0..5 {
        let line = format!("ping-{i}-{}", "x".repeat(i * 100));
        s.send.write_all(format!("{line}\n").as_bytes()).await?;
        let back = timeout(Duration::from_secs(3), read_line(&mut s.recv, &mut s.lines)).await??;
        if back != line {
            return Err(format!("line {i} came back as {back:?}").into());
        }
    }
    let datagram: Vec<u8> = (0..300u32).map(|i| (i * 7 % 251) as u8).collect();
    s.conn.send_datagram(datagram.clone().into())?;
    let back = timeout(Duration::from_secs(3), s.conn.read_datagram()).await??;
    if back.as_ref() != datagram.as_slice() {
        return Err(format!("datagram came back with {} bytes, sent {}", back.len(), datagram.len()).into());
    }
    shutdown(&s.conn, &s.endpoint, 0, b"done").await;
    Ok("OK, 5 session lines and 1 datagram echoed".into())
}

/// A datagram can overtake the stream message that authorises it (stage 0.4 finding 11), so the server drops everything that arrives
/// before the token has been accepted. The early one must never come back; the late one must.
async fn early_datagram(args: &Args) -> Res<String> {
    let (addr, fp, tok) = need(args)?;
    let (endpoint, conn) = connect(addr, &fp).await?;
    conn.send_datagram(b"early".to_vec().into())?;
    match timeout(Duration::from_millis(1200), conn.read_datagram()).await {
        Err(_) => {} // nothing came back: dropped, as intended
        Ok(Ok(d)) => return Err(format!("a datagram arrived before the token: {} bytes {:?}", d.len(), String::from_utf8_lossy(&d)).into()),
        Ok(Err(e)) => return Err(format!("the connection died after a datagram sent before the token: {e}").into()),
    }
    let (mut send, mut recv) = conn.open_bi().await?;
    send.write_all(&tok).await?;
    let mut lines = Vec::new();
    let first = read_line(&mut recv, &mut lines).await?;
    if first != "OK" {
        return Err(format!("the server answered {first:?}, expected OK").into());
    }
    conn.send_datagram(b"late".to_vec().into())?;
    let back = timeout(Duration::from_secs(3), conn.read_datagram()).await??;
    if back.as_ref() != b"late" {
        return Err(format!("expected the late datagram back, got {} bytes", back.len()).into());
    }
    shutdown(&conn, &endpoint, 0, b"done").await;
    Ok("early datagram dropped, late datagram echoed".into())
}

async fn wrong_tok(args: &Args) -> Res<String> {
    let (addr, fp, mut tok) = need(args)?;
    tok[31] ^= 0x01;
    let started = Instant::now();
    let (s, first) = timeout(Duration::from_secs(3), open(addr, &fp, &tok)).await??;
    let elapsed = started.elapsed();
    if first != "NO" {
        return Err(format!("expected NO, got {first:?}").into());
    }
    if elapsed > Duration::from_secs(1) {
        return Err(format!("NO took {} ms (limit 1000)", elapsed.as_millis()).into());
    }
    // The server cannot close the connection for us (Network.framework): the client leaves by itself.
    shutdown(&s.conn, &s.endpoint, 1, b"refused").await;
    Ok(format!("NO after {} ms, client closed", elapsed.as_millis()))
}

async fn wrong_fp(args: &Args) -> Res<String> {
    let (addr, mut fp, _tok) = need(args)?;
    fp[0] ^= 0x01;
    match timeout(Duration::from_secs(5), connect(addr, &fp)).await {
        Ok(Ok(_)) => Err("connected with the wrong fingerprint".into()),
        Ok(Err(e)) => Ok(format!("handshake refused: {e}")),
        Err(_) => Err("the handshake neither finished nor failed within 5 s".into()),
    }
}

async fn streams(args: &Args) -> Res<String> {
    let (addr, fp, tok) = need(args)?;
    let n = args.count.max(1);
    let mut s = authenticate(addr, &fp, &tok).await?;
    let mut opened = 0u32;
    let mut blocked_at = None;
    let mut handles = Vec::new();
    for i in 0..n {
        match timeout(Duration::from_secs(3), s.conn.open_uni()).await {
            Ok(Ok(mut stream)) => {
                handles.push(tokio::spawn(async move {
                    // channel 2 (screen) and a short body; the server drains it and counts it
                    let _ = stream.write_all(&[0x02, 1, 2, 3, 4, 5, 6, 7, 8]).await;
                    let _ = stream.finish();
                }));
                opened += 1;
                if handles.len() >= 200 {
                    for h in handles.drain(..) {
                        h.await?;
                    }
                }
            }
            Ok(Err(e)) => return Err(format!("open_uni #{i} failed: {e}").into()),
            Err(_) => {
                blocked_at = Some(i);
                break;
            }
        }
    }
    for h in handles.drain(..) {
        h.await?;
    }
    if args.expect_block {
        return match blocked_at {
            Some(at) => Ok(format!("stalled at stream {at} as expected ({opened} opened)")),
            None => Err(format!("expected the sender to stall but all {opened} streams opened").into()),
        };
    }
    if let Some(at) = blocked_at {
        return Err(format!("open_uni blocked at stream {at} (no credit)").into());
    }
    // The server counts a stream when it has read it to the end: poll until it has seen them all.
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut last = String::new();
    while Instant::now() < deadline {
        s.send.write_all(b"COUNT\n").await?;
        last = timeout(Duration::from_secs(3), read_line(&mut s.recv, &mut s.lines)).await??;
        if last == format!("COUNT {opened}") {
            shutdown(&s.conn, &s.endpoint, 0, b"done").await;
            return Ok(format!("{opened} uni streams opened and counted"));
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    Err(format!("the server never reported {opened} streams (last answer {last:?})").into())
}

async fn chatter(args: &Args) -> Res<String> {
    let (addr, fp, tok) = need(args)?;
    let mut s = authenticate(addr, &fp, &tok).await?;
    let lines = args.wait.unwrap_or(6);
    let mut last_echo = Instant::now();
    for i in 0..lines {
        let line = format!("tick-{i}");
        s.send.write_all(format!("{line}\n").as_bytes()).await?;
        let back = timeout(Duration::from_secs(2), read_line(&mut s.recv, &mut s.lines))
            .await
            .map_err(|_| format!("session ended or silent at line {i}"))??;
        if back != line {
            return Err(format!("line {i} came back as {back:?} (END before the silence?)").into());
        }
        last_echo = Instant::now();
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    let line = timeout(Duration::from_secs(8), read_line(&mut s.recv, &mut s.lines)).await.map_err(|_| "no END after the silence")??;
    let gap = last_echo.elapsed().as_secs_f64();
    if line != "END" || !(2.5..=4.5).contains(&gap) {
        return Err(format!("expected END 2.5-4.5 s after the last line, got {line:?} after {gap:.1} s").into());
    }
    shutdown(&s.conn, &s.endpoint, 0, b"ended").await;
    Ok(format!("{lines} lines kept the session alive, END {gap:.1} s after the last echoed line"))
}

async fn idle(args: &Args) -> Res<String> {
    let (addr, fp, tok) = need(args)?;
    let mut s = authenticate(addr, &fp, &tok).await?;
    let started = Instant::now();
    let limit = Duration::from_secs(args.wait.unwrap_or(40));
    let line = timeout(limit, read_line(&mut s.recv, &mut s.lines)).await.map_err(|_| "no END within the wait")??;
    let secs = started.elapsed().as_secs_f64();
    if line != "END" {
        return Err(format!("expected END, got {line:?}").into());
    }
    if !(29.0..=34.0).contains(&secs) {
        return Err(format!("END after {secs:.1} s (expected about 30)").into());
    }
    shutdown(&s.conn, &s.endpoint, 0, b"ended").await;
    Ok(format!("END after {secs:.1} s"))
}

async fn hold(args: &Args) -> Res<String> {
    let (addr, fp, tok) = need(args)?;
    let mut s = authenticate(addr, &fp, &tok).await?;
    let started = Instant::now();
    let limit = Duration::from_secs(args.wait.unwrap_or(15));
    let line = timeout(limit, read_line(&mut s.recv, &mut s.lines)).await.map_err(|_| "no END within the wait")??;
    if line != "END" {
        return Err(format!("expected END, got {line:?}").into());
    }
    shutdown(&s.conn, &s.endpoint, 0, b"ended").await;
    Ok(format!("END after {} ms", started.elapsed().as_millis()))
}

async fn linger(args: &Args) -> Res<String> {
    let (addr, fp, tok) = need(args)?;
    let s = authenticate(addr, &fp, &tok).await?;
    // Deliberately not reading anything: the connection stays up whatever the server does with its side.
    tokio::time::sleep(Duration::from_secs(args.wait.unwrap_or(8))).await;
    shutdown(&s.conn, &s.endpoint, 0, b"done").await;
    Ok("stayed connected".into())
}

async fn second_conn(args: &Args) -> Res<String> {
    let (addr, fp, tok) = need(args)?;
    let first = authenticate(addr, &fp, &tok).await?;
    let outcome = match timeout(Duration::from_secs(3), open(addr, &fp, &tok)).await {
        Ok(Ok((_second, reply))) if reply == "OK" => Err("the second connection with the same token got OK".into()),
        Ok(Ok((second, reply))) => {
            shutdown(&second.conn, &second.endpoint, 1, b"refused").await;
            Ok(format!("second connection answered {reply:?}"))
        }
        Ok(Err(e)) => Ok(format!("second connection failed: {e}")),
        Err(_) => Ok("second connection got no OK within 3 s".to_string()),
    };
    shutdown(&first.conn, &first.endpoint, 0, b"done").await;
    outcome
}

fn need(args: &Args) -> Res<(SocketAddr, [u8; FINGERPRINT_LEN], [u8; 32])> {
    match (args.addr, args.fp, args.tok) {
        (Some(a), Some(f), Some(t)) => Ok((a, f, t)),
        _ => Err("--addr, --fp and --tok are required".into()),
    }
}

fn main() -> ExitCode {
    let args = match parse_args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::from(2);
        }
    };
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().expect("tokio runtime");
    let started = Instant::now();
    let result = runtime.block_on(async {
        match args.scenario.as_str() {
            "happy" => happy(&args).await,
            "early-datagram" => early_datagram(&args).await,
            "wrong-tok" => wrong_tok(&args).await,
            "wrong-fp" => wrong_fp(&args).await,
            "streams" => streams(&args).await,
            "chatter" => chatter(&args).await,
            "idle" => idle(&args).await,
            "hold" => hold(&args).await,
            "linger" => linger(&args).await,
            "second-conn" => second_conn(&args).await,
            other => Err(format!("unknown scenario {other}").into()),
        }
    });
    let ms = started.elapsed().as_millis();
    match result {
        Ok(detail) => {
            println!("RESULT {} PASS {ms}ms {detail}", args.scenario);
            ExitCode::SUCCESS
        }
        Err(e) => {
            println!("RESULT {} FAIL {ms}ms {e}", args.scenario);
            ExitCode::FAILURE
        }
    }
}
