//! Fragmenting messages into notifications and putting them back together (protocol v4 §2).

use thiserror::Error;

/// Bytes of header before the data of a frame (§2.1).
pub const HEADER_BYTES: usize = 5;
/// Longest message in bytes (§2.2).
pub const MAX_MESSAGE_BYTES: usize = 16_384;
/// Most frames one message may use (§2.2).
pub const MAX_FRAME_COUNT: usize = 255;

/// Why a frame or a message was refused (§2.2, §2.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum FrameError {
    #[error("frame size leaves no room for data, or a received frame is shorter than its header")]
    FrameTooSmall,
    #[error("message of {0} bytes does not fit")]
    PayloadTooLarge(usize),
    #[error("bad version, zero count, or a frame that continues nothing")]
    BadHeader,
    #[error("index is not below count")]
    BadIndex,
    #[error("count changed inside one message")]
    CountMismatch,
    #[error("index already received")]
    DuplicateIndex,
    #[error("message grew past the limit")]
    MessageTooLarge,
}

const FRAME_VERSION: u8 = 0x02;

/// Splits one encoded message into notifications of at most `max_frame` bytes (§2.2). `max_frame` is the central's
/// notification limit, header included.
pub fn split_frames(payload: &[u8], message_id: u16, max_frame: usize) -> Result<Vec<Vec<u8>>, FrameError> {
    if max_frame <= HEADER_BYTES {
        return Err(FrameError::FrameTooSmall);
    }
    if payload.len() > MAX_MESSAGE_BYTES {
        return Err(FrameError::PayloadTooLarge(payload.len()));
    }
    let slice = max_frame - HEADER_BYTES;
    let count = payload.len().div_ceil(slice).max(1);
    if count > MAX_FRAME_COUNT {
        return Err(FrameError::PayloadTooLarge(payload.len()));
    }
    let id = message_id.to_be_bytes();
    Ok((0..count)
        .map(|index| {
            let start = index * slice;
            let end = (start + slice).min(payload.len());
            let mut frame = Vec::with_capacity(HEADER_BYTES + end - start);
            // `count` is at most 255, so both casts are exact.
            frame.extend_from_slice(&[FRAME_VERSION, id[0], id[1], index as u8, count as u8]);
            frame.extend_from_slice(&payload[start..end]);
            frame
        })
        .collect())
}

/// What a frame did to the message in progress (§2.3).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Reassembly {
    Incomplete,
    Complete(Vec<u8>),
    Rejected(FrameError),
}

#[derive(Debug)]
struct Partial {
    message_id: u16,
    slices: Vec<Option<Vec<u8>>>,
    received: usize,
    bytes: usize,
}

impl Partial {
    fn start(message_id: u16, count: usize, slice: &[u8]) -> Self {
        let mut slices = vec![None; count];
        slices[0] = Some(slice.to_vec());
        Self { message_id, slices, received: 1, bytes: slice.len() }
    }
}

/// One per connection; holds one unfinished message and must be reset when the connection ends (§2.3).
#[derive(Debug, Default)]
pub struct FrameReassembler {
    partial: Option<Partial>,
    dropped_partial_messages: u64,
}

impl FrameReassembler {
    /// An empty reassembler.
    pub fn new() -> Self {
        Self::default()
    }

    /// Forgets the unfinished message.
    pub fn reset(&mut self) {
        self.partial = None;
    }

    /// Unfinished messages thrown away because the first frame of another message arrived.
    pub fn dropped_partial_messages(&self) -> u64 {
        self.dropped_partial_messages
    }

