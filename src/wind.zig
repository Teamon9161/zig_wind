//! Zig bindings for the Wind Quant API.
//!
//! The public surface is identical on both platforms; only the transport differs:
//!   * Windows — the `WindDataCOM` Automation server registered by the terminal.
//!   * Linux   — the C API shared objects the terminal installs under `com.wind.api`.
//!
//! A handful of requests exist in only one transport. Those return
//! `error.UnsupportedOnThisPlatform` rather than being absent, so calling code
//! stays portable; see the README for the list.

const std = @import("std");
const builtin = @import("builtin");

const types = @import("wind_types.zig");

const backend = switch (builtin.os.tag) {
    .windows => @import("wind_windows.zig"),
    .linux => @import("wind_linux.zig"),
    else => @compileError("zig-wind supports Windows and Linux; the Wind terminal ships no API for this target"),
};

pub const Error = types.Error;
pub const Value = types.Value;
pub const Data = types.Data;
pub const TradingDayOffset = types.TradingDayOffset;
pub const TradingDayCount = types.TradingDayCount;
pub const SubscriptionEvent = types.SubscriptionEvent;

pub const Wind = backend.Wind;
pub const Subscription = backend.Subscription;
pub const SubscriptionStart = backend.SubscriptionStart;

test {
    _ = types;
    _ = backend;
}
