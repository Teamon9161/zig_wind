const std = @import("std");

const win = struct {
    const HRESULT = i32;
    const ULONG = u32;
    const DISPID = i32;
    const UINT = u32;
    const LONG = i32;
    const LONGLONG = i64;
    const ULONGLONG = u64;
    const BOOL = i32;
    const VARTYPE = u16;
    const DOUBLE = f64;
    const FLOAT = f32;
    const VARIANT_BOOL = i16;
    const DATE = f64;
    const OLECHAR = u16;
    const BSTR = ?[*]u16;

    // VARIANT is 24 bytes with 8-byte alignment on supported Windows x64 targets.
    const VARIANT = extern struct { storage: [24]u8 align(8) };
    const CLSID = extern struct {
        Data1: u32,
        Data2: u16,
        Data3: u16,
        Data4: [8]u8,
    };
    const SubscriptionEventRaw = extern struct {
        state: LONG,
        request_id: ULONGLONG,
        error_code: LONG,
    };

    const VT_EMPTY: VARTYPE = 0;
    const VT_NULL: VARTYPE = 1;
    const VT_I4: VARTYPE = 3;
    const VT_R4: VARTYPE = 4;
    const VT_R8: VARTYPE = 5;
    const VT_DATE: VARTYPE = 7;
    const VT_BSTR: VARTYPE = 8;
    const VT_BOOL: VARTYPE = 11;
    const VT_I8: VARTYPE = 20;
    const VT_UI8: VARTYPE = 21;
    const VT_TYPEMASK: VARTYPE = 0x0fff;
};

const helpers = struct {
    extern fn wind_com_initialize() win.HRESULT;
    extern fn wind_com_uninitialize() void;
    extern fn wind_variant_init(variant: *win.VARIANT) void;
    extern fn wind_variant_clear(variant: *win.VARIANT) void;
    extern fn wind_get_clsid(out: *win.CLSID) void;
    extern fn wind_create_dispatch(out: *?*anyopaque) win.HRESULT;
    extern fn wind_release_dispatch(dispatch: *anyopaque) win.ULONG;
    extern fn wind_dispatch_invoke(dispatch: *anyopaque, member: win.DISPID, args: ?[*]win.VARIANT, arg_count: win.UINT, result: *win.VARIANT) win.HRESULT;
    extern fn wind_dispatch_get_id(dispatch: *anyopaque, name: [*:0]const win.OLECHAR, out: *win.DISPID) win.HRESULT;

    extern fn wind_variant_set_bstr(variant: *win.VARIANT, value: [*:0]const win.OLECHAR) void;
    extern fn wind_variant_set_i4(variant: *win.VARIANT, value: win.LONG) void;
    extern fn wind_variant_set_i8(variant: *win.VARIANT, value: win.LONGLONG) void;
    extern fn wind_variant_set_ui8(variant: *win.VARIANT, value: win.ULONGLONG) void;
    extern fn wind_variant_set_variant_ref(variant: *win.VARIANT, value: *win.VARIANT) void;
    extern fn wind_variant_set_i4_ref(variant: *win.VARIANT, value: *win.LONG) void;
    extern fn wind_variant_array_count(variant: *const win.VARIANT) win.LONG;
    extern fn wind_variant_array_element(array_variant: *const win.VARIANT, index: win.LONG, out: *win.VARIANT) win.HRESULT;
    extern fn wind_variant_type(variant: *const win.VARIANT) win.VARTYPE;
    extern fn wind_variant_bstr(variant: *const win.VARIANT) win.BSTR;
    extern fn wind_variant_i4(variant: *const win.VARIANT) win.LONG;
    extern fn wind_variant_i8(variant: *const win.VARIANT) win.LONGLONG;
    extern fn wind_variant_r8(variant: *const win.VARIANT) win.DOUBLE;
    extern fn wind_variant_r4(variant: *const win.VARIANT) win.FLOAT;
    extern fn wind_variant_bool(variant: *const win.VARIANT) win.VARIANT_BOOL;
    extern fn wind_variant_date(variant: *const win.VARIANT) win.DATE;
    extern fn wind_bstr_len(value: win.BSTR) win.UINT;

    extern fn wind_event_sink_create(dispatch: *anyopaque, out: *?*anyopaque) win.HRESULT;
    extern fn wind_event_sink_destroy(sink: *anyopaque) void;
    extern fn wind_pump_messages() void;
    extern fn wind_event_sink_pop(sink: *anyopaque, out: *win.SubscriptionEventRaw) win.BOOL;
    extern fn wind_event_sink_take_overflow(sink: *anyopaque) win.BOOL;
};

