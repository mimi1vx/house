#![allow(
    clippy::module_inception,
    reason = "threads module mirrors C threads.h layout"
)]
pub mod switch;
pub mod threads;
pub mod tls;