    /// Feeds one `0x02` notification. A rejected frame leaves the unfinished message alone (§2.3), except that an
    /// oversize message is dropped; nothing incomplete is ever handed out.
    pub fn accept(&mut self, frame: &[u8]) -> Reassembly {
        if frame.len() < HEADER_BYTES {
            return Reassembly::Rejected(FrameError::FrameTooSmall);
        }
        if frame[0] != FRAME_VERSION || frame[4] == 0 {
            return Reassembly::Rejected(FrameError::BadHeader);
        }
        let message_id = u16::from_be_bytes([frame[1], frame[2]]);
        let index = usize::from(frame[3]);
        let count = usize::from(frame[4]);
        if index >= count {
            return Reassembly::Rejected(FrameError::BadIndex);
        }
        let slice = &frame[HEADER_BYTES..];

        let Some(current) = self.partial.as_mut() else {
            if index != 0 {
                return Reassembly::Rejected(FrameError::BadHeader);
            }
            return self.start(message_id, count, slice);
        };
        if current.message_id != message_id {
            // Only a first frame can start a message; an unrelated later frame leaves the one in progress alone.
            if index != 0 {
                return Reassembly::Rejected(FrameError::BadHeader);
            }
            self.partial = None;
            self.dropped_partial_messages += 1;
            return self.start(message_id, count, slice);
        }
        if current.slices.len() != count {
            return Reassembly::Rejected(FrameError::CountMismatch);
        }
        if current.slices[index].is_some() {
            return Reassembly::Rejected(FrameError::DuplicateIndex);
        }
        current.bytes += slice.len();
        if current.bytes > MAX_MESSAGE_BYTES {
            self.partial = None;
            return Reassembly::Rejected(FrameError::MessageTooLarge);
        }
        current.slices[index] = Some(slice.to_vec());
        current.received += 1;
        self.finish()
    }

    fn start(&mut self, message_id: u16, count: usize, slice: &[u8]) -> Reassembly {
        if slice.len() > MAX_MESSAGE_BYTES {
            return Reassembly::Rejected(FrameError::MessageTooLarge);
        }
        self.partial = Some(Partial::start(message_id, count, slice));
        self.finish()
    }