pub const Error = error{
    ComInitializationFailed,
    WindClassUnavailable,
    AutomationCallFailed,
    UnknownAutomationMethod,
    EventSinkUnavailable,
    EventQueueOverflow,
    UnexpectedSubscriptionResult,
    OutOfMemory,
    InvalidUtf8,
    UnexpectedVariant,
    InvalidDataLayout,
};

pub const Value = union(enum) {
    empty,
    string: []u8,
    integer: i32,
    integer64: i64,
    float: f32,
    number: f64,
    boolean: bool,
    date: f64,

    fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |value| allocator.free(value),
            else => {},
        }
    }
};

pub const Data = struct {
    allocator: std.mem.Allocator,
    error_code: i32,
    codes: [][]u8,
    fields: [][]u8,
    times: []f64,
    values: []Value,

    pub fn deinit(self: *Data) void {
        freeStrings(self.allocator, self.codes);
        freeStrings(self.allocator, self.fields);
        self.allocator.free(self.times);
        for (self.values) |*value| value.deinit(self.allocator);
        self.allocator.free(self.values);
        self.* = undefined;
    }

    pub fn valueAt(self: *const Data, time_index: usize, code_index: usize, field_index: usize) Error!Value {
        const code_count = self.codes.len;
        const field_count = self.fields.len;
        if (code_count == 0 or field_count == 0) return error.InvalidDataLayout;
        const index = time_index * code_count * field_count + code_index * field_count + field_index;
        if (time_index >= self.times.len or code_index >= code_count or field_index >= field_count or index >= self.values.len) {
            return error.InvalidDataLayout;
        }
        return self.values[index];
    }
};

pub const TradingDayOffset = struct {
    error_code: i32,
    date: ?f64,
};

pub const TradingDayCount = struct {
    error_code: i32,
    count: ?i32,
};

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

/// One event from any active data subscription. Owns data when data is non-null.
pub const SubscriptionEvent = struct {
    request_id: u64,
    state: i32,
    error_code: i32,
    data: ?Data,

    pub fn deinit(self: *SubscriptionEvent) void {
        if (self.data) |*data| data.deinit();
        self.* = undefined;
    }
};

