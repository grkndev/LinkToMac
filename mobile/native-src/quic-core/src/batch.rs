//! Batched reading of file streams (plan item 7, stage 0.6 finding 20). quinn hands a stream out in ~1.4 kB parts, one per packet; moving
//! each part to the writer costs a thread switch (about 1 ms on the phone), which capped a transfer near 1 MB/s. So file streams are
//! collected into pieces of at least [`FILE_BATCH_BYTES`] and handed over at once; the end of the stream releases what is left.
//! Media streams (screen, camera) are NOT batched: a late frame is worse than a slow writer.

use crate::channel::QuicChannel;

/// A file stream is handed over once this much has been collected.
pub const FILE_BATCH_BYTES: usize = 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StreamMode {
    /// Collect parts until this many bytes, then deliver them together (and the rest at the end of the stream).
    Batched(usize),
    /// Deliver each part as it arrives.
    Immediate,
}

impl StreamMode {
    pub fn for_channel(channel: QuicChannel) -> Self {
        match channel {
            QuicChannel::File => Self::Batched(FILE_BATCH_BYTES),
            QuicChannel::Screen | QuicChannel::Camera => Self::Immediate,
        }
    }
}

#[derive(Debug)]
pub struct ChunkBatcher {
    threshold: usize,
    buf: Vec<u8>,
}

impl ChunkBatcher {
    pub fn new(threshold: usize) -> Self {
        Self { threshold, buf: Vec::new() }
    }

    pub fn pending_bytes(&self) -> usize {
        self.buf.len()
    }

    /// Adds a part; once the collected bytes reach the threshold they are all returned, in order, in one piece.
    pub fn push(&mut self, part: Vec<u8>) -> Option<Vec<u8>> {
        if self.buf.is_empty() && part.len() >= self.threshold {
            return Some(part); // a big part needs no copy
        }
        self.buf.extend_from_slice(&part);
        if self.buf.len() >= self.threshold {
            Some(std::mem::take(&mut self.buf))
        } else {
            None
        }
    }

    pub fn push_slice(&mut self, part: &[u8]) -> Option<Vec<u8>> {
        self.push(part.to_vec())
    }

    /// The end of the stream: whatever is left, once.
    pub fn finish(&mut self) -> Option<Vec<u8>> {
        if self.buf.is_empty() {
            None
        } else {
            Some(std::mem::take(&mut self.buf))
        }
    }
}
