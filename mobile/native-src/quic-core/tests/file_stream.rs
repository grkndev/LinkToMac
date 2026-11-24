//! The QUIC file stream over a real quinn connection on loopback (plan stage 2.2, Faz 2): `send_file` against `receive_file`, with what
//! actually crosses the stream counted and hashed. The codec itself is pinned by `tests/vectors.rs`.

mod common;

use std::io::Cursor;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use quic_core::channel::QuicChannel;
use quic_core::file::{
    classify_incoming, encode_header, receive_file, send_file, Header, Incoming, ReceiveError, Received, Refusal, SendError, Sent, WireError,
};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt};

fn pattern(len: usize) -> Vec<u8> {
    (0..len).map(|i| ((i * 31 + 7) % 251) as u8).collect()
}

fn digest(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}

fn header_for(data: &[u8]) -> Header {
    Header { dir: None, id: "0a1b2c3d".into(), mime: "application/octet-stream".into(), mtime: 1_700_000_000, name: "test.bin".into(), size: data.len() as u64 }
}

/// What the receiving side saw: the bytes of the body, and whether the file was "moved into place".
#[derive(Default)]
struct Outcome {
    body: Mutex<Vec<u8>>,
    finalized: AtomicBool,
    finalized_at: Mutex<Option<Instant>>,
}

/// An `AsyncWrite` that keeps everything in a shared buffer.
struct Collect(Arc<Outcome>);

impl AsyncWrite for Collect {
    fn poll_write(self: Pin<&mut Self>, _: &mut Context<'_>, buf: &[u8]) -> Poll<std::io::Result<usize>> {
        self.0.body.lock().unwrap().extend_from_slice(buf);
        Poll::Ready(Ok(buf.len()))
    }
    fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }
    fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

/// An `AsyncWrite` whose disk is full.
struct Broken;

impl AsyncWrite for Broken {
    fn poll_write(self: Pin<&mut Self>, _: &mut Context<'_>, _: &[u8]) -> Poll<std::io::Result<usize>> {
        Poll::Ready(Err(std::io::Error::other("no space left")))
    }
    fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }
    fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

type SenderResult = Result<Sent, SendError>;
type ReceiverResult = Result<Received, ReceiveError>;

/// The client sends `data` with `header` over a fresh bidirectional stream; the server receives with `have` (or refuses with `refuse`).
async fn transfer(data: Vec<u8>, header: Header, have: u64, refuse: Option<WireError>, finalize_delay: Duration) -> (SenderResult, ReceiverResult, Arc<Outcome>) {
    let pair = common::loopback().await;
    let outcome = Arc::new(Outcome::default());
    let out = outcome.clone();
    let server = tokio::spawn(async move {
        let (mut send, mut recv) = pair.server.accept_bi().await.unwrap();
        let Incoming::File(seed) = classify_incoming(&mut recv, Duration::from_secs(2)).await else { panic!("not a file stream") };
        let result = receive_file(
            &mut recv,
            &mut send,
            &seed,
            |_h: &Header| match refuse {
                Some(code) => Err(code),
                None => Ok((have, Collect(out.clone()))),
            },
            |_w: Collect, _h: &Header| {
                std::thread::sleep(finalize_delay);
                out.finalized_at.lock().unwrap().replace(Instant::now());
                out.finalized.store(true, Ordering::SeqCst);
                Ok(())
            },
        )
        .await;
        (result, pair.server)
    });
    let (mut send, mut recv) = pair.client.open_bi().await.unwrap();
    let mut reader = Cursor::new(data);
    let sent = send_file(&mut send, &mut recv, &header, &mut reader).await;
    let (received, _keep_alive) = server.await.unwrap();
    (sent, received, outcome)
}

#[tokio::test]
async fn a_small_file_arrives_byte_for_byte_and_is_acknowledged_after_it_is_in_place() {
    let data = pattern(100_000);
    let (sent, received, outcome) = transfer(data.clone(), header_for(&data), 0, None, Duration::ZERO).await;
    let sent = sent.expect("the sender sees the result");
    assert_eq!((sent.have, sent.bytes_written), (0, 100_000));
    let received = received.expect("the receiver finished");
    assert_eq!((received.have, received.bytes_received), (0, 100_000));
    assert_eq!(digest(&outcome.body.lock().unwrap()), digest(&data));
    assert!(outcome.finalized.load(Ordering::SeqCst));
}

