//! Linux backend: loads the Wind terminal's C API shared objects at run time.
//!
//! There is no COM on Linux. The Wind terminal ships `com.wind.api`, whose
//! `libWind.QuantData.so` exports a plain C ABI — the same one WindPy drives through
//! ctypes. This backend binds those exports directly, so it needs no C or C++ shim.
//!
//! Two libraries are involved:
//!   * `libWind.QuantData.so`        — session control plus most data requests.
//!   * `libWind.Cosmos.QuantData.so` — `wsi` and `wst` live here and are freed here.
//!
//! Loading happens at run time, so a binary built from this package links against
//! nothing from Wind and runs on any machine where the terminal is installed.

const std = @import("std");

const types = @import("wind_types.zig");

pub const Error = types.Error;
pub const Value = types.Value;
pub const Data = types.Data;
pub const TradingDayOffset = types.TradingDayOffset;
pub const TradingDayCount = types.TradingDayCount;
pub const SubscriptionEvent = types.SubscriptionEvent;

const freeStrings = types.freeStrings;

/// Scratch space for the null-terminated copies the C API expects.
const scratch = std.heap.page_allocator;

/// Wind installs to a fixed location on Linux; `WIND_API_LIB_DIR` overrides it.
pub const default_lib_dir = "/opt/apps/com.wind.wft/files/com.wind.api/lib";
pub const lib_dir_env = "WIND_API_LIB_DIR";

const main_lib_name = "libWind.QuantData.so";
const quant_lib_name = "libWind.Cosmos.QuantData.so";

/// Product code identifying the caller to Wind's authorization check. This is the
/// value WindPy passes; the packaged C++ wrapper passes 94630 instead, which is a
/// separately entitled interface. Stick with the proven one unless an account is
/// licensed for the other.
pub const product_type: i32 = 94645;

/// `setLongValue` key that selects the product code. Without this call `start`
/// blocks forever instead of returning an error.
const set_long_product_key: i32 = 6433;

// Wind's own variant tags. These are not the Windows VARTYPE values.
const vt = struct {
    const EMPTY: u16 = 0;
    const NULL: u16 = 1;
    const I8: u16 = 2;
    const I4: u16 = 3;
    const I2: u16 = 4;
    const I1: u16 = 5;
    const R4: u16 = 6;
    const R8: u16 = 7;
    const DATE: u16 = 8;
    const VARIANT: u16 = 9;
    const CSTR: u16 = 10;
    const BSTR: u16 = 11;
    const BOOL: u16 = 12;
    const ARRAY: u16 = 0x100;
    const TYPEMASK: u16 = 0x00ff;
};

/// Wind hands out these buffers, so nothing here may assume natural alignment;
/// every pointer into them is read as `align(1)`.
const SafeArray = extern struct {
    cDims: u16,
    fFeatures: u16,
    cbElements: u32,
    cLocks: u32,
    pvData: ?*align(1) anyopaque,
    rgsabound: ?[*]align(1) u32,
};

const Variant = extern struct {
    vt: u16,
    val: extern union {
        llVal: i64,
        lVal: i32,
        iVal: i16,
        bVal: i8,
        fltVal: f32,
        dblVal: f64,
        date: f64,
        cstrVal: ?[*:0]align(1) u8,
        parray: ?*align(1) SafeArray,
    },

    fn baseType(self: *const Variant) u16 {
        return self.vt & vt.TYPEMASK;
    }

    fn isArray(self: *const Variant) bool {
        return (self.vt & vt.ARRAY) != 0;
    }

    /// Total element count across every dimension. Wind flattens multi-dimensional
    /// results in row-major order with the last dimension varying fastest.
    fn arrayLen(self: *const Variant) usize {
        if (!self.isArray()) return 0;
        const array = self.val.parray orelse return 0;
        const bounds = array.rgsabound orelse return 0;
        var total: usize = 1;
        var dimension: usize = 0;
        while (dimension < array.cDims) : (dimension += 1) total *= bounds[dimension];
        return total;
    }
};

const ApiOut = extern struct {
    ErrorCode: i32,
    StateCode: i32,
    RequestID: i64,
    Codes: Variant,
    Fields: Variant,
    Times: Variant,
    Data: Variant,
};

const StateCallback = fn (state: i32, request_id: i64, error_code: i32) callconv(.c) i32;

