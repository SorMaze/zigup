//! Single-line transfer progress for interactive terminals.
//!
//! Rendering is best-effort: it never fails a download, never writes to a
//! redirected stream, and never prints a download URL or proxy endpoint.
//! Sizes come from the caller (the Zig release index publishes an exact
//! `size` per asset), so no extra request is needed just to render a bar.

const std = @import("std");
const Io = std.Io;

pub const env_name = "ZIGUP_NO_PROGRESS";
pub const bar_width = 24;
const mib: u128 = 1024 * 1024;

pub const Options = struct {
    /// Expected payload size in bytes; zero renders an indeterminate line.
    total: u64 = 0,
};

/// True when a progress line may be drawn for this process.
pub fn allowed(io: Io, environ: *const std.process.Environ.Map) bool {
    if (!allowedByEnvironment(environ)) return false;
    return Io.File.stdout().isTty(io) catch false;
}

/// `ZIGUP_NO_PROGRESS` disables rendering unless it is empty or explicitly
/// set to a false-like value, so build logs and CI stay quiet by default.
pub fn allowedByEnvironment(environ: *const std.process.Environ.Map) bool {
    const raw = environ.get(env_name) orelse return true;
    const value = std.mem.trim(u8, raw, " \t");
    if (value.len == 0) return true;
    for ([_][]const u8{ "0", "false", "no", "off" }) |disabled_on| {
        if (std.ascii.eqlIgnoreCase(value, disabled_on)) return true;
    }
    return false;
}

/// Renders one progress line without a trailing newline.
pub fn render(buffer: []u8, written: u64, total: u64, elapsed_ns: i96) std.fmt.BufPrintError![]const u8 {
    const elapsed: u128 = @intCast(@max(elapsed_ns, 1));
    const done_tenths = (@as(u128, written) * 10) / mib;
    const rate_tenths = (@as(u128, written) * 10 * std.time.ns_per_s) / (mib * elapsed);
    if (total == 0) {
        return std.fmt.bufPrint(buffer, "  {d}.{d} MiB  {d}.{d} MiB/s", .{
            done_tenths / 10, done_tenths % 10,
            rate_tenths / 10, rate_tenths % 10,
        });
    }
    const percent: u64 = if (written >= total) 100 else (written * 100) / total;
    var bar: [bar_width]u8 = @splat('-');
    fillBar(&bar, percent);
    const total_tenths = (@as(u128, total) * 10) / mib;
    return std.fmt.bufPrint(buffer, "{d:>3}% [{s}] {d}.{d}/{d}.{d} MiB {d}.{d} MiB/s", .{
        percent,
        bar,
        done_tenths / 10,
        done_tenths % 10,
        total_tenths / 10,
        total_tenths % 10,
        rate_tenths / 10,
        rate_tenths % 10,
    });
}

fn fillBar(bar: *[bar_width]u8, percent: u64) void {
    const filled: usize = @intCast((percent * bar_width) / 100);
    for (bar, 0..) |*cell, index| {
        cell.* = if (index < filled) '=' else if (index == filled and percent < 100) '>' else '-';
    }
}

/// Redraws the single progress line in place. `drawn` carries the width of the
/// previous frame so a shorter line can erase the leftover characters.
pub fn draw(
    writer: *Io.Writer,
    buffer: []u8,
    written: u64,
    total: u64,
    elapsed_ns: i96,
    drawn: *usize,
) !void {
    const line = try render(buffer, written, total, elapsed_ns);
    var padding: [256]u8 = @splat(' ');
    try writer.writeAll("\r");
    try writer.writeAll(line);
    if (line.len < drawn.*) try writer.writeAll(padding[0 .. drawn.* - line.len]);
    try writer.flush();
    drawn.* = line.len;
}

/// Erases the progress line so the next status message starts on a clean row.
pub fn erase(writer: *Io.Writer, drawn: *usize) void {
    const previous = drawn.*;
    if (previous == 0) return;
    var padding: [256]u8 = @splat(' ');
    writer.writeAll("\r") catch return;
    var remaining = previous;
    while (remaining > 0) {
        const chunk = @min(remaining, padding.len);
        writer.writeAll(padding[0..chunk]) catch return;
        remaining -= chunk;
    }
    writer.writeAll("\r") catch return;
    writer.flush() catch {};
    drawn.* = 0;
}

/// Size of the in-progress transfer file; a missing file reads as zero.
pub fn sizeOf(io: Io, path: []const u8) u64 {
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch return 0;
    return stat.size;
}

test "progress renders percentage, transfer size and rate" {
    var buffer: [192]u8 = undefined;
    const line = try render(&buffer, 10 * 1024 * 1024, 20 * 1024 * 1024, 2 * std.time.ns_per_s);
    try std.testing.expectEqualStrings(
        " 50% [============>-----------] 10.0/20.0 MiB 5.0 MiB/s",
        line,
    );
}

test "progress renders a complete bar only after the last byte" {
    var buffer: [192]u8 = undefined;
    const line = try render(&buffer, 20 * 1024 * 1024, 20 * 1024 * 1024, 4 * std.time.ns_per_s);
    try std.testing.expectEqualStrings(
        "100% [========================] 20.0/20.0 MiB 5.0 MiB/s",
        line,
    );
    const nearly = try render(&buffer, 20 * 1024 * 1024 - 1, 20 * 1024 * 1024, 4 * std.time.ns_per_s);
    try std.testing.expect(std.mem.startsWith(u8, nearly, " 99% [=======================>"));
}

test "progress stays indeterminate without a known size" {
    var buffer: [192]u8 = undefined;
    const line = try render(&buffer, 3 * 1024 * 1024, 0, std.time.ns_per_s);
    try std.testing.expectEqualStrings("  3.0 MiB  3.0 MiB/s", line);
}

test "progress tolerates a zero clock reading instead of dividing by zero" {
    var buffer: [192]u8 = undefined;
    const line = try render(&buffer, 1024 * 1024, 4 * 1024 * 1024, 0);
    try std.testing.expect(std.mem.startsWith(u8, line, " 25% ["));
    try std.testing.expect(std.mem.indexOf(u8, line, " 1.0/4.0 MiB ") != null);
}

test "progress honours ZIGUP_NO_PROGRESS" {
    const allocator = std.testing.allocator;
    var environ: std.process.Environ.Map = .init(allocator);
    defer environ.deinit();
    try std.testing.expect(allowedByEnvironment(&environ));
    for ([_][]const u8{ "1", "true", "yes", "anything" }) |value| {
        try environ.put(env_name, value);
        try std.testing.expect(!allowedByEnvironment(&environ));
    }
    for ([_][]const u8{ "0", "off", "FALSE", " no " }) |value| {
        try environ.put(env_name, value);
        try std.testing.expect(allowedByEnvironment(&environ));
    }
}