pub const Wind = struct {
    dispatch: ?*anyopaque,
    event_sink: ?*anyopaque,
    apartment_initialized: bool,

    pub fn init() Error!Wind {
        const init_result = helpers.wind_com_initialize();
        if (init_result < 0) return error.ComInitializationFailed;

        var dispatch: ?*anyopaque = null;
        const create_result = helpers.wind_create_dispatch(&dispatch);
        if (create_result < 0 or dispatch == null) {
            helpers.wind_com_uninitialize();
            return error.WindClassUnavailable;
        }

        return .{
            .dispatch = dispatch,
            .event_sink = null,
            .apartment_initialized = true,
        };
    }

    pub fn deinit(self: *Wind) void {
        self.cancelAllRequests() catch {};
        if (self.event_sink) |sink| {
            helpers.wind_event_sink_destroy(sink);
            self.event_sink = null;
        }
        if (self.dispatch) |dispatch| {
            _ = helpers.wind_release_dispatch(dispatch);
            self.dispatch = null;
        }
        if (self.apartment_initialized) {
            helpers.wind_com_uninitialize();
            self.apartment_initialized = false;
        }
    }

    pub fn start(self: *Wind, options: ?[]const u8, options2: ?[]const u8, timeout_ms: i32) Error!i32 {
        var options_arg: win.VARIANT = undefined;
        var options2_arg: win.VARIANT = undefined;
        var timeout_arg: win.VARIANT = undefined;
        helpers.wind_variant_init(&options_arg);
        helpers.wind_variant_init(&options2_arg);
        helpers.wind_variant_init(&timeout_arg);
        defer clearVariant(&options_arg);
        defer clearVariant(&options2_arg);
        defer clearVariant(&timeout_arg);

        try setStringVariant(&options_arg, options orelse "");
        try setStringVariant(&options2_arg, options2 orelse "");
        helpers.wind_variant_set_i4(&timeout_arg, timeout_ms);

        var args = [_]win.VARIANT{ timeout_arg, options2_arg, options_arg };
        var result: win.VARIANT = undefined;
        helpers.wind_variant_init(&result);
        defer clearVariant(&result);
        try self.invokeNamed("start_cpp", args[0..], &result);
        return resultCode(&result);
    }

    pub fn stop(self: *Wind) Error!i32 {
        var result: win.VARIANT = undefined;
        helpers.wind_variant_init(&result);
        defer clearVariant(&result);
        try self.invokeNamed("stop", &.{}, &result);
        return resultCode(&result);
    }

    pub fn isConnected(self: *Wind) Error!i32 {
        var connection_state: win.LONG = 0;
        var state_ref: win.VARIANT = undefined;
        helpers.wind_variant_init(&state_ref);
        defer clearVariant(&state_ref);
        helpers.wind_variant_set_i4_ref(&state_ref, &connection_state);

        var result: win.VARIANT = undefined;
        helpers.wind_variant_init(&result);
        defer clearVariant(&result);
        try self.invokeNamed("getConnectionState", &.{state_ref}, &result);
        return connection_state;
    }

    pub fn cancelRequest(self: *Wind, request_id: u64) Error!void {
        var request: win.VARIANT = undefined;
        helpers.wind_variant_init(&request);
        defer clearVariant(&request);
        helpers.wind_variant_set_ui8(&request, request_id);
        var result: win.VARIANT = undefined;
        helpers.wind_variant_init(&result);
        defer clearVariant(&result);
        try self.invokeNamed("cancelRequest", &.{request}, &result);
    }

    pub fn cancelAllRequests(self: *Wind) Error!void {
        try self.cancelRequest(0);
    }

    pub fn wsd(self: *Wind, allocator: std.mem.Allocator, codes: []const u8, fields: []const u8, begin_time: []const u8, end_time: []const u8, options: []const u8) Error!Data {
        return self.queryData(allocator, "wsd_syn", &.{ codes, fields, begin_time, end_time, options });
    }

    pub fn wss(self: *Wind, allocator: std.mem.Allocator, codes: []const u8, fields: []const u8, options: []const u8) Error!Data {
        return self.queryData(allocator, "wss_syn", &.{ codes, fields, options });
    }

    pub fn wsi(self: *Wind, allocator: std.mem.Allocator, codes: []const u8, fields: []const u8, begin_time: []const u8, end_time: []const u8, options: []const u8) Error!Data {
        return self.queryData(allocator, "wsi_syn", &.{ codes, fields, begin_time, end_time, options });
    }

    pub fn wst(self: *Wind, allocator: std.mem.Allocator, codes: []const u8, fields: []const u8, begin_time: []const u8, end_time: []const u8, options: []const u8) Error!Data {
        return self.queryData(allocator, "wst_syn", &.{ codes, fields, begin_time, end_time, options });
    }

    /// Returns an immediate WSQ snapshot; use subscribeWsq for a live stream.
    pub fn wsq(self: *Wind, allocator: std.mem.Allocator, codes: []const u8, fields: []const u8, options: []const u8) Error!Data {
        return self.queryData(allocator, "wsq_syn", &.{ codes, fields, options });
    }

    /// Returns an immediate TDQ snapshot; use subscribeTdq for a live stream.
    pub fn tdq(self: *Wind, allocator: std.mem.Allocator, codes: []const u8, fields: []const u8, options: []const u8) Error!Data {
        return self.queryData(allocator, "tdq_syn", &.{ codes, fields, options });
    }

    /// Returns an immediate BBQ snapshot; use subscribeBbq for a live stream.
    pub fn bbq(self: *Wind, allocator: std.mem.Allocator, codes: []const u8, fields: []const u8, options: []const u8) Error!Data {
        return self.queryData(allocator, "bbq_syn", &.{ codes, fields, options });
    }

    pub fn wset(self: *Wind, allocator: std.mem.Allocator, report_name: []const u8, options: []const u8) Error!Data {
        return self.queryData(allocator, "wset_syn", &.{ report_name, options });
    }

    pub fn wgel(self: *Wind, allocator: std.mem.Allocator, function_name: []const u8, wind_id: []const u8, options: []const u8) Error!Data {
        return self.queryData(allocator, "wgel_syn", &.{ function_name, wind_id, options });
    }

    pub fn wnd(self: *Wind, allocator: std.mem.Allocator, codes: []const u8, begin_time: []const u8, end_time: []const u8, options: []const u8) Error!Data {
        return self.queryData(allocator, "wnd_syn", &.{ codes, begin_time, end_time, options });
    }

    /// Returns an immediate WNQ snapshot; use subscribeWnq for a live stream.
    pub fn wnq(self: *Wind, allocator: std.mem.Allocator, codes: []const u8, options: []const u8) Error!Data {
        return self.queryData(allocator, "wnq_syn", &.{ codes, options });
    }

    pub fn wnc(self: *Wind, allocator: std.mem.Allocator, codes: []const u8, options: []const u8) Error!Data {
        return self.queryData(allocator, "wnc_syn", &.{ codes, options });
    }

    pub fn edb(self: *Wind, allocator: std.mem.Allocator, codes: []const u8, begin_time: []const u8, end_time: []const u8, options: []const u8) Error!Data {
        return self.queryData(allocator, "edb_syn", &.{ codes, begin_time, end_time, options });
    }

    pub fn htocode(self: *Wind, allocator: std.mem.Allocator, codes: []const u8, security_type: []const u8, options: []const u8) Error!Data {
        return self.queryData(allocator, "htocode", &.{ codes, security_type, options });
    }

    pub fn tdays(self: *Wind, allocator: std.mem.Allocator, begin_time: []const u8, end_time: []const u8, options: []const u8) Error!Data {
        return self.queryData(allocator, "tdays_syn", &.{ begin_time, end_time, options });
    }

    pub fn tdaysOffset(self: *Wind, allocator: std.mem.Allocator, begin_time: []const u8, offset: i32, options: []const u8) Error!TradingDayOffset {
        var data = try self.queryDataWithInteger(allocator, "tdaysoffset_syn", &.{ begin_time }, offset, options);
        defer data.deinit();
        if (data.error_code != 0) return .{ .error_code = data.error_code, .date = null };
        if (data.values.len == 0) return error.UnexpectedVariant;
        const date = switch (data.values[0]) {
            .date => |value| value,
            .number => |value| value,
            else => return error.UnexpectedVariant,
        };
        return .{ .error_code = 0, .date = date };
    }

    pub fn tdaysCount(self: *Wind, allocator: std.mem.Allocator, begin_time: []const u8, end_time: []const u8, options: []const u8) Error!TradingDayCount {
        var data = try self.queryData(allocator, "tdayscount_syn", &.{ begin_time, end_time, options });
        defer data.deinit();
        if (data.error_code != 0) return .{ .error_code = data.error_code, .count = null };
        if (data.values.len == 0) return error.UnexpectedVariant;
        const count = switch (data.values[0]) {
            .integer => |value| value,
            else => return error.UnexpectedVariant,
        };
        return .{ .error_code = 0, .count = count };
    }

    pub fn wsee(self: *Wind, allocator: std.mem.Allocator, codes: []const u8, fields: []const u8, options: []const u8) Error!Data {
        return self.queryData(allocator, "wsee_syn", &.{ codes, fields, options });
    }

    pub fn wses(self: *Wind, allocator: std.mem.Allocator, codes: []const u8, fields: []const u8, begin_time: []const u8, end_time: []const u8, options: []const u8) Error!Data {
        return self.queryData(allocator, "wses_syn", &.{ codes, fields, begin_time, end_time, options });
    }

    pub fn subscribeWsq(self: *Wind, codes: []const u8, fields: []const u8, options: []const u8) Error!SubscriptionStart {
        return self.subscribe("wsq", codes, fields, options);
    }

    pub fn subscribeTdq(self: *Wind, codes: []const u8, fields: []const u8, options: []const u8) Error!SubscriptionStart {
        return self.subscribe("tdq", codes, fields, options);
    }

    pub fn subscribeBbq(self: *Wind, codes: []const u8, fields: []const u8, options: []const u8) Error!SubscriptionStart {
        return self.subscribe("bbq", codes, fields, options);
    }

    pub fn subscribeWnq(self: *Wind, codes: []const u8, options: []const u8) Error!SubscriptionStart {
        return self.subscribeWithoutFields("wnq", codes, options);
    }

    /// Dispatches COM messages and returns the next event, if one is ready.
    /// Call this frequently on the same thread that created Wind.
    pub fn poll(self: *Wind, allocator: std.mem.Allocator) Error!?SubscriptionEvent {
        const sink = self.event_sink orelse return null;
        helpers.wind_pump_messages();
        if (helpers.wind_event_sink_take_overflow(sink) != 0) return error.EventQueueOverflow;

        while (true) {
            var raw: win.SubscriptionEventRaw = undefined;
            if (helpers.wind_event_sink_pop(sink, &raw) == 0) return null;
            if (raw.state == 4) continue; // Trade notifications are intentionally outside this package's scope.
            if (raw.error_code != 0) return .{
                .request_id = raw.request_id,
                .state = raw.state,
                .error_code = raw.error_code,
                .data = null,
            };
            if (raw.state != 1) return .{
                .request_id = raw.request_id,
                .state = raw.state,
                .error_code = 0,
                .data = null,
            };
            return .{
                .request_id = raw.request_id,
                .state = raw.state,
                .error_code = 0,
                .data = try self.readData(allocator, raw.request_id),
            };
        }
    }

    fn subscribe(self: *Wind, method: []const u8, codes: []const u8, fields: []const u8, options: []const u8) Error!SubscriptionStart {
        try self.ensureEventSink();
        const realtime_options = try withRealtimeOption(options);
        defer std.heap.page_allocator.free(realtime_options);
        return self.startSubscription(method, &.{ codes, fields, realtime_options });
    }

    fn subscribeWithoutFields(self: *Wind, method: []const u8, codes: []const u8, options: []const u8) Error!SubscriptionStart {
        try self.ensureEventSink();
        const realtime_options = try withRealtimeOption(options);
        defer std.heap.page_allocator.free(realtime_options);
        return self.startSubscription(method, &.{ codes, realtime_options });
    }

    fn startSubscription(self: *Wind, method: []const u8, inputs: []const []const u8) Error!SubscriptionStart {
        var error_code: win.LONG = 0;
        var error_ref: win.VARIANT = undefined;
        helpers.wind_variant_init(&error_ref);
        defer clearVariant(&error_ref);
        helpers.wind_variant_set_i4_ref(&error_ref, &error_code);

        var args = try std.heap.page_allocator.alloc(win.VARIANT, inputs.len + 1);
        defer std.heap.page_allocator.free(args);
        for (args) |*arg| helpers.wind_variant_init(arg);
        args[0] = error_ref;
        for (inputs, 0..) |input, index| try setStringVariant(&args[inputs.len - index], input);

        var result: win.VARIANT = undefined;
        helpers.wind_variant_init(&result);
        defer clearVariant(&result);
        try self.invokeNamed(method, args, &result);
        if (error_code != 0) return .{ .error_code = error_code, .subscription = null };

        const request_id: u64 = switch (helpers.wind_variant_type(&result) & win.VT_TYPEMASK) {
            win.VT_I8 => @bitCast(helpers.wind_variant_i8(&result)),
            win.VT_UI8 => @bitCast(helpers.wind_variant_i8(&result)),
            win.VT_I4 => @intCast(helpers.wind_variant_i4(&result)),
            else => return error.UnexpectedSubscriptionResult,
        };
        return .{ .error_code = 0, .subscription = .{
            .wind = self,
            .request_id = request_id,
        } };
    }

    fn ensureEventSink(self: *Wind) Error!void {
        if (self.event_sink != null) return;
        var enabled: win.VARIANT = undefined;
        var result: win.VARIANT = undefined;
        helpers.wind_variant_init(&enabled);
        helpers.wind_variant_init(&result);
        defer clearVariant(&enabled);
        defer clearVariant(&result);
        helpers.wind_variant_set_i4(&enabled, 1);
        try self.invokeNamed("enableAsyn", &.{enabled}, &result);

        const dispatch = self.dispatch orelse return error.WindClassUnavailable;
        var sink: ?*anyopaque = null;
        if (helpers.wind_event_sink_create(dispatch, &sink) < 0 or sink == null) return error.EventSinkUnavailable;
        self.event_sink = sink;
    }

    fn readData(self: *Wind, allocator: std.mem.Allocator, request_id: u64) Error!Data {
        var codes: win.VARIANT = undefined;
        var fields: win.VARIANT = undefined;
        var times: win.VARIANT = undefined;
        var request_state: win.LONG = 0;
        var error_code: win.LONG = 0;
        helpers.wind_variant_init(&codes);
        helpers.wind_variant_init(&fields);
        helpers.wind_variant_init(&times);
        defer clearVariant(&codes);
        defer clearVariant(&fields);
        defer clearVariant(&times);

        var args: [6]win.VARIANT = undefined;
        for (&args) |*arg| helpers.wind_variant_init(arg);
        defer for (&args) |*arg| clearVariant(arg);
        helpers.wind_variant_set_i4_ref(&args[0], &error_code);
        helpers.wind_variant_set_i4_ref(&args[1], &request_state);
        helpers.wind_variant_set_variant_ref(&args[2], &times);
        helpers.wind_variant_set_variant_ref(&args[3], &fields);
        helpers.wind_variant_set_variant_ref(&args[4], &codes);
        helpers.wind_variant_set_i8(&args[5], @bitCast(request_id));

        var result: win.VARIANT = undefined;
        helpers.wind_variant_init(&result);
        defer clearVariant(&result);
        try self.invokeNamed("readdata", args[0..], &result);
        return copyData(allocator, error_code, &codes, &fields, &times, &result);
    }

    fn queryDataWithInteger(self: *Wind, allocator: std.mem.Allocator, method: []const u8, string_inputs: []const []const u8, integer: i32, options: []const u8) Error!Data {
        var inputs = try std.heap.page_allocator.alloc(win.VARIANT, string_inputs.len + 2);
        defer std.heap.page_allocator.free(inputs);
        for (inputs) |*input| helpers.wind_variant_init(input);
        defer for (inputs) |*input| clearVariant(input);
        for (string_inputs, 0..) |input, index| try setStringVariant(&inputs[index], input);
        helpers.wind_variant_set_i4(&inputs[string_inputs.len], integer);
        try setStringVariant(&inputs[string_inputs.len + 1], options);
        return self.queryDataVariants(allocator, method, inputs);
    }

    fn queryData(self: *Wind, allocator: std.mem.Allocator, method: []const u8, inputs: []const []const u8) Error!Data {
        var args = try std.heap.page_allocator.alloc(win.VARIANT, inputs.len);
        defer std.heap.page_allocator.free(args);
        for (args) |*arg| helpers.wind_variant_init(arg);
        defer for (args) |*arg| clearVariant(arg);
        for (inputs, 0..) |input, index| try setStringVariant(&args[index], input);
        return self.queryDataVariants(allocator, method, args);
    }

    fn queryDataVariants(self: *Wind, allocator: std.mem.Allocator, method: []const u8, inputs: []const win.VARIANT) Error!Data {
        var codes: win.VARIANT = undefined;
        var fields: win.VARIANT = undefined;
        var times: win.VARIANT = undefined;
        var error_code: win.LONG = 0;
        helpers.wind_variant_init(&codes);
        helpers.wind_variant_init(&fields);
        helpers.wind_variant_init(&times);
        defer clearVariant(&codes);
        defer clearVariant(&fields);
        defer clearVariant(&times);

        var args = try std.heap.page_allocator.alloc(win.VARIANT, inputs.len + 4);
        defer std.heap.page_allocator.free(args);
        for (args) |*arg| helpers.wind_variant_init(arg);
        helpers.wind_variant_set_i4_ref(&args[0], &error_code);
        helpers.wind_variant_set_variant_ref(&args[1], &times);
        helpers.wind_variant_set_variant_ref(&args[2], &fields);
        helpers.wind_variant_set_variant_ref(&args[3], &codes);
        for (inputs, 0..) |input, index| args[4 + inputs.len - 1 - index] = input;

        var result: win.VARIANT = undefined;
        helpers.wind_variant_init(&result);
        defer clearVariant(&result);
        try self.invokeNamed(method, args, &result);
        return copyData(allocator, error_code, &codes, &fields, &times, &result);
    }

    fn invokeNamed(self: *Wind, method: []const u8, args: []const win.VARIANT, result: *win.VARIANT) Error!void {
        const member = try self.memberId(method);
        const dispatch = self.dispatch orelse return error.WindClassUnavailable;
        if (helpers.wind_dispatch_invoke(dispatch, member, if (args.len == 0) null else @constCast(args.ptr), @intCast(args.len), result) < 0) {
            return error.AutomationCallFailed;
        }
    }

    fn memberId(self: *Wind, method: []const u8) Error!win.DISPID {
        const dispatch = self.dispatch orelse return error.WindClassUnavailable;
        const name = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, method) catch return error.InvalidUtf8;
        defer std.heap.page_allocator.free(name);
        var member: win.DISPID = undefined;
        if (helpers.wind_dispatch_get_id(dispatch, name.ptr, &member) < 0) return error.UnknownAutomationMethod;
        return member;
    }
};