const SetLongFn = *const fn (i32, i32) callconv(.c) void;
const SetStateFn = *const fn (?*const StateCallback) callconv(.c) void;
const StartFn = *const fn ([*:0]const u8, i32, i32) callconv(.c) i32;
const StatusFn = *const fn () callconv(.c) i32;
const CancelFn = *const fn (i64) callconv(.c) void;
const ReadDataFn = *const fn (i64, i32) callconv(.c) ?*ApiOut;
const SetLanguageFn = *const fn ([*:0]const u8) callconv(.c) void;

const Fn2 = *const fn ([*:0]const u8, [*:0]const u8) callconv(.c) ?*ApiOut;
const Fn3 = *const fn ([*:0]const u8, [*:0]const u8, [*:0]const u8) callconv(.c) ?*ApiOut;
const Fn4 = *const fn ([*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8) callconv(.c) ?*ApiOut;
const Fn5 = *const fn ([*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8) callconv(.c) ?*ApiOut;
const FnOffset = *const fn ([*:0]const u8, i32, [*:0]const u8) callconv(.c) ?*ApiOut;
const FreeFn = *const fn (?*ApiOut) callconv(.c) void;

const Api = struct {
    // libWind.QuantData.so — required.
    setLongValue: SetLongFn,
    setStateCallback: SetStateFn,
    start: StartFn,
    stop: StatusFn,
    isConnectionOK: StatusFn,
    cancelRequest: CancelFn,
    readdata: ReadDataFn,
    free_data: FreeFn,

    // libWind.QuantData.so — optional, so an older terminal still loads.
    wsd: ?Fn5,
    wss: ?Fn3,
    wsq: ?Fn3,
    wsq_asyn: ?Fn3,
    wset: ?Fn2,
    wses: ?Fn5,
    wsee: ?Fn3,
    edb: ?Fn4,
    wnd: ?Fn4,
    wnq: ?Fn2,
    wnq_asyn: ?Fn2,
    wnc: ?Fn2,
    htocode: ?Fn3,
    tdays: ?Fn3,
    tdaysoffset: ?FnOffset,
    tdayscount: ?Fn3,
    setLanguage: ?SetLanguageFn,

    // libWind.Cosmos.QuantData.so
    quant_start: StartFn,
    quant_stop: StatusFn,
    quant_isConnectionOK: StatusFn,
    quant_free_data: FreeFn,
    wsi: ?Fn5,
    wst: ?Fn5,
};

/// The Wind libraries keep process-global state (one authorization, one state
/// callback), so they are loaded once and never unloaded — their background
/// threads outlive any `dlclose`.
var api_lock: SpinLock = .{};
var api_state: enum { unloaded, loaded, failed } = .unloaded;
var loaded_api: Api = undefined;
var load_error: Error = error.WindLibraryNotFound;

fn ensureApi() Error!*const Api {
    api_lock.lock();
    defer api_lock.unlock();
    switch (api_state) {
        .loaded => return &loaded_api,
        .failed => return load_error,
        .unloaded => {
            loaded_api = load() catch |err| {
                load_error = err;
                api_state = .failed;
                return err;
            };
            api_state = .loaded;
            return &loaded_api;
        },
    }
}

fn load() Error!Api {
    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const override = std.c.getenv(lib_dir_env);
    const dir = if (override) |value| std.mem.span(value) else default_lib_dir;

    const main = try openLibrary(&dir_buffer, dir, main_lib_name);
    const quant = try openLibrary(&dir_buffer, dir, quant_lib_name);

    return .{
        .setLongValue = try require(SetLongFn, main, "setLongValue"),
        .setStateCallback = try require(SetStateFn, main, "setStateCallback"),
        .start = try require(StartFn, main, "start"),
        .stop = try require(StatusFn, main, "stop"),
        .isConnectionOK = try require(StatusFn, main, "isConnectionOK"),
        .cancelRequest = try require(CancelFn, main, "cancelRequest"),
        .readdata = try require(ReadDataFn, main, "readdata"),
        .free_data = try require(FreeFn, main, "free_data"),

        .wsd = lookup(Fn5, main, "wsd"),
        .wss = lookup(Fn3, main, "wss"),
        .wsq = lookup(Fn3, main, "wsq"),
        .wsq_asyn = lookup(Fn3, main, "wsq_asyn"),
        .wset = lookup(Fn2, main, "wset"),
        .wses = lookup(Fn5, main, "wses"),
        .wsee = lookup(Fn3, main, "wsee"),
        .edb = lookup(Fn4, main, "edb"),
        .wnd = lookup(Fn4, main, "wnd"),
        .wnq = lookup(Fn2, main, "wnq"),
        .wnq_asyn = lookup(Fn2, main, "wnq_asyn"),
        .wnc = lookup(Fn2, main, "wnc"),
        .htocode = lookup(Fn3, main, "htocode"),
        .tdays = lookup(Fn3, main, "tdays"),
        .tdaysoffset = lookup(FnOffset, main, "tdaysoffset"),
        .tdayscount = lookup(Fn3, main, "tdayscount"),
        .setLanguage = lookup(SetLanguageFn, main, "SetLanguage"),

        .quant_start = try require(StartFn, quant, "start"),
        .quant_stop = try require(StatusFn, quant, "stop"),
        .quant_isConnectionOK = try require(StatusFn, quant, "isConnectionOK"),
        .quant_free_data = try require(FreeFn, quant, "free_data"),
        .wsi = lookup(Fn5, quant, "wsi"),
        .wst = lookup(Fn5, quant, "wst"),
    };
}

fn openLibrary(buffer: []u8, dir: []const u8, name: []const u8) Error!*anyopaque {
    const path = std.fmt.bufPrintZ(buffer, "{s}/{s}", .{ dir, name }) catch return error.WindLibraryNotFound;
    // RTLD_LOCAL is required, not just tidier: the two libraries export the same
    // names (start, stop, free_data, isConnectionOK, ...), so loading them globally
    // lets the first one interpose the second one's internal calls. That leaves the
    // quant library answering -103 and kills real-time pushes. WindPy loads them
    // locally too, via ctypes' default mode.
    return std.c.dlopen(path.ptr, .{ .NOW = true }) orelse error.WindLibraryNotFound;
}

fn lookup(comptime Fn: type, handle: *anyopaque, comptime name: [:0]const u8) ?Fn {
    const symbol = std.c.dlsym(handle, name.ptr) orelse return null;
    return @ptrCast(@alignCast(symbol));
}

fn require(comptime Fn: type, handle: *anyopaque, comptime name: [:0]const u8) Error!Fn {
    return lookup(Fn, handle, name) orelse error.WindSymbolMissing;
}

/// Events arrive on a Wind-owned thread, so they are parked in a fixed-size ring
/// buffer and drained by `poll` on the caller's thread. No allocation happens in
/// the callback.
const RawEvent = struct {
    state: i32,
    request_id: i64,
    error_code: i32,
};

const event_queue_capacity = 1024;

/// Wind calls the state callback from its own thread, and `std.Io.Mutex` needs an
/// `Io` this code has no way to reach from there. Both critical sections here are
/// a few instructions long and never block, so a spin lock is the right shape.
const SpinLock = struct {
    held: std.atomic.Value(bool) = .init(false),

    fn lock(self: *SpinLock) void {
        while (self.held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn unlock(self: *SpinLock) void {
        self.held.store(false, .release);
    }
};

var queue_lock: SpinLock = .{};
var queue_items: [event_queue_capacity]RawEvent = undefined;
var queue_head: usize = 0;
var queue_len: usize = 0;
var queue_overflow: bool = false;

fn stateCallback(state: i32, request_id: i64, error_code: i32) callconv(.c) i32 {
    queue_lock.lock();
    defer queue_lock.unlock();
    if (queue_len == event_queue_capacity) {
        queue_overflow = true;
        return 0;
    }
    queue_items[(queue_head + queue_len) % event_queue_capacity] = .{
        .state = state,
        .request_id = request_id,
        .error_code = error_code,
    };
    queue_len += 1;
    return 0;
}

fn popEvent() ?RawEvent {
    queue_lock.lock();
    defer queue_lock.unlock();
    if (queue_len == 0) return null;
    const item = queue_items[queue_head];
    queue_head = (queue_head + 1) % event_queue_capacity;
    queue_len -= 1;
    return item;
}

fn takeOverflow() bool {
    queue_lock.lock();
    defer queue_lock.unlock();
    const overflowed = queue_overflow;
    queue_overflow = false;
    return overflowed;
}

/// A live request registered with Wind. Call deinit before the owning Wind is deinitialized.
pub const Subscription = struct {
    wind: *Wind,
    request_id: u64,
    active: bool = true,

    pub fn cancel(self: *Subscription) Error!void {
        if (!self.active) return;
        try self.wind.cancelRequest(self.request_id);
        self.active = false;
    }

    pub fn deinit(self: *Subscription) void {
        self.cancel() catch {};
    }
};

pub const SubscriptionStart = struct {
    error_code: i32,
    subscription: ?Subscription,
};

pub const Wind = struct {
    api: *const Api,
    callback_registered: bool,

    pub fn init() Error!Wind {
        return .{ .api = try ensureApi(), .callback_registered = false };
    }

    pub fn deinit(self: *Wind) void {
        self.cancelAllRequests() catch {};
        self.* = undefined;
    }

    /// `options2` exists only in the COM API and is ignored here; pass null.
    pub fn start(self: *Wind, options: ?[]const u8, options2: ?[]const u8, timeout_ms: i32) Error!i32 {
        _ = options2;
        const text = try dupeZ(options orelse "");
        defer scratch.free(text);

        // Must precede start; without it start never returns.
        self.api.setLongValue(set_long_product_key, product_type);

        const code = self.api.start(text.ptr, timeout_ms, product_type);
        if (code != 0) return code;
        // wsi/wst live in the second library and need their own session. A failure
        // here is not fatal for the rest of the API, so it is not propagated.
        _ = self.api.quant_start(text.ptr, timeout_ms, product_type);
        return 0;
    }

    pub fn stop(self: *Wind) Error!i32 {
        const code = self.api.stop();
        _ = self.api.quant_stop();
        return code;
    }

    pub fn isConnected(self: *Wind) Error!i32 {
        const main_state = self.api.isConnectionOK();
        if (main_state == 0) return 0;
        return if (self.api.quant_isConnectionOK() != 0) main_state else 0;
    }

    pub fn setLanguage(self: *Wind, language: []const u8) Error!void {
        const setter = self.api.setLanguage orelse return error.UnsupportedOnThisPlatform;
        const text = try dupeZ(language);
        defer scratch.free(text);
        setter(text.ptr);
    }

    pub fn cancelRequest(self: *Wind, request_id: u64) Error!void {
        self.api.cancelRequest(@bitCast(request_id));
    }

    pub fn cancelAllRequests(self: *Wind) Error!void {
        try self.cancelRequest(0);
    }

    pub fn wsd(self: *Wind, allocator: std.mem.Allocator, codes: []const u8, fields: []const u8, begin_time: []const u8, end_time: []const u8, options: []const u8) Error!Data {
        return call5(allocator, self.api.wsd, self.api.free_data, codes, fields, begin_time, end_time, options);
    }

    pub fn wss(self: *Wind, allocator: std.mem.Allocator, codes: []const u8, fields: []const u8, options: []const u8) Error!Data {
        return call3(allocator, self.api.wss, self.api.free_data, codes, fields, options);
    }

    pub fn wsi(self: *Wind, allocator: std.mem.Allocator, codes: []const u8, fields: []const u8, begin_time: []const u8, end_time: []const u8, options: []const u8) Error!Data {
        return call5(allocator, self.api.wsi, self.api.quant_free_data, codes, fields, begin_time, end_time, options);
    }

    pub fn wst(self: *Wind, allocator: std.mem.Allocator, codes: []const u8, fields: []const u8, begin_time: []const u8, end_time: []const u8, options: []const u8) Error!Data {
        return call5(allocator, self.api.wst, self.api.quant_free_data, codes, fields, begin_time, end_time, options);
    }

    /// Returns an immediate WSQ snapshot; use subscribeWsq for a live stream.
    pub fn wsq(self: *Wind, allocator: std.mem.Allocator, codes: []const u8, fields: []const u8, options: []const u8) Error!Data {
        return call3(allocator, self.api.wsq, self.api.free_data, codes, fields, options);
    }

    /// Not exported by the Linux libraries.
    pub fn tdq(self: *Wind, allocator: std.mem.Allocator, codes: []const u8, fields: []const u8, options: []const u8) Error!Data {
        _ = .{ self, allocator, codes, fields, options };
        return error.UnsupportedOnThisPlatform;
    }

    /// Not exported by the Linux libraries.
    pub fn bbq(self: *Wind, allocator: std.mem.Allocator, codes: []const u8, fields: []const u8, options: []const u8) Error!Data {
        _ = .{ self, allocator, codes, fields, options };
        return error.UnsupportedOnThisPlatform;
    }

    pub fn wset(self: *Wind, allocator: std.mem.Allocator, report_name: []const u8, options: []const u8) Error!Data {
        return call2(allocator, self.api.wset, self.api.free_data, report_name, options);
    }

    /// Not exported by the Linux libraries.
    pub fn wgel(self: *Wind, allocator: std.mem.Allocator, function_name: []const u8, wind_id: []const u8, options: []const u8) Error!Data {
        _ = .{ self, allocator, function_name, wind_id, options };
        return error.UnsupportedOnThisPlatform;
    }

    pub fn wnd(self: *Wind, allocator: std.mem.Allocator, codes: []const u8, begin_time: []const u8, end_time: []const u8, options: []const u8) Error!Data {
        return call4(allocator, self.api.wnd, self.api.free_data, codes, begin_time, end_time, options);
    }

    /// Returns an immediate WNQ snapshot; use subscribeWnq for a live stream.
    pub fn wnq(self: *Wind, allocator: std.mem.Allocator, codes: []const u8, options: []const u8) Error!Data {
        return call2(allocator, self.api.wnq, self.api.free_data, codes, options);
    }

    pub fn wnc(self: *Wind, allocator: std.mem.Allocator, codes: []const u8, options: []const u8) Error!Data {
        return call2(allocator, self.api.wnc, self.api.free_data, codes, options);
    }

    pub fn edb(self: *Wind, allocator: std.mem.Allocator, codes: []const u8, begin_time: []const u8, end_time: []const u8, options: []const u8) Error!Data {
        return call4(allocator, self.api.edb, self.api.free_data, codes, begin_time, end_time, options);
    }

    pub fn htocode(self: *Wind, allocator: std.mem.Allocator, codes: []const u8, security_type: []const u8, options: []const u8) Error!Data {
        return call3(allocator, self.api.htocode, self.api.free_data, codes, security_type, options);
    }

    pub fn tdays(self: *Wind, allocator: std.mem.Allocator, begin_time: []const u8, end_time: []const u8, options: []const u8) Error!Data {
        return call3(allocator, self.api.tdays, self.api.free_data, begin_time, end_time, options);
    }

    pub fn tdaysOffset(self: *Wind, allocator: std.mem.Allocator, begin_time: []const u8, offset: i32, options: []const u8) Error!TradingDayOffset {
        const request = self.api.tdaysoffset orelse return error.UnsupportedOnThisPlatform;
        const begin = try dupeZ(begin_time);
        defer scratch.free(begin);
        const option_text = try dupeZ(options);
        defer scratch.free(option_text);

        var data = try finish(allocator, request(begin.ptr, offset, option_text.ptr), self.api.free_data);
        defer data.deinit();
        if (data.error_code != 0) return .{ .error_code = data.error_code, .date = null };
        if (data.values.len != 0) {
            switch (data.values[0]) {
                .date, .number => |value| return .{ .error_code = 0, .date = value },
                else => {},
            }
        }
        // Some builds report the answer through Times instead.
        if (data.times.len != 0) return .{ .error_code = 0, .date = data.times[0] };
        return error.UnexpectedVariant;
    }

    pub fn tdaysCount(self: *Wind, allocator: std.mem.Allocator, begin_time: []const u8, end_time: []const u8, options: []const u8) Error!TradingDayCount {
        var data = try call3(allocator, self.api.tdayscount, self.api.free_data, begin_time, end_time, options);
        defer data.deinit();
        if (data.error_code != 0) return .{ .error_code = data.error_code, .count = null };
        if (data.values.len == 0) return error.UnexpectedVariant;
        const count: i32 = switch (data.values[0]) {
            .integer => |value| value,
            .integer64 => |value| std.math.cast(i32, value) orelse return error.UnexpectedVariant,
            .number => |value| @intFromFloat(value),
            else => return error.UnexpectedVariant,
        };
        return .{ .error_code = 0, .count = count };
    }

    pub fn wsee(self: *Wind, allocator: std.mem.Allocator, codes: []const u8, fields: []const u8, options: []const u8) Error!Data {
        return call3(allocator, self.api.wsee, self.api.free_data, codes, fields, options);
    }

    pub fn wses(self: *Wind, allocator: std.mem.Allocator, codes: []const u8, fields: []const u8, begin_time: []const u8, end_time: []const u8, options: []const u8) Error!Data {
        return call5(allocator, self.api.wses, self.api.free_data, codes, fields, begin_time, end_time, options);
    }

    pub fn subscribeWsq(self: *Wind, codes: []const u8, fields: []const u8, options: []const u8) Error!SubscriptionStart {
        self.ensureCallback();
        const request = self.api.wsq_asyn orelse return error.UnsupportedOnThisPlatform;
        const code_text = try dupeZ(codes);
        defer scratch.free(code_text);
        const field_text = try dupeZ(fields);
        defer scratch.free(field_text);
        const option_text = try dupeZ(options);
        defer scratch.free(option_text);
        return self.finishSubscription(request(code_text.ptr, field_text.ptr, option_text.ptr));
    }

    /// Not exported by the Linux libraries.
    pub fn subscribeTdq(self: *Wind, codes: []const u8, fields: []const u8, options: []const u8) Error!SubscriptionStart {
        _ = .{ self, codes, fields, options };
        return error.UnsupportedOnThisPlatform;
    }

    /// Not exported by the Linux libraries.
    pub fn subscribeBbq(self: *Wind, codes: []const u8, fields: []const u8, options: []const u8) Error!SubscriptionStart {
        _ = .{ self, codes, fields, options };
        return error.UnsupportedOnThisPlatform;
    }

    pub fn subscribeWnq(self: *Wind, codes: []const u8, options: []const u8) Error!SubscriptionStart {
        self.ensureCallback();
        const request = self.api.wnq_asyn orelse return error.UnsupportedOnThisPlatform;
        const code_text = try dupeZ(codes);
        defer scratch.free(code_text);
        const option_text = try dupeZ(options);
        defer scratch.free(option_text);
        return self.finishSubscription(request(code_text.ptr, option_text.ptr));
    }

    /// Returns the next subscription event, if one is ready.
    ///
    /// Wind delivers pushes on its own thread; they are queued there and decoded
    /// here, so user code never runs on a Wind thread.
    pub fn poll(self: *Wind, allocator: std.mem.Allocator) Error!?SubscriptionEvent {
        if (!self.callback_registered) return null;
        if (takeOverflow()) return error.EventQueueOverflow;

        while (true) {
            const raw = popEvent() orelse return null;
            if (raw.state == 4) continue; // Trade notifications are intentionally outside this package's scope.
            const request_id: u64 = @bitCast(raw.request_id);
            if (raw.error_code != 0) return .{
                .request_id = request_id,
                .state = raw.state,
                .error_code = raw.error_code,
                .data = null,
            };
            if (raw.state != 1) return .{
                .request_id = request_id,
                .state = raw.state,
                .error_code = 0,
                .data = null,
            };
            return .{
                .request_id = request_id,
                .state = raw.state,
                .error_code = 0,
                .data = try self.readData(allocator, raw.request_id),
            };
        }
    }

    fn ensureCallback(self: *Wind) void {
        if (self.callback_registered) return;
        self.api.setStateCallback(&stateCallback);
        self.callback_registered = true;
    }

    fn finishSubscription(self: *Wind, out: ?*ApiOut) Error!SubscriptionStart {
        const result = out orelse return error.UnexpectedSubscriptionResult;
        defer self.api.free_data(result);
        if (result.ErrorCode != 0) return .{ .error_code = result.ErrorCode, .subscription = null };
        return .{ .error_code = 0, .subscription = .{
            .wind = self,
            .request_id = @bitCast(result.RequestID),
        } };
    }

    fn readData(self: *Wind, allocator: std.mem.Allocator, request_id: i64) Error!Data {
        return finish(allocator, self.api.readdata(request_id, 1), self.api.free_data);
    }
};

fn dupeZ(text: []const u8) Error![:0]u8 {
    return scratch.dupeZ(u8, text) catch error.OutOfMemory;
}

fn call2(allocator: std.mem.Allocator, request: ?Fn2, free: FreeFn, a: []const u8, b: []const u8) Error!Data {
    const call = request orelse return error.UnsupportedOnThisPlatform;
    const za = try dupeZ(a);
    defer scratch.free(za);
    const zb = try dupeZ(b);
    defer scratch.free(zb);
    return finish(allocator, call(za.ptr, zb.ptr), free);
}

fn call3(allocator: std.mem.Allocator, request: ?Fn3, free: FreeFn, a: []const u8, b: []const u8, c: []const u8) Error!Data {
    const call = request orelse return error.UnsupportedOnThisPlatform;
    const za = try dupeZ(a);
    defer scratch.free(za);
    const zb = try dupeZ(b);
    defer scratch.free(zb);
    const zc = try dupeZ(c);
    defer scratch.free(zc);
    return finish(allocator, call(za.ptr, zb.ptr, zc.ptr), free);
}

fn call4(allocator: std.mem.Allocator, request: ?Fn4, free: FreeFn, a: []const u8, b: []const u8, c: []const u8, d: []const u8) Error!Data {
    const call = request orelse return error.UnsupportedOnThisPlatform;
    const za = try dupeZ(a);
    defer scratch.free(za);
    const zb = try dupeZ(b);
    defer scratch.free(zb);
    const zc = try dupeZ(c);
    defer scratch.free(zc);
    const zd = try dupeZ(d);
    defer scratch.free(zd);
    return finish(allocator, call(za.ptr, zb.ptr, zc.ptr, zd.ptr), free);
}

fn call5(allocator: std.mem.Allocator, request: ?Fn5, free: FreeFn, a: []const u8, b: []const u8, c: []const u8, d: []const u8, e: []const u8) Error!Data {
    const call = request orelse return error.UnsupportedOnThisPlatform;
    const za = try dupeZ(a);
    defer scratch.free(za);
    const zb = try dupeZ(b);
    defer scratch.free(zb);
    const zc = try dupeZ(c);
    defer scratch.free(zc);
    const zd = try dupeZ(d);
    defer scratch.free(zd);
    const ze = try dupeZ(e);
    defer scratch.free(ze);
    return finish(allocator, call(za.ptr, zb.ptr, zc.ptr, zd.ptr, ze.ptr), free);
}

/// Copies an ApiOut into allocator-owned memory and releases the Wind-owned one.
fn finish(allocator: std.mem.Allocator, out: ?*ApiOut, free: FreeFn) Error!Data {
    const result = out orelse return error.UnexpectedVariant;
    defer free(result);

    var data = Data.empty(allocator, result.ErrorCode);
    errdefer data.deinit();

    data.codes = try copyStringArray(allocator, &result.Codes);
    data.fields = try copyStringArray(allocator, &result.Fields);
    data.times = try copyNumberArray(allocator, &result.Times);
    data.values = try copyValueArray(allocator, &result.Data);
    return data;
}

fn copyStringArray(allocator: std.mem.Allocator, source: *const Variant) Error![][]u8 {
    const count = source.arrayLen();
    if (count == 0) return allocator.alloc([]u8, 0);
    if (source.baseType() != vt.CSTR) return error.UnexpectedVariant;
    const array = source.val.parray orelse return error.UnexpectedVariant;
    const items: [*]align(1) const ?[*:0]align(1) const u8 = @ptrCast(array.pvData orelse return error.UnexpectedVariant);

    const result = try allocator.alloc([]u8, count);
    var filled: usize = 0;
    errdefer {
        for (result[0..filled]) |text| allocator.free(text);
        allocator.free(result);
    }
    for (result, 0..) |*destination, index| {
        destination.* = try copyCString(allocator, items[index]);
        filled += 1;
    }
    return result;
}

fn copyNumberArray(allocator: std.mem.Allocator, source: *const Variant) Error![]f64 {
    const count = source.arrayLen();
    if (count == 0) return allocator.alloc(f64, 0);
    const base = source.baseType();
    if (base != vt.DATE and base != vt.R8) return error.UnexpectedVariant;
    const array = source.val.parray orelse return error.UnexpectedVariant;
    const items: [*]align(1) const f64 = @ptrCast(array.pvData orelse return error.UnexpectedVariant);

    const result = try allocator.alloc(f64, count);
    // Wind's Linux libraries already use the OLE Automation epoch (1899-12-30).
    for (result, 0..) |*destination, index| destination.* = items[index];
    return result;
}

fn copyValueArray(allocator: std.mem.Allocator, source: *const Variant) Error![]Value {
    const count = source.arrayLen();
    if (count == 0) return allocator.alloc(Value, 0);
    const array = source.val.parray orelse return error.UnexpectedVariant;
    const raw = array.pvData orelse return error.UnexpectedVariant;
    const base = source.baseType();

    const result = try allocator.alloc(Value, count);
    var filled: usize = 0;
    errdefer {
        for (result[0..filled]) |*value| value.deinit(allocator);
        allocator.free(result);
    }
    for (result, 0..) |*destination, index| {
        destination.* = switch (base) {
            vt.VARIANT => item: {
                const item: Variant = @as([*]align(1) const Variant, @ptrCast(raw))[index];
                break :item try copyValue(allocator, &item);
            },
            vt.CSTR => .{ .string = try copyCString(allocator, @as([*]align(1) const ?[*:0]align(1) const u8, @ptrCast(raw))[index]) },
            vt.R8 => .{ .number = @as([*]align(1) const f64, @ptrCast(raw))[index] },
            vt.R4 => .{ .float = @as([*]align(1) const f32, @ptrCast(raw))[index] },
            vt.DATE => .{ .date = @as([*]align(1) const f64, @ptrCast(raw))[index] },
            vt.I4 => .{ .integer = @as([*]align(1) const i32, @ptrCast(raw))[index] },
            vt.I8 => .{ .integer64 = @as([*]align(1) const i64, @ptrCast(raw))[index] },
            vt.I2 => .{ .integer = @as([*]align(1) const i16, @ptrCast(raw))[index] },
            else => return error.UnexpectedVariant,
        };
        filled += 1;
    }
    return result;
}

fn copyValue(allocator: std.mem.Allocator, source: *const Variant) Error!Value {
    if (source.isArray()) return error.UnexpectedVariant;
    return switch (source.vt) {
        vt.EMPTY, vt.NULL => .empty,
        vt.I1 => .{ .integer = source.val.bVal },
        vt.I2 => .{ .integer = source.val.iVal },
        vt.I4 => .{ .integer = source.val.lVal },
        vt.I8 => .{ .integer64 = source.val.llVal },
        vt.R4 => .{ .float = source.val.fltVal },
        vt.R8 => .{ .number = source.val.dblVal },
        vt.DATE => .{ .date = source.val.date },
        vt.BOOL => .{ .boolean = source.val.bVal != 0 },
        vt.CSTR => .{ .string = try copyCString(allocator, source.val.cstrVal) },
        else => error.UnexpectedVariant,
    };
}

fn copyCString(allocator: std.mem.Allocator, value: ?[*:0]align(1) const u8) Error![]u8 {
    const text = value orelse return allocator.dupe(u8, "");
    return allocator.dupe(u8, std.mem.span(text));
}

test "Variant layout matches the C API" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Variant));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Variant, "val"));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(SafeArray));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(SafeArray, "pvData"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(SafeArray, "rgsabound"));
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(ApiOut));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(ApiOut, "Codes"));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(ApiOut, "Data"));
}

