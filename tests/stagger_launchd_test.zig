const std = @import("std");
const launchd = @import("codex_auth").stagger.launchd;

test "LaunchAgent paths use the supplied user home" {
    const paths = try launchd.paths(std.testing.allocator, "/Users/ada");
    defer paths.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("/Users/ada/Library/LaunchAgents/com.loongphy.codex-auth.stagger.plist", paths.plist);
    try std.testing.expectEqualStrings("/Users/ada/Library/Logs/codex-auth-stagger.log", paths.stdout_log);
    try std.testing.expectEqualStrings("/Users/ada/Library/Logs/codex-auth-stagger-error.log", paths.stderr_log);
}

test "LaunchAgent plist renders escaped scheduler inputs" {
    const rendered = try launchd.render(std.testing.allocator, .{
        .home = "/Users/Ada & Bob",
        .codex_home = "/Users/Ada & Bob/.codex<stagger>",
        .path = "/opt/codex&bin:/usr/bin",
        .executable = "/Applications/Codex Auth & Tools/codex-auth",
    });
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "<string>/Applications/Codex Auth &amp; Tools/codex-auth</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "<string>stagger</string>\n    <string>tick</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "<string>/Users/Ada &amp; Bob/.codex&lt;stagger&gt;</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "<string>/opt/codex&amp;bin:/usr/bin</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "<integer>300</integer>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "<string>Background</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "<integer>60</integer>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "<string>/Users/Ada &amp; Bob/Library/Logs/codex-auth-stagger.log</string>") != null);
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