fn resultCode(result: *const win.VARIANT) Error!i32 {
    if ((helpers.wind_variant_type(result) & win.VT_TYPEMASK) != win.VT_I4) return error.UnexpectedVariant;
    return helpers.wind_variant_i4(result);
}

fn setStringVariant(destination: *win.VARIANT, text: []const u8) Error!void {
    const utf16 = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, text) catch return error.InvalidUtf8;
    defer std.heap.page_allocator.free(utf16);
    helpers.wind_variant_set_bstr(destination, utf16.ptr);
    if (helpers.wind_variant_bstr(destination) == null and text.len != 0) return error.OutOfMemory;
}

fn withRealtimeOption(options: []const u8) Error![]u8 {
    return std.fmt.allocPrint(std.heap.page_allocator, "{s};REALTIME=Y", .{options}) catch return error.OutOfMemory;
}

fn clearVariant(variant: *win.VARIANT) void {
    helpers.wind_variant_clear(variant);
}

fn copyData(allocator: std.mem.Allocator, error_code: win.LONG, codes: *const win.VARIANT, fields: *const win.VARIANT, times: *const win.VARIANT, values: *const win.VARIANT) Error!Data {
    var result = Data{
        .allocator = allocator,
        .error_code = error_code,
        .codes = &.{},
        .fields = &.{},
        .times = &.{},
        .values = &.{},
    };
    errdefer result.deinit();

    result.codes = try copyStringArray(allocator, codes);
    result.fields = try copyStringArray(allocator, fields);
    result.times = try copyNumberArray(allocator, times);
    result.values = try copyValueArray(allocator, values);
    return result;
}

