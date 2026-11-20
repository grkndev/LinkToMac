//! The PRODUCTION phone client (`quic_core::client::Client`, the code the JNI layer wraps) driven from the command line, so it can be
//! tested against the real Mac listener without a phone (stage 1.7). `echo_client` speaks raw quinn to probe the Mac's protocol; this
//! speaks it through the library, which is what actually ships.
//!
//!   session_client --addr 127.0.0.1:53125 --fp <64 hex> --tok <43 chars base64url> --scenario <name> [--count N] [--wait SECS]
//!
//! Scenarios (one `RESULT <name> PASS|FAIL <ms>ms <detail>` line each; exit 0 only on PASS):
//!   happy      correct fp + tok: Connected, a session line echoed, a datagram echoed, a screen uni stream counted by the server
//!   wrong-fp   fingerprint flipped: Failed(FpMismatch)
//!   wrong-tok  last token byte flipped: Failed(TokenRejected) within 1.5 s
//!   streams    --count N short uni streams, all counted by the server (`COUNT N`)
//!   end        connected, then waits up to --wait SECS (default 15) for the server's END (PeerEnded)

use std::process::ExitCode;
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use quic_core::channel::QuicChannel;
use quic_core::client::{Client, Event, EventSink, Timeouts};
use quic_core::error::ErrorCode;
use quic_core::params::{decode_token, encode_token, ConnectParams};
use quic_core::pin::parse_fingerprint_hex;

struct Collector(Mutex<mpsc::Sender<Event>>);

impl EventSink for Collector {
    fn event(&self, event: Event) {
        let _ = self.0.lock().map(|tx| tx.send(event));
    }
}

struct Args {
    addr: String,
    fp: String,
    tok: String,
    scenario: String,
    count: u32,
    wait: u64,
}

fn parse_args() -> Result<Args, String> {
    let mut args = Args { addr: String::new(), fp: String::new(), tok: String::new(), scenario: "happy".into(), count: 100, wait: 15 };
    let mut it = std::env::args().skip(1);
    while let Some(flag) = it.next() {
        let value = it.next().ok_or(format!("{flag} needs a value"))?;
        match flag.as_str() {
            "--addr" => args.addr = value,
            "--fp" => args.fp = value,
            "--tok" => args.tok = value,
            "--scenario" => args.scenario = value,
            "--count" => args.count = value.parse().map_err(|e| format!("--count: {e}"))?,
            "--wait" => args.wait = value.parse().map_err(|e| format!("--wait: {e}"))?,
            other => return Err(format!("unknown flag {other}")),
        }
    }
    Ok(args)
}

fn start(args: &Args, fp: &str, tok: &str) -> Result<(Client, Receiver<Event>), String> {
    let (host, port) = args.addr.rsplit_once(':').ok_or("--addr must be host:port")?;
    let port: u16 = port.parse().map_err(|_| "bad port".to_string())?;
    let params = ConnectParams::parse(host, port, fp, tok).map_err(|e| e.to_string())?;
    let (tx, rx) = mpsc::channel();
    Ok((Client::connect(params, Arc::new(Collector(Mutex::new(tx))), Timeouts::default()), rx))
}

fn wait_for(rx: &Receiver<Event>, within: Duration, mut pred: impl FnMut(&Event) -> bool) -> Result<Event, String> {
    let deadline = Instant::now() + within;
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        match rx.recv_timeout(left) {
            Ok(event) if pred(&event) => return Ok(event),
            Ok(_) => {}
            Err(_) => return Err("timed out waiting for an event".into()),
        }
    }
}

fn connected(args: &Args) -> Result<(Client, Receiver<Event>), String> {
    let (client, rx) = start(args, &args.fp, &args.tok)?;
    match wait_for(&rx, Duration::from_secs(10), |e| matches!(e, Event::Connected | Event::Failed(_)))? {
        Event::Connected => Ok((client, rx)),
        Event::Failed(code) => Err(format!("failed: {code}")),
        _ => unreachable!(),
    }
}

