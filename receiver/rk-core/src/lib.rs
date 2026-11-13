//! Protocol v4 of Remote Keyboard as pure logic: no IO, no clock, no random source.
//!
//! The specification is `docs/protocol/v4.md`; every public item names the section it implements. Randomness (nonces,
//! private scalars, grants) and time (microseconds as `u64`) are always supplied by the caller.

#![forbid(unsafe_code)]

pub mod binding;
pub mod channel;
pub mod dedup;
pub mod frame;
pub mod handshake;
pub mod identity;
pub mod json;
pub mod message;
pub mod pairing;
pub mod pointer;
pub mod secret;
pub mod select_uuid;
pub mod session;

#[cfg(test)]
mod rust_vectors;