#[tokio::test]
async fn an_empty_file_is_a_header_and_a_result() {
    let (sent, received, outcome) = transfer(Vec::new(), header_for(&[]), 0, None, Duration::ZERO).await;
    assert_eq!(sent.unwrap().bytes_written, 0);
    assert_eq!(received.unwrap().bytes_received, 0);
    assert!(outcome.body.lock().unwrap().is_empty());
    assert!(outcome.finalized.load(Ordering::SeqCst));
}

#[tokio::test]
async fn a_larger_file_crosses_in_many_pieces() {
    let data = pattern(8 * 1024 * 1024 + 123);
    let (sent, received, outcome) = transfer(data.clone(), header_for(&data), 0, None, Duration::ZERO).await;
    assert_eq!(sent.unwrap().bytes_written, data.len() as u64);
    assert_eq!(received.unwrap().bytes_received, data.len() as u64);
    assert_eq!(digest(&outcome.body.lock().unwrap()), digest(&data));
}

#[tokio::test]
async fn a_have_skips_what_the_receiver_holds_and_only_the_rest_crosses() {
    let data = pattern(50_000);
    let (sent, received, outcome) = transfer(data.clone(), header_for(&data), 20_000, None, Duration::ZERO).await;
    let sent = sent.unwrap();
    assert_eq!((sent.have, sent.bytes_written), (20_000, 30_000));
    assert_eq!(received.unwrap().bytes_received, 30_000);
    assert_eq!(digest(&outcome.body.lock().unwrap()), digest(&data[20_000..]), "the receiver got exactly the tail");
    assert!(outcome.finalized.load(Ordering::SeqCst));
}

#[tokio::test]
async fn a_have_equal_to_the_size_sends_nothing_and_still_finishes() {
    let data = pattern(10_000);
    let (sent, received, outcome) = transfer(data.clone(), header_for(&data), 10_000, None, Duration::ZERO).await;
    assert_eq!(sent.unwrap().bytes_written, 0);
    assert_eq!(received.unwrap().bytes_received, 0);
    assert!(outcome.body.lock().unwrap().is_empty());
    assert!(outcome.finalized.load(Ordering::SeqCst));
}

#[tokio::test]
async fn a_refusal_reaches_the_sender_and_nothing_is_written_or_finalised() {
    let data = pattern(10_000);
    for code in [WireError::Space, WireError::Busy, WireError::TooMany] {
        let (sent, received, outcome) = transfer(data.clone(), header_for(&data), 0, Some(code), Duration::ZERO).await;
        assert_eq!(sent.unwrap_err(), SendError::Refused(Refusal::Known(code)));
        assert_eq!(received.unwrap_err(), ReceiveError::Refused(code));
        assert!(outcome.body.lock().unwrap().is_empty());
        assert!(!outcome.finalized.load(Ordering::SeqCst));
    }
}

#[tokio::test]
async fn a_bad_id_is_refused_before_the_receiver_is_even_asked() {
    let data = pattern(1_000);
    let mut header = header_for(&data);
    header.id = "NOT-AN-ID".into();
    let (sent, received, outcome) = transfer(data, header, 0, None, Duration::ZERO).await;
    assert_eq!(sent.unwrap_err(), SendError::Refused(Refusal::Known(WireError::BadId)));
    assert_eq!(received.unwrap_err(), ReceiveError::Refused(WireError::BadId));
    assert!(outcome.body.lock().unwrap().is_empty());
}