fn counted(client: &Client, rx: &Receiver<Event>, want: u32) -> Result<(), String> {
    let line = format!("COUNT {want}");
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        client.session_write("COUNT");
        if wait_for(rx, Duration::from_millis(300), |e| *e == Event::SessionLine(line.clone())).is_ok() {
            return Ok(());
        }
    }
    Err(format!("the server never reported {want} streams"))
}

fn happy(args: &Args) -> Result<String, String> {
    let (client, rx) = connected(args)?;
    client.session_write("hello");
    wait_for(&rx, Duration::from_secs(5), |e| *e == Event::SessionLine("hello".into()))?;
    let datagram: Vec<u8> = (0..300u32).map(|i| (i * 7 % 251) as u8).collect();
    client.send_datagram(&datagram);
    wait_for(&rx, Duration::from_secs(5), |e| *e == Event::Datagram(datagram.clone())).map_err(|_| "datagram echo")?;
    let id = client.open_uni(QuicChannel::Screen).map_err(|e| format!("open_uni: {e}"))?;
    client.stream_write(id, b"frame");
    client.stream_finish(id);
    counted(&client, &rx, 1)?;
    client.close(0);
    Ok("Connected, line + datagram echoed, 1 uni stream counted".into())
}

fn streams(args: &Args) -> Result<String, String> {
    let (client, rx) = connected(args)?;
    for i in 0..args.count {
        let id = client.open_uni(QuicChannel::Screen).map_err(|e| format!("open_uni #{i}: {e}"))?;
        client.stream_write(id, &[1, 2, 3, 4]);
        client.stream_finish(id);
    }
    counted(&client, &rx, args.count)?;
    client.close(0);
    Ok(format!("{} uni streams opened and counted", args.count))
}

fn wrong_fp(args: &Args) -> Result<String, String> {
    let mut fp = parse_fingerprint_hex(&args.fp).map_err(|e| e.to_string())?;
    fp[0] ^= 1;
    let flipped: String = fp.iter().map(|b| format!("{b:02x}")).collect();
    let (_client, rx) = start(args, &flipped, &args.tok)?;
    match wait_for(&rx, Duration::from_secs(10), |e| matches!(e, Event::Connected | Event::Failed(_)))? {
        Event::Failed(ErrorCode::FpMismatch) => Ok("Failed(FpMismatch)".into()),
        other => Err(format!("expected Failed(FpMismatch), got {other:?}")),
    }
}

fn wrong_tok(args: &Args) -> Result<String, String> {
    let mut tok = decode_token(&args.tok).map_err(|e| e.to_string())?;
    tok[31] ^= 1;
    let started = Instant::now();
    let (_client, rx) = start(args, &args.fp, &encode_token(&tok))?;
    match wait_for(&rx, Duration::from_secs(10), |e| matches!(e, Event::Connected | Event::Failed(_)))? {
        Event::Failed(ErrorCode::TokenRejected) if started.elapsed() < Duration::from_millis(1500) => {
            Ok(format!("Failed(TokenRejected) after {} ms", started.elapsed().as_millis()))
        }
        other => Err(format!("expected Failed(TokenRejected) within 1.5 s, got {other:?} after {} ms", started.elapsed().as_millis())),
    }
}

fn end(args: &Args) -> Result<String, String> {
    let (_client, rx) = connected(args)?;
    let started = Instant::now();
    wait_for(&rx, Duration::from_secs(args.wait), |e| *e == Event::PeerEnded)?;
    Ok(format!("PeerEnded after {} ms", started.elapsed().as_millis()))
}

fn main() -> ExitCode {
    let args = match parse_args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::from(2);
        }
    };
    let started = Instant::now();
    let result = match args.scenario.as_str() {
        "happy" => happy(&args),
        "wrong-fp" => wrong_fp(&args),
        "wrong-tok" => wrong_tok(&args),
        "streams" => streams(&args),
        "end" => end(&args),
        other => Err(format!("unknown scenario {other}")),
    };
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
