const std = @import("std");
const wind = @import("zig_wind");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var api = try wind.Wind.init();
    defer api.deinit();

    const start_code = try api.start(null, null, 5000);
    if (start_code != 0) {
        std.debug.print("Wind start failed: {d}\n", .{start_code});
        return;
    }
    defer _ = api.stop() catch {};

    var result = try api.wsd(
        allocator,
        "000001.SZ",
        "close",
        "2024-01-02",
        "2024-01-10",
        "",
    );
    defer result.deinit();

    if (result.error_code != 0) {
        std.debug.print("Wind API error: {d}\n", .{result.error_code});
        return;
    }

    for (result.times, 0..) |date, time_index| {
        const value = try result.valueAt(time_index, 0, 0);
        std.debug.print("date={d:.0}, close={any}\n", .{ date, value });
    }
}
