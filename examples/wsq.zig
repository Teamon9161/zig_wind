const std = @import("std");
const wind = @import("zig_wind");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var api = try wind.Wind.init();
    defer api.deinit();

    if (try api.start(null, null, 5000) != 0) return error.WindStartFailed;
    defer _ = api.stop() catch {};

    const started = try api.subscribeWsq("000001.SZ", "rt_last", "");
    if (started.error_code != 0) {
        std.debug.print("WSQ subscription failed: {d}\n", .{started.error_code});
        return;
    }

    var subscription = started.subscription orelse return error.MissingSubscription;
    defer subscription.deinit();
    std.debug.print("WSQ request ID: {d}\n", .{subscription.request_id});

    // Wind pushes arrive on its own thread; poll() hands them over on this one.
    var attempt: usize = 0;
    while (attempt < 200) : (attempt += 1) {
        if (try api.poll(allocator)) |event_value| {
            var event = event_value;
            defer event.deinit();
            std.debug.print("event state={d}, Wind error={d}\n", .{ event.state, event.error_code });
            if (event.data) |data| {
                std.debug.print("codes={d}, fields={d}, values={d}\n", .{ data.codes.len, data.fields.len, data.values.len });
                if (data.values.len != 0) std.debug.print("first value={any}\n", .{data.values[0]});
            }
            return;
        }
        try io.sleep(.fromMilliseconds(50), .awake);
    }

    std.debug.print("No WSQ update arrived within 10 seconds. Keep polling in a long-lived application.\n", .{});
}