#[tokio::test]
async fn a_malformed_header_is_refused_with_bad_header() {
    let pair = common::loopback().await;
    let server = tokio::spawn(async move {
        let (mut send, mut recv) = pair.server.accept_bi().await.unwrap();
        let Incoming::File(seed) = classify_incoming(&mut recv, Duration::from_secs(2)).await else { panic!("not a file stream") };
        let r = receive_file(&mut recv, &mut send, &seed, |_: &Header| Ok((0, Collect(Arc::default()))), |_: Collect, _: &Header| Ok(())).await;
        (r, pair.server)
    });
    let (mut send, mut recv) = pair.client.open_bi().await.unwrap();
    send.write_all(&[0x01, 0x00, 0x05]).await.unwrap();
    send.write_all(b"[1,2]").await.unwrap();
    let mut answer = vec![0u8; 64];
    let n = recv.read(&mut answer).await.unwrap().unwrap_or(0);
    let (received, _keep) = server.await.unwrap();
    assert_eq!(received.unwrap_err(), ReceiveError::Refused(WireError::BadHeader));
    assert_eq!(&answer[2..n], br#"{"err":"bad-header","ok":false}"#);
}

/// A "sender" that lies about the size: header says `size`, then `actual` bytes follow.
async fn lying_sender(size: u64, actual: usize) -> (ReceiverResult, Arc<Outcome>, Vec<u8>) {
    let pair = common::loopback().await;
    let outcome = Arc::new(Outcome::default());
    let out = outcome.clone();
    let server = tokio::spawn(async move {
        let (mut send, mut recv) = pair.server.accept_bi().await.unwrap();
        let Incoming::File(seed) = classify_incoming(&mut recv, Duration::from_secs(2)).await else { panic!("not a file stream") };
        let r = receive_file(
            &mut recv,
            &mut send,
            &seed,
            |_: &Header| Ok((0, Collect(out.clone()))),
            |_: Collect, _: &Header| {
                out.finalized.store(true, Ordering::SeqCst);
                Ok(())
            },
        )
        .await;
        (r, pair.server)
    });
    let (mut send, mut recv) = pair.client.open_bi().await.unwrap();
    let mut header = header_for(&[]);
    header.size = size;
    send.write_all(&encode_header(&header)).await.unwrap();
    let mut have = vec![0u8; 64];
    let n = recv.read(&mut have).await.unwrap().unwrap_or(0);
    assert_eq!(&have[2..n], br#"{"have":0}"#);
    send.write_all(&pattern(actual)).await.unwrap();
    send.finish().unwrap();
    let mut tail = Vec::new();
    recv.read_to_end(1024).await.map(|b| tail = b).unwrap();
    let (received, _keep) = server.await.unwrap();
    (received, outcome, tail)
}

#[tokio::test]
async fn a_stream_that_ends_short_is_refused_with_size_and_the_file_is_not_finalised() {
    let (received, outcome, tail) = lying_sender(1_000, 400).await;
    assert_eq!(received.unwrap_err(), ReceiveError::Refused(WireError::Size));
    assert!(!outcome.finalized.load(Ordering::SeqCst));
    assert_eq!(&tail[2..], br#"{"err":"size","ok":false}"#);
}

#[tokio::test]
async fn a_stream_that_carries_more_than_the_size_is_refused_with_size() {
    let (received, outcome, tail) = lying_sender(1_000, 1_500).await;
    assert_eq!(received.unwrap_err(), ReceiveError::Refused(WireError::Size));
    assert!(!outcome.finalized.load(Ordering::SeqCst));
    assert_eq!(&tail[2..], br#"{"err":"size","ok":false}"#);
}

#[tokio::test]
async fn a_disk_that_cannot_be_written_is_refused_with_write() {
    let data = pattern(5_000);
    let pair = common::loopback().await;
    let finalized = Arc::new(AtomicBool::new(false));
    let f = finalized.clone();
    let server = tokio::spawn(async move {
        let (mut send, mut recv) = pair.server.accept_bi().await.unwrap();
        let Incoming::File(seed) = classify_incoming(&mut recv, Duration::from_secs(2)).await else { panic!("not a file stream") };
        let r = receive_file(&mut recv, &mut send, &seed, |_: &Header| Ok((0, Broken)), |_: Broken, _: &Header| {
            f.store(true, Ordering::SeqCst);
            Ok(())
        })
        .await;
        (r, pair.server)
    });
    let (mut send, mut recv) = pair.client.open_bi().await.unwrap();
    let sent = send_file(&mut send, &mut recv, &header_for(&data), &mut Cursor::new(data)).await;
    let (received, _keep) = server.await.unwrap();
    assert_eq!(sent.unwrap_err(), SendError::Refused(Refusal::Known(WireError::Write)));
    assert_eq!(received.unwrap_err(), ReceiveError::Refused(WireError::Write));
    assert!(!finalized.load(Ordering::SeqCst));
}

#[tokio::test]
async fn a_file_that_cannot_be_moved_into_place_is_refused_with_write() {
    let data = pattern(5_000);
    let pair = common::loopback().await;
    let server = tokio::spawn(async move {
        let (mut send, mut recv) = pair.server.accept_bi().await.unwrap();
        let Incoming::File(seed) = classify_incoming(&mut recv, Duration::from_secs(2)).await else { panic!("not a file stream") };
        let r = receive_file(&mut recv, &mut send, &seed, |_: &Header| Ok((0, Collect(Arc::default()))), |_: Collect, _: &Header| Err(WireError::Write)).await;
        (r, pair.server)
    });
    let (mut send, mut recv) = pair.client.open_bi().await.unwrap();
    let sent = send_file(&mut send, &mut recv, &header_for(&data), &mut Cursor::new(data)).await;
    let (received, _keep) = server.await.unwrap();
    assert_eq!(sent.unwrap_err(), SendError::Refused(Refusal::Known(WireError::Write)), "no delivery receipt for a file that is not in place");
    assert_eq!(received.unwrap_err(), ReceiveError::Refused(WireError::Write));
}

#[tokio::test]
async fn the_ok_comes_only_after_the_file_is_in_its_final_place() {
    let data = pattern(20_000);
    let delay = Duration::from_millis(400);
    let started = Instant::now();
    let (sent, _received, outcome) = transfer(data.clone(), header_for(&data), 0, None, delay).await;
    sent.expect("delivered");
    let done = Instant::now();
    let finalized_at = outcome.finalized_at.lock().unwrap().expect("finalised");
    assert!(finalized_at <= done, "the receipt cannot come before the file is in place");
    assert!(done.duration_since(started) >= delay, "the sender waited for the move");
}

#[tokio::test]
async fn a_sender_whose_source_is_too_short_fails_instead_of_inventing_bytes() {
    let pair = common::loopback().await;
    let server = tokio::spawn(async move {
        let (mut send, mut recv) = pair.server.accept_bi().await.unwrap();
        let Incoming::File(seed) = classify_incoming(&mut recv, Duration::from_secs(2)).await else { panic!("not a file stream") };
        let r = receive_file(&mut recv, &mut send, &seed, |_: &Header| Ok((0, Collect(Arc::default()))), |_: Collect, _: &Header| Ok(())).await;
        (r, pair.server)
    });
    let (mut send, mut recv) = pair.client.open_bi().await.unwrap();
    let mut header = header_for(&[]);
    header.size = 10_000; // says 10 000
    let sent = send_file(&mut send, &mut recv, &header, &mut Cursor::new(pattern(4_000))).await; // has 4 000
    let (received, _keep) = server.await.unwrap();
    assert_eq!(sent.unwrap_err(), SendError::SourceTooShort);
    assert!(received.is_err(), "the receiver does not call a short stream a file");
}

#[tokio::test]
async fn a_connection_that_dies_in_the_middle_is_an_error_on_both_sides_and_nothing_is_finalised() {
    let data = pattern(2 * 1024 * 1024);
    let pair = common::loopback().await;
    let outcome = Arc::new(Outcome::default());
    let out = outcome.clone();
    let client = pair.client.clone();
    let server = tokio::spawn(async move {
        let (mut send, mut recv) = pair.server.accept_bi().await.unwrap();
        let Incoming::File(seed) = classify_incoming(&mut recv, Duration::from_secs(2)).await else { panic!("not a file stream") };
        receive_file(
            &mut recv,
            &mut send,
            &seed,
            |_: &Header| Ok((0, Collect(out.clone()))),
            |_: Collect, _: &Header| {
                out.finalized.store(true, Ordering::SeqCst);
                Ok(())
            },
        )
        .await
    });
    let (mut send, mut recv) = client.open_bi().await.unwrap();
    let header = header_for(&data);
    let mut source = Cursor::new(data);
    let sending = send_file(&mut send, &mut recv, &header, &mut source);
    let kill = async {
        tokio::time::sleep(Duration::from_millis(5)).await;
        client.close(7u32.into(), b"gone");
    };
    let (sent, _) = tokio::join!(sending, kill);
    let received = server.await.unwrap();
    assert!(sent.is_err() || received.is_err(), "somebody noticed");
    assert!(received.is_err());
    assert!(!outcome.finalized.load(Ordering::SeqCst));
}

// ---- which incoming streams are files: the byte-less server-initiated stream of Network.framework (plan stage 2.2, item 7) ------------------

#[tokio::test]
async fn a_stream_that_ends_without_a_byte_is_ignored_at_once() {
    let (mut tx, mut rx) = tokio::io::duplex(64);
    tx.shutdown().await.unwrap();
    let t = Instant::now();
    assert_eq!(classify_incoming(&mut rx, Duration::from_secs(2)).await, Incoming::Ignored);
    assert!(t.elapsed() < Duration::from_millis(500));
}

#[tokio::test]
async fn a_stream_that_stays_silent_is_ignored_after_the_first_byte_time_not_before() {
    let (_tx, mut rx) = tokio::io::duplex(64); // never written, never closed
    let t = Instant::now();
    assert_eq!(classify_incoming(&mut rx, Duration::from_millis(300)).await, Incoming::Ignored);
    let took = t.elapsed();
    assert!(took >= Duration::from_millis(300) && took < Duration::from_millis(1500), "took {took:?}");
}

#[tokio::test]
async fn a_silent_stream_does_not_delay_a_real_file_stream_next_to_it() {
    let silent = tokio::spawn(async {
        let (_tx, mut rx) = tokio::io::duplex(64);
        let t = Instant::now();
        let r = classify_incoming(&mut rx, Duration::from_secs(1)).await;
        (r, t.elapsed())
    });
    let (mut tx, mut rx) = tokio::io::duplex(64);
    tx.write_all(&[0x01, 0x00]).await.unwrap();
    let t = Instant::now();
    let real = classify_incoming(&mut rx, Duration::from_secs(1)).await;
    assert!(matches!(real, Incoming::File(_)), "{real:?}");
    assert!(t.elapsed() < Duration::from_millis(300), "the real stream was served while the silent one was still waiting");
    let (silent_result, silent_took) = silent.await.unwrap();
    assert_eq!(silent_result, Incoming::Ignored);
    assert!(silent_took >= Duration::from_millis(900));
}

#[tokio::test]
async fn an_empty_server_initiated_stream_next_to_a_real_one_is_ignored_over_real_quic() {
    let data = pattern(30_000);
    let pair = common::loopback().await;
    // The server (the Mac) first starts a stream that carries nothing and closes it, then the real file stream.
    let (mut empty_send, _empty_recv) = pair.server.open_bi().await.unwrap();
    empty_send.finish().unwrap();
    let (mut real_send, mut real_recv) = pair.server.open_bi().await.unwrap();
    let header = header_for(&data);
    let payload = data.clone();
    let sender = tokio::spawn(async move {
        let r = send_file(&mut real_send, &mut real_recv, &header, &mut Cursor::new(payload)).await;
        (r, pair.server)
    });
    // The client (the phone) accepts every stream the server started and classifies each by its first byte.
    let received = Arc::new(Mutex::new(Vec::<u8>::new()));
    let ignored = Arc::new(AtomicU64::new(0));
    let mut tasks = Vec::new();
    for _ in 0..2 {
        let (mut send, mut recv) = pair.client.accept_bi().await.unwrap();
        let received = received.clone();
        let ignored = ignored.clone();
        tasks.push(tokio::spawn(async move {
            match classify_incoming(&mut recv, Duration::from_secs(2)).await {
                Incoming::File(seed) => {
                    let sink = Arc::new(Outcome::default());
                    let s2 = sink.clone();
                    let r = receive_file(&mut recv, &mut send, &seed, |_: &Header| Ok((0, Collect(s2.clone()))), |_: Collect, _: &Header| Ok(())).await;
                    received.lock().unwrap().extend_from_slice(&sink.body.lock().unwrap());
                    r.is_ok()
                }
                Incoming::Ignored => {
                    ignored.fetch_add(1, Ordering::SeqCst);
                    true
                }
                Incoming::Other(_) => false,
            }
        }));
    }
    for t in tasks {
        assert!(t.await.unwrap());
    }
    let (sent, _keep) = sender.await.unwrap();
    sent.expect("delivered");
    assert_eq!(ignored.load(Ordering::SeqCst), 1, "the empty stream was ignored");
    assert_eq!(digest(&received.lock().unwrap()), digest(&data));
}

#[tokio::test]
async fn another_channel_is_reported_as_another_channel_not_as_a_file() {
    let (mut tx, mut rx) = tokio::io::duplex(64);
    tx.write_all(&[0x02, 0xAA]).await.unwrap();
    match classify_incoming(&mut rx, Duration::from_secs(1)).await {
        Incoming::Other(prefix) => assert_eq!(prefix, vec![0x02]),
        other => panic!("{other:?}"),
    }
    let _ = QuicChannel::Screen;
}

#[allow(dead_code)]
fn _assert_traits<R: AsyncRead + Unpin, W: AsyncWrite + Unpin>() {}
