#![cfg_attr(not(windows), forbid(unsafe_code))]

//! The Remote Keyboard receiver for Windows and Linux.
//!
//! Everything platform independent lives here and is tested on every host; `platform` holds the shells.

pub mod app;
pub mod cli;
pub mod clock;
pub mod config;
pub mod diag;
pub mod i18n;
pub mod icons;
pub mod inject_log;
pub mod log;
pub mod platform;
pub mod random;
pub mod runner;
pub mod store;
pub mod ui;