test "the event queue keeps order and reports overflow" {
    queue_head = 0;
    queue_len = 0;
    queue_overflow = false;

    _ = stateCallback(1, 7, 0);
    _ = stateCallback(2, 8, -1);
    try std.testing.expectEqual(@as(i64, 7), popEvent().?.request_id);
    try std.testing.expectEqual(@as(i32, -1), popEvent().?.error_code);
    try std.testing.expectEqual(@as(?RawEvent, null), popEvent());

    var index: usize = 0;
    while (index < event_queue_capacity + 1) : (index += 1) _ = stateCallback(1, @intCast(index), 0);
    try std.testing.expect(takeOverflow());
    try std.testing.expect(!takeOverflow());

    queue_head = 0;
    queue_len = 0;
}

test "an empty variant decodes to an empty slice" {
    const allocator = std.testing.allocator;
    const empty = Variant{ .vt = vt.EMPTY, .val = .{ .llVal = 0 } };

    const codes = try copyStringArray(allocator, &empty);
    defer freeStrings(allocator, codes);
    try std.testing.expectEqual(@as(usize, 0), codes.len);

    const times = try copyNumberArray(allocator, &empty);
    defer allocator.free(times);
    try std.testing.expectEqual(@as(usize, 0), times.len);
}

test "a three-dimensional variant array flattens to time-code-field order" {
    const allocator = std.testing.allocator;
    // One time, two codes, three fields — the shape a wss request returns.
    var bounds = [_]u32{ 1, 2, 3 };
    var items = [_]Variant{
        .{ .vt = vt.R8, .val = .{ .dblVal = 0 } }, .{ .vt = vt.R8, .val = .{ .dblVal = 1 } },
        .{ .vt = vt.R8, .val = .{ .dblVal = 2 } }, .{ .vt = vt.R8, .val = .{ .dblVal = 3 } },
        .{ .vt = vt.R8, .val = .{ .dblVal = 4 } }, .{ .vt = vt.R8, .val = .{ .dblVal = 5 } },
    };
    var array = SafeArray{
        .cDims = 3,
        .fFeatures = 0,
        .cbElements = @sizeOf(Variant),
        .cLocks = 0,
        .pvData = &items,
        .rgsabound = &bounds,
    };
    const source = Variant{ .vt = vt.VARIANT | vt.ARRAY, .val = .{ .parray = &array } };

    const values = try copyValueArray(allocator, &source);
    defer allocator.free(values);
    try std.testing.expectEqual(@as(usize, 6), values.len);
    // Second code, third field.
    try std.testing.expectEqual(Value{ .number = 5 }, values[0 * 2 * 3 + 1 * 3 + 2]);
}
