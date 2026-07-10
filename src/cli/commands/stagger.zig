const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .stagger } };
    }
    if (args.len == 0) return common.usageErrorResult(allocator, .stagger, "`stagger` requires a subcommand.", .{});

    const subcommand = std.mem.sliceTo(args[0], 0);
    if (std.mem.eql(u8, subcommand, "configure")) return parseConfigure(allocator, args[1..]);
    if (std.mem.eql(u8, subcommand, "tick")) return parseTick(allocator, args[1..]);
    if (std.mem.eql(u8, subcommand, "status")) return parseAction(allocator, args[1..], .status);
    if (std.mem.eql(u8, subcommand, "enable")) return parseAction(allocator, args[1..], .enable);
    if (std.mem.eql(u8, subcommand, "disable")) return parseAction(allocator, args[1..], .disable);
    if (std.mem.eql(u8, subcommand, "uninstall")) return parseAction(allocator, args[1..], .uninstall);

    return common.usageErrorResult(allocator, .stagger, "unknown stagger subcommand `{s}`.", .{subcommand});
}

fn parseConfigure(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .stagger } };
    }

    var opts: types.StaggerConfigureOptions = undefined;
    var has_primary = false;
    var has_secondary = false;
    var has_spacing = false;
    var has_weekly_reserve = false;
    defer {
        if (has_primary) allocator.free(opts.primary_selector);
        if (has_secondary) allocator.free(opts.secondary_selector);
    }

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = std.mem.sliceTo(args[index], 0);
        if (std.mem.eql(u8, arg, "--primary")) {
            if (has_primary) return common.usageErrorResult(allocator, .stagger, "duplicate `--primary` for `stagger configure`.", .{});
            const value = nextValue(args, &index) orelse return common.usageErrorResult(allocator, .stagger, "`--primary` requires a selector or value.", .{});
            opts.primary_selector = try allocator.dupe(u8, value);
            has_primary = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--secondary")) {
            if (has_secondary) return common.usageErrorResult(allocator, .stagger, "duplicate `--secondary` for `stagger configure`.", .{});
            const value = nextValue(args, &index) orelse return common.usageErrorResult(allocator, .stagger, "`--secondary` requires a selector or value.", .{});
            opts.secondary_selector = try allocator.dupe(u8, value);
            has_secondary = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--spacing-minutes")) {
            if (has_spacing) return common.usageErrorResult(allocator, .stagger, "duplicate `--spacing-minutes` for `stagger configure`.", .{});
            const raw = nextValue(args, &index) orelse return common.usageErrorResult(allocator, .stagger, "`--spacing-minutes` requires a selector or value.", .{});
            const value = std.fmt.parseInt(u16, raw, 10) catch return common.usageErrorResult(allocator, .stagger, "`--spacing-minutes` must be an integer from 1 to 299.", .{});
            if (value < 1 or value > 299) return common.usageErrorResult(allocator, .stagger, "`--spacing-minutes` must be an integer from 1 to 299.", .{});
            opts.spacing_minutes = value;
            has_spacing = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--weekly-reserve-percent")) {
            if (has_weekly_reserve) return common.usageErrorResult(allocator, .stagger, "duplicate `--weekly-reserve-percent` for `stagger configure`.", .{});
            const raw = nextValue(args, &index) orelse return common.usageErrorResult(allocator, .stagger, "`--weekly-reserve-percent` requires a selector or value.", .{});
            const value = std.fmt.parseInt(u8, raw, 10) catch return common.usageErrorResult(allocator, .stagger, "`--weekly-reserve-percent` must be an integer from 0 to 99.", .{});
            if (value > 99) return common.usageErrorResult(allocator, .stagger, "`--weekly-reserve-percent` must be an integer from 0 to 99.", .{});
            opts.weekly_reserve_percent = value;
            has_weekly_reserve = true;
            continue;
        }
        if (common.isHelpFlag(arg)) return common.usageErrorResult(allocator, .stagger, "`--help` must be used by itself for `stagger configure`.", .{});
        if (std.mem.startsWith(u8, arg, "-")) return common.usageErrorResult(allocator, .stagger, "unknown flag `{s}` for `stagger configure`.", .{arg});
        return common.usageErrorResult(allocator, .stagger, "unexpected argument `{s}` for `stagger configure`.", .{arg});
    }

    if (!has_primary or !has_secondary) {
        return common.usageErrorResult(allocator, .stagger, "`stagger configure` requires `--primary <selector>` and `--secondary <selector>`.", .{});
    }
    if (!has_spacing) opts.spacing_minutes = 150;
    if (!has_weekly_reserve) opts.weekly_reserve_percent = 5;
    has_primary = false;
    has_secondary = false;
    return .{ .command = .{ .stagger = .{ .configure = opts } } };
}

fn parseTick(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .stagger } };
    }

    var opts: types.StaggerTickOptions = .{};
    for (args) |raw_arg| {
        const arg = std.mem.sliceTo(raw_arg, 0);
        if (std.mem.eql(u8, arg, "--dry-run")) {
            if (opts.dry_run) return common.usageErrorResult(allocator, .stagger, "duplicate `--dry-run` for `stagger tick`.", .{});
            opts.dry_run = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--api")) {
            switch (opts.api_mode) {
                .default => opts.api_mode = .force_api,
                .force_api => return common.usageErrorResult(allocator, .stagger, "duplicate `--api` for `stagger tick`.", .{}),
                .skip_api => return common.usageErrorResult(allocator, .stagger, "`--api` cannot be combined with `--skip-api` for `stagger tick`.", .{}),
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--skip-api")) {
            switch (opts.api_mode) {
                .default => opts.api_mode = .skip_api,
                .skip_api => return common.usageErrorResult(allocator, .stagger, "duplicate `--skip-api` for `stagger tick`.", .{}),
                .force_api => return common.usageErrorResult(allocator, .stagger, "`--skip-api` cannot be combined with `--api` for `stagger tick`.", .{}),
            }
            continue;
        }
        if (common.isHelpFlag(arg)) return common.usageErrorResult(allocator, .stagger, "`--help` must be used by itself for `stagger tick`.", .{});
        if (std.mem.startsWith(u8, arg, "-")) return common.usageErrorResult(allocator, .stagger, "unknown flag `{s}` for `stagger tick`.", .{arg});
        return common.usageErrorResult(allocator, .stagger, "unexpected argument `{s}` for `stagger tick`.", .{arg});
    }
    return .{ .command = .{ .stagger = .{ .tick = opts } } };
}

fn parseAction(allocator: std.mem.Allocator, args: []const [:0]const u8, action: types.StaggerAction) !types.ParseResult {
    if (args.len == 0) return .{ .command = .{ .stagger = .{ .action = action } } };
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) return .{ .command = .{ .help = .stagger } };
    const arg = std.mem.sliceTo(args[0], 0);
    if (std.mem.startsWith(u8, arg, "-")) return common.usageErrorResult(allocator, .stagger, "unknown flag `{s}` for `stagger`.", .{arg});
    return common.usageErrorResult(allocator, .stagger, "unexpected argument `{s}` for `stagger`.", .{arg});
}

fn nextValue(args: []const [:0]const u8, index: *usize) ?[]const u8 {
    if (index.* + 1 >= args.len) return null;
    index.* += 1;
    const raw = std.mem.sliceTo(args[index.*], 0);
    if (std.mem.startsWith(u8, raw, "-")) return null;
    return raw;
}
