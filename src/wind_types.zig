//! Public data types shared by the Windows (COM) and Linux (shared object) backends.

const std = @import("std");

pub const Error = error{
    // Shared
    OutOfMemory,
    InvalidUtf8,
    UnexpectedVariant,
    InvalidDataLayout,
    EventQueueOverflow,
    UnexpectedSubscriptionResult,
    /// The request exists in the Wind API but not on the backend for this platform.
    UnsupportedOnThisPlatform,

    // Windows / COM
    ComInitializationFailed,
    WindClassUnavailable,
    AutomationCallFailed,
    UnknownAutomationMethod,
    EventSinkUnavailable,

    // Linux / shared object
    WindLibraryNotFound,
    WindSymbolMissing,
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

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
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
    /// OLE Automation dates: days since 1899-12-30.
    times: []f64,
    values: []Value,

    pub fn empty(allocator: std.mem.Allocator, error_code: i32) Data {
        return .{
            .allocator = allocator,
            .error_code = error_code,
            .codes = &.{},
            .fields = &.{},
            .times = &.{},
            .values = &.{},
        };
    }

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

pub fn freeStrings(allocator: std.mem.Allocator, values: [][]u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
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
