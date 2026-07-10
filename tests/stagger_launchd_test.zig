const std = @import("std");
const builtin = @import("builtin");
const launchd = @import("codex_auth").stagger.launchd;

fn userHome() []const u8 {
    return if (builtin.os.tag == .windows) "C:\\Users\\ada" else "/Users/ada";
}

fn schedulerPath(allocator: std.mem.Allocator, segments: []const []const u8) ![]u8 {
    return std.fs.path.join(allocator, segments);
}

test "LaunchAgent paths use the supplied user home" {
    const allocator = std.testing.allocator;
    const home = userHome();
    const paths = try launchd.paths(allocator, home);
    defer paths.deinit(std.testing.allocator);

    const plist = try schedulerPath(allocator, &.{ home, "Library", "LaunchAgents", "com.loongphy.codex-auth.stagger.plist" });
    defer allocator.free(plist);
    const stdout_log = try schedulerPath(allocator, &.{ home, "Library", "Logs", "codex-auth-stagger.log" });
    defer allocator.free(stdout_log);
    const stderr_log = try schedulerPath(allocator, &.{ home, "Library", "Logs", "codex-auth-stagger-error.log" });
    defer allocator.free(stderr_log);

    try std.testing.expectEqualStrings(plist, paths.plist);
    try std.testing.expectEqualStrings(stdout_log, paths.stdout_log);
    try std.testing.expectEqualStrings(stderr_log, paths.stderr_log);
}

test "LaunchAgent plist renders escaped scheduler inputs" {
    const allocator = std.testing.allocator;
    const home = if (builtin.os.tag == .windows) "C:\\Users\\Ada & Bob" else "/Users/Ada & Bob";
    const codex_home = try schedulerPath(allocator, &.{ home, ".codex<stagger>" });
    defer allocator.free(codex_home);
    const rendered = try launchd.render(std.testing.allocator, .{
        .home = home,
        .codex_home = codex_home,
        .path = "/opt/codex&bin:/usr/bin",
        .executable = if (builtin.os.tag == .windows) "C:\\Applications\\Codex Auth & Tools\\codex-auth.exe" else "/Applications/Codex Auth & Tools/codex-auth",
    });
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>") != null);
    const expected_executable = if (builtin.os.tag == .windows) "<string>C:\\Applications\\Codex Auth &amp; Tools\\codex-auth.exe</string>" else "<string>/Applications/Codex Auth &amp; Tools/codex-auth</string>";
    try std.testing.expect(std.mem.indexOf(u8, rendered, expected_executable) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "<string>stagger</string>\n    <string>tick</string>") != null);
    const expected_codex_home_element = if (builtin.os.tag == .windows) "<string>C:\\Users\\Ada &amp; Bob\\.codex&lt;stagger&gt;</string>" else "<string>/Users/Ada &amp; Bob/.codex&lt;stagger&gt;</string>";
    try std.testing.expect(std.mem.indexOf(u8, rendered, expected_codex_home_element) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "<string>/opt/codex&amp;bin:/usr/bin</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "<integer>300</integer>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "<string>Background</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "<integer>60</integer>") != null);
    const expected_stdout_log = if (builtin.os.tag == .windows) "<string>C:\\Users\\Ada &amp; Bob\\Library\\Logs\\codex-auth-stagger.log</string>" else "<string>/Users/Ada &amp; Bob/Library/Logs/codex-auth-stagger.log</string>";
    try std.testing.expect(std.mem.indexOf(u8, rendered, expected_stdout_log) != null);
}

test "LaunchAgent renderer rejects a relative executable" {
    try std.testing.expectError(error.ExecutablePathNotAbsolute, launchd.render(std.testing.allocator, .{
        .home = "/Users/ada",
        .codex_home = "/Users/ada/.codex",
        .path = "/usr/bin",
        .executable = "codex-auth",
    }));
}

test "launchctl plans target the invoking user's service domain" {
    const allocator = std.testing.allocator;
    const plist = "/Users/ada/Library/LaunchAgents/com.loongphy.codex-auth.stagger.plist";

    var bootstrap = try launchd.commandPlan(allocator, .bootstrap, 501, plist);
    defer bootstrap.deinit(allocator);
    try std.testing.expectEqualStrings("launchctl", bootstrap.argv[0]);
    try std.testing.expectEqualStrings("bootstrap", bootstrap.argv[1]);
    try std.testing.expectEqualStrings("gui/501", bootstrap.argv[2]);
    try std.testing.expectEqualStrings(plist, bootstrap.argv[3]);

    var bootout = try launchd.commandPlan(allocator, .bootout, 501, plist);
    defer bootout.deinit(allocator);
    try std.testing.expectEqualStrings("bootout", bootout.argv[1]);
    try std.testing.expectEqualStrings("gui/501/com.loongphy.codex-auth.stagger", bootout.argv[2]);

    var print = try launchd.commandPlan(allocator, .print, 501, plist);
    defer print.deinit(allocator);
    try std.testing.expectEqualStrings("print", print.argv[1]);
    try std.testing.expectEqualStrings("gui/501/com.loongphy.codex-auth.stagger", print.argv[2]);
}

test "launchctl print only treats explicit service-not-found output as unloaded" {
    try std.testing.expect(launchd.printReportsServiceNotFound("Could not find service \"com.loongphy.codex-auth.stagger\" in domain for user gui: 501"));
    try std.testing.expect(launchd.printReportsServiceNotFound("service not found"));
    try std.testing.expect(!launchd.printReportsServiceNotFound("Operation not permitted"));
    try std.testing.expect(!launchd.printReportsServiceNotFound("launchctl: malformed response"));
}