fn copyStringArray(allocator: std.mem.Allocator, source: *const win.VARIANT) Error![][]u8 {
    const count: usize = @intCast(helpers.wind_variant_array_count(source));
    const result = try allocator.alloc([]u8, count);
    errdefer freeStrings(allocator, result);
    for (result, 0..) |*destination, index| {
        var item: win.VARIANT = undefined;
        helpers.wind_variant_init(&item);
        defer clearVariant(&item);
        if (helpers.wind_variant_array_element(source, @intCast(index), &item) < 0) return error.UnexpectedVariant;
        if ((helpers.wind_variant_type(&item) & win.VT_TYPEMASK) != win.VT_BSTR) return error.UnexpectedVariant;
        destination.* = try bstrToUtf8(allocator, helpers.wind_variant_bstr(&item));
    }
    return result;
}

fn copyNumberArray(allocator: std.mem.Allocator, source: *const win.VARIANT) Error![]f64 {
    const count: usize = @intCast(helpers.wind_variant_array_count(source));
    const result = try allocator.alloc(f64, count);
    errdefer allocator.free(result);
    for (result, 0..) |*destination, index| {
        var item: win.VARIANT = undefined;
        helpers.wind_variant_init(&item);
        defer clearVariant(&item);
        if (helpers.wind_variant_array_element(source, @intCast(index), &item) < 0) return error.UnexpectedVariant;
        destination.* = windDateSerialToOleDate(switch (helpers.wind_variant_type(&item) & win.VT_TYPEMASK) {
            win.VT_DATE => helpers.wind_variant_date(&item),
            win.VT_R8 => helpers.wind_variant_r8(&item),
            else => return error.UnexpectedVariant,
        });
    }
    return result;
}

