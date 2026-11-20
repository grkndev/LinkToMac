//! The file-stream batcher (stage 1.7, plan item 7 / stage 0.6 finding 20): quinn hands out ~1.4 kB parts, and handing each one to the
//! writer costs a thread switch. The batcher collects parts and releases them in big pieces — bytes complete and in order.

use quic_core::batch::{ChunkBatcher, StreamMode, FILE_BATCH_BYTES};
use quic_core::channel::QuicChannel;

fn part(len: usize, seed: u8) -> Vec<u8> {
    (0..len).map(|i| seed.wrapping_add(i as u8)).collect()
}

#[test]
fn the_threshold_is_one_mebibyte() {
    assert_eq!(FILE_BATCH_BYTES, 1024 * 1024);
}

#[test]
fn parts_below_the_threshold_are_held() {
    let mut b = ChunkBatcher::new(10);
    assert_eq!(b.push(vec![1, 2, 3]), None);
    assert_eq!(b.push(vec![4, 5, 6]), None);
    assert_eq!(b.pending_bytes(), 6);
}

#[test]
fn reaching_the_threshold_releases_everything_in_order() {
    let mut b = ChunkBatcher::new(10);
    assert_eq!(b.push(vec![1, 2, 3, 4, 5, 6]), None);
    assert_eq!(b.push(vec![7, 8, 9, 10]), Some(vec![1, 2, 3, 4, 5, 6, 7, 8, 9, 10]));
    assert_eq!(b.pending_bytes(), 0);
}

#[test]
fn the_boundary_is_exact() {
    let mut below = ChunkBatcher::new(10);
    assert_eq!(below.push(part(9, 0)), None);
    let mut at = ChunkBatcher::new(10);
    assert_eq!(at.push(part(10, 0)).map(|v| v.len()), Some(10));
}

#[test]
fn one_part_larger_than_the_threshold_goes_out_whole() {
    let mut b = ChunkBatcher::new(10);
    assert_eq!(b.push(part(25, 3)), Some(part(25, 3)));
    assert_eq!(b.pending_bytes(), 0);
}

#[test]
fn the_end_of_the_stream_releases_the_rest_and_only_the_rest() {
    let mut b = ChunkBatcher::new(100);
    assert_eq!(b.push(vec![1, 2, 3]), None);
    assert_eq!(b.finish(), Some(vec![1, 2, 3]));
    assert_eq!(b.finish(), None); // nothing is released twice
}

#[test]
fn an_empty_batcher_releases_nothing_at_the_end() {
    assert_eq!(ChunkBatcher::new(100).finish(), None);
}

#[test]
fn empty_parts_never_produce_an_empty_batch() {
    let mut b = ChunkBatcher::new(4);
    assert_eq!(b.push(Vec::new()), None);
    assert_eq!(b.push(vec![1, 2]), None);
    assert_eq!(b.push(Vec::new()), None);
    assert_eq!(b.finish(), Some(vec![1, 2]));
}

#[test]
fn a_long_stream_arrives_complete_in_order_and_in_big_pieces() {
    // 5000 parts of 1400 bytes = ~7 MB through the real threshold: every byte once, in sequence, in few deliveries.
    let mut b = ChunkBatcher::new(FILE_BATCH_BYTES);
    let mut sent = Vec::new();
    let mut got = Vec::new();
    let mut deliveries = 0;
    for i in 0..5000usize {
        let p = part(1400, (i % 251) as u8);
        sent.extend_from_slice(&p);
        if let Some(out) = b.push(p) {
            assert!(out.len() >= FILE_BATCH_BYTES);
            deliveries += 1;
            got.extend_from_slice(&out);
        }
    }
    if let Some(rest) = b.finish() {
        deliveries += 1;
        got.extend_from_slice(&rest);
    }
    assert_eq!(got.len(), sent.len());
    assert!(got == sent, "bytes differ or are out of order");
    assert!(deliveries <= 8, "{deliveries} deliveries for ~7 MB: the batching is not working");
}

#[test]
fn the_file_channel_batches_and_the_media_channels_do_not() {
    assert_eq!(StreamMode::for_channel(QuicChannel::File), StreamMode::Batched(FILE_BATCH_BYTES));
    assert_eq!(StreamMode::for_channel(QuicChannel::Screen), StreamMode::Immediate);
    assert_eq!(StreamMode::for_channel(QuicChannel::Camera), StreamMode::Immediate);
}