    fn finish(&mut self) -> Reassembly {
        match self.partial.take() {
            Some(partial) if partial.received == partial.slices.len() => {
                let mut message = Vec::with_capacity(partial.bytes);
                for slice in partial.slices.into_iter().flatten() {
                    message.extend_from_slice(&slice);
                }
                Reassembly::Complete(message)
            }
            unfinished => {
                self.partial = unfinished;
                Reassembly::Incomplete
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(id: u16, index: u8, count: u8, data: &[u8]) -> Vec<u8> {
        let mut f = vec![FRAME_VERSION, (id >> 8) as u8, id as u8, index, count];
        f.extend_from_slice(data);
        f
    }

    fn pattern(len: usize) -> Vec<u8> {
        (0..len).map(|i| (i % 251) as u8).collect()
    }

    #[test]
    fn a_600_byte_message_at_185_makes_four_frames() {
        let message = pattern(600);
        let frames = split_frames(&message, 0x0102, 185).unwrap();
        assert_eq!(frames.len(), 4);
        for (i, f) in frames.iter().enumerate() {
            assert_eq!(f[..5], [0x02, 0x01, 0x02, i as u8, 4]);
        }
        assert_eq!(frames.iter().map(|f| f.len() - 5).collect::<Vec<_>>(), [180, 180, 180, 60]);
        assert_eq!(frames.concat().len(), 600 + 4 * 5);
    }

    #[test]
    fn an_empty_message_is_one_header_only_frame() {
        let frames = split_frames(&[], 9, 185).unwrap();
        assert_eq!(frames, vec![vec![0x02, 0, 9, 0, 1]]);
    }

    #[test]
    fn split_refuses_what_cannot_be_sent() {
        assert_eq!(split_frames(&[1], 0, 5), Err(FrameError::FrameTooSmall));
        assert_eq!(split_frames(&[1], 0, 0), Err(FrameError::FrameTooSmall));
        assert_eq!(split_frames(&pattern(16_385), 0, 185), Err(FrameError::PayloadTooLarge(16_385)));
        // 16 384 bytes at F = 23 would need 912 frames.
        assert_eq!(split_frames(&pattern(16_384), 0, 23), Err(FrameError::PayloadTooLarge(16_384)));
        // 255 frames is the most: 255 * 18 bytes fits, one byte more does not.
        assert_eq!(split_frames(&pattern(255 * 18), 0, 23).unwrap().len(), 255);
        assert_eq!(split_frames(&pattern(255 * 18 + 1), 0, 23), Err(FrameError::PayloadTooLarge(255 * 18 + 1)));
        assert_eq!(split_frames(&pattern(16_384), 0, 185).unwrap().len(), 92);
    }

    #[test]
    fn frames_round_trip_for_many_sizes_and_limits() {
        for max_frame in [6, 23, 100, 185, 512] {
            for len in [0, 1, 17, 18, 19, 180, 181, 600, 1000] {
                if len > 255 * (max_frame - 5) {
                    continue;
                }
                let message = pattern(len);
                let frames = split_frames(&message, 65_535, max_frame).unwrap();
                assert!(frames.iter().all(|f| f.len() <= max_frame));
                let mut r = FrameReassembler::new();
                let mut done = None;
                for f in &frames {
                    match r.accept(f) {
                        Reassembly::Incomplete => {}
                        Reassembly::Complete(m) => done = Some(m),
                        Reassembly::Rejected(e) => panic!("{e} at F={max_frame} len={len}"),
                    }
                }
                assert_eq!(done, Some(message), "F={max_frame} len={len}");
            }
        }
    }

    #[test]
    fn a_frame_shorter_than_its_header_is_rejected() {
        let mut r = FrameReassembler::new();
        assert_eq!(r.accept(&[]), Reassembly::Rejected(FrameError::FrameTooSmall));
        assert_eq!(r.accept(&[0x02, 0, 1, 0]), Reassembly::Rejected(FrameError::FrameTooSmall));
    }

    #[test]
    fn a_wrong_version_or_a_zero_count_is_rejected() {
        let mut r = FrameReassembler::new();
        assert_eq!(r.accept(&[0x03, 0, 1, 0, 1, 9]), Reassembly::Rejected(FrameError::BadHeader));
        assert_eq!(r.accept(&[0x01, 0, 1, 0, 1, 9]), Reassembly::Rejected(FrameError::BadHeader));
        assert_eq!(r.accept(&frame(1, 0, 0, b"x")), Reassembly::Rejected(FrameError::BadHeader));
    }

    #[test]
    fn an_index_not_below_count_is_rejected() {
        let mut r = FrameReassembler::new();
        assert_eq!(r.accept(&frame(1, 2, 2, b"x")), Reassembly::Rejected(FrameError::BadIndex));
        assert_eq!(r.accept(&frame(1, 255, 255, b"x")), Reassembly::Rejected(FrameError::BadIndex));
    }

    #[test]
    fn with_nothing_in_progress_only_index_zero_starts_a_message() {
        let mut r = FrameReassembler::new();
        assert_eq!(r.accept(&frame(1, 1, 2, b"x")), Reassembly::Rejected(FrameError::BadHeader));
        assert_eq!(r.accept(&frame(1, 0, 2, b"a")), Reassembly::Incomplete);
        assert_eq!(r.accept(&frame(1, 1, 2, b"b")), Reassembly::Complete(b"ab".to_vec()));
    }

    #[test]
    fn a_later_frame_of_another_message_is_rejected_and_the_unfinished_message_survives() {
        let mut r = FrameReassembler::new();
        assert_eq!(r.accept(&frame(1, 0, 3, b"a")), Reassembly::Incomplete);
        assert_eq!(r.accept(&frame(2, 1, 3, b"zzz")), Reassembly::Rejected(FrameError::BadHeader));
        assert_eq!(r.accept(&frame(1, 1, 3, b"b")), Reassembly::Incomplete);
        assert_eq!(r.accept(&frame(1, 2, 3, b"c")), Reassembly::Complete(b"abc".to_vec()));
        assert_eq!(r.dropped_partial_messages(), 0);
    }

    #[test]
    fn the_first_frame_of_a_new_message_replaces_the_unfinished_one() {
        let mut r = FrameReassembler::new();
        assert_eq!(r.accept(&frame(1, 0, 3, b"a")), Reassembly::Incomplete);
        assert_eq!(r.accept(&frame(2, 0, 2, b"x")), Reassembly::Incomplete);
        assert_eq!(r.dropped_partial_messages(), 1);
        // The old message is gone: its next frame is a stray one now.
        assert_eq!(r.accept(&frame(1, 1, 3, b"b")), Reassembly::Rejected(FrameError::BadHeader));
        assert_eq!(r.accept(&frame(2, 1, 2, b"y")), Reassembly::Complete(b"xy".to_vec()));
    }

    #[test]
    fn a_new_single_frame_message_completes_at_once_and_drops_the_old_one() {
        let mut r = FrameReassembler::new();
        assert_eq!(r.accept(&frame(1, 0, 3, b"a")), Reassembly::Incomplete);
        assert_eq!(r.accept(&frame(2, 0, 1, b"solo")), Reassembly::Complete(b"solo".to_vec()));
        assert_eq!(r.dropped_partial_messages(), 1);
    }

    #[test]
    fn the_same_id_with_another_count_is_rejected() {
        let mut r = FrameReassembler::new();
        assert_eq!(r.accept(&frame(1, 0, 3, b"a")), Reassembly::Incomplete);
        assert_eq!(r.accept(&frame(1, 1, 4, b"b")), Reassembly::Rejected(FrameError::CountMismatch));
        assert_eq!(r.accept(&frame(1, 0, 2, b"b")), Reassembly::Rejected(FrameError::CountMismatch));
        assert_eq!(r.accept(&frame(1, 1, 3, b"b")), Reassembly::Incomplete, "the message in progress is untouched");
    }

    #[test]
    fn a_repeated_index_is_rejected_and_not_counted_twice() {
        let mut r = FrameReassembler::new();
        assert_eq!(r.accept(&frame(1, 0, 2, b"a")), Reassembly::Incomplete);
        assert_eq!(r.accept(&frame(1, 0, 2, b"a")), Reassembly::Rejected(FrameError::DuplicateIndex));
        assert_eq!(r.accept(&frame(1, 1, 2, b"b")), Reassembly::Complete(b"ab".to_vec()));
    }

    #[test]
    fn frames_may_arrive_out_of_index_order_but_join_in_index_order() {
        let mut r = FrameReassembler::new();
        assert_eq!(r.accept(&frame(1, 0, 3, b"a")), Reassembly::Incomplete);
        assert_eq!(r.accept(&frame(1, 2, 3, b"c")), Reassembly::Incomplete);
        assert_eq!(r.accept(&frame(1, 1, 3, b"b")), Reassembly::Complete(b"abc".to_vec()));
    }

    #[test]
    fn a_message_past_16384_bytes_is_dropped_whole() {
        let mut r = FrameReassembler::new();
        assert_eq!(r.accept(&frame(1, 0, 3, &pattern(10_000))), Reassembly::Incomplete);
        assert_eq!(r.accept(&frame(1, 1, 3, &pattern(6_385))), Reassembly::Rejected(FrameError::MessageTooLarge));
        // Dropped: the last frame has nothing to join and is itself a stray frame.
        assert_eq!(r.accept(&frame(1, 2, 3, b"x")), Reassembly::Rejected(FrameError::BadHeader));
        // Exactly 16 384 is allowed.
        assert_eq!(r.accept(&frame(2, 0, 2, &pattern(10_000))), Reassembly::Incomplete);
        let Reassembly::Complete(m) = r.accept(&frame(2, 1, 2, &pattern(6_384))) else { panic!("complete expected") };
        assert_eq!(m.len(), 16_384);
    }

    #[test]
    fn a_first_frame_alone_over_the_limit_is_rejected() {
        let mut r = FrameReassembler::new();
        assert_eq!(r.accept(&frame(1, 0, 2, &pattern(16_385))), Reassembly::Rejected(FrameError::MessageTooLarge));
    }

    #[test]
    fn reset_forgets_the_unfinished_message() {
        let mut r = FrameReassembler::new();
        assert_eq!(r.accept(&frame(1, 0, 2, b"a")), Reassembly::Incomplete);
        r.reset();
        assert_eq!(r.accept(&frame(1, 1, 2, b"b")), Reassembly::Rejected(FrameError::BadHeader));
    }
}