fn windDateSerialToOleDate(serial: f64) f64 {
    // Wind returns days since 0001-01-01; OLE Automation dates start at 1899-12-30.
    return serial - 693_960.0;
}

fn copyValueArray(allocator: std.mem.Allocator, source: *const win.VARIANT) Error![]Value {
    const count: usize = @intCast(helpers.wind_variant_array_count(source));
    var result = try allocator.alloc(Value, count);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |*value| value.deinit(allocator);
        allocator.free(result);
    }
    for (result, 0..) |*destination, index| {
        var item: win.VARIANT = undefined;
        helpers.wind_variant_init(&item);
        defer clearVariant(&item);
        if (helpers.wind_variant_array_element(source, @intCast(index), &item) < 0) return error.UnexpectedVariant;
        destination.* = try copyValue(allocator, &item);
        initialized += 1;
    }
    return result;
}

fn copyValue(allocator: std.mem.Allocator, source: *const win.VARIANT) Error!Value {
    return switch (helpers.wind_variant_type(source) & win.VT_TYPEMASK) {
        win.VT_EMPTY, win.VT_NULL => .empty,
        win.VT_BSTR => .{ .string = try bstrToUtf8(allocator, helpers.wind_variant_bstr(source)) },
        win.VT_I4 => .{ .integer = helpers.wind_variant_i4(source) },
        win.VT_I8 => .{ .integer64 = helpers.wind_variant_i8(source) },
        win.VT_R4 => .{ .float = helpers.wind_variant_r4(source) },
        win.VT_R8 => .{ .number = helpers.wind_variant_r8(source) },
        win.VT_BOOL => .{ .boolean = helpers.wind_variant_bool(source) != 0 },
        win.VT_DATE => .{ .date = helpers.wind_variant_date(source) },
        else => error.UnexpectedVariant,
    };
}

fn bstrToUtf8(allocator: std.mem.Allocator, value: win.BSTR) Error![]u8 {
    const bstr = value orelse return try allocator.dupe(u8, "");
    const length: usize = @intCast(helpers.wind_bstr_len(bstr));
    return std.unicode.utf16LeToUtf8Alloc(allocator, bstr[0..length]) catch return error.InvalidUtf8;
}

fn freeStrings(allocator: std.mem.Allocator, values: [][]u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

test "COM class id matches the packaged Wind type library" {
    const expected = std.os.windows.GUID.parse("{3f16f4ab-ce92-4848-9644-39e67c6e1cce}");
    var actual: win.CLSID = undefined;
    helpers.wind_get_clsid(&actual);
    try std.testing.expectEqual(expected.Data1, actual.Data1);
    try std.testing.expectEqual(expected.Data2, actual.Data2);
    try std.testing.expectEqual(expected.Data3, actual.Data3);
    try std.testing.expectEqualSlices(u8, expected.Data4[0..], actual.Data4[0..]);
}

test "resultCode reads a VT_I4 result" {
    var result: win.VARIANT = undefined;
    helpers.wind_variant_set_i4(&result, 42);
    defer clearVariant(&result);
    try std.testing.expectEqual(@as(i32, 42), try resultCode(&result));
}

test "Data.valueAt follows time-code-field layout" {
    const allocator = std.testing.allocator;
    var data = Data{
        .allocator = allocator,
        .error_code = 0,
        .codes = try allocator.dupe([]u8, &.{
            try allocator.dupe(u8, "000001.SZ"),
            try allocator.dupe(u8, "000002.SZ"),
        }),
        .fields = try allocator.dupe([]u8, &.{
            try allocator.dupe(u8, "open"),
            try allocator.dupe(u8, "close"),
        }),
        .times = try allocator.dupe(f64, &.{ 45293.0, 45294.0 }),
        .values = try allocator.dupe(Value, &.{
            .{ .integer = 0 }, .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 },
            .{ .integer = 4 }, .{ .integer = 5 }, .{ .integer = 6 }, .{ .integer = 7 },
        }),
    };
    defer data.deinit();

    try std.testing.expectEqual(Value{ .integer = 6 }, try data.valueAt(1, 1, 0));
    try std.testing.expectError(error.InvalidDataLayout, data.valueAt(2, 0, 0));
}
