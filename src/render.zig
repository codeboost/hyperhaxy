const std = @import("std");
const haxy = @import("haxy");
const ui = haxy.ui;
const html = @import("html.zig");
const layout = @import("layout.zig");
const account = @import("pages/account.zig");
const fork = @import("pages/fork.zig");
const home = @import("pages/home.zig");
const new_repo = @import("pages/new_repo.zig");
const not_found = @import("pages/not_found.zig");
const repo = @import("pages/repo.zig");
const user = @import("pages/user.zig");
const Ctx = html.Ctx;

// haxy's render_html hook: the whole document for one page
pub fn page(allocator: std.mem.Allocator, p: *const ui.Page, session: *const ui.Session.Data, writer: *std.Io.Writer) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const c: Ctx = .{ .w = writer, .arena = &arena, .session = session };
    try layout.begin(c, p, try title(c, p));
    try body(c, p);
    try layout.end(c);
}

fn body(c: Ctx, p: *const ui.Page) !void {
    // every page carries the user, new repo and new user tabs
    const route = c.session.current_page;
    switch (route) {
        .home_user, .user_user, .repo_user, .fork_user => return account.userTab(c, userNotifications(p) orelse return error.UnexpectedPage, route),
        .home_repo_new, .user_repo_new, .repo_repo_new, .fork_repo_new => return new_repo.page(c, route),
        .home_user_new, .user_user_new, .repo_user_new, .fork_user_new => return account.register(c, route),
        else => {},
    }
    switch (p.*) {
        .home => |*data| if (route == .home_users) try home.users(c, &data.users) else try home.about(c, &data.about),
        .user => |*data| try user.profile(c, data),
        .repo => |*data| try repo.page(c, data),
        .fork => |*data| try fork.page(c, data),
        .not_found => try not_found.page(c),
    }
}

fn title(c: Ctx, p: *const ui.Page) ![]const u8 {
    const route = c.session.current_page;
    switch (route) {
        .home_user, .user_user, .repo_user, .fork_user => {
            if (!c.loggedIn()) return "Log in";
            return switch (route.userTab().view) {
                .notifications => "Notifications",
                .settings, .keys, .delete => "Account",
            };
        },
        .home_repo_new, .user_repo_new, .repo_repo_new, .fork_repo_new => return "New repository",
        .home_user_new, .user_user_new, .repo_user_new, .fork_user_new => return "Create an account",
        .home_users => return "Users",
        else => {},
    }
    return switch (p.*) {
        .home => |*data| data.about.title orelse "",
        .user => |*data| data.user.name,
        .repo => |*data| if (data.header.owner_name.len == 0)
            data.header.name
        else
            try c.arena.allocator().print("{s}:{s}", .{ data.header.owner_name, data.header.name }),
        .fork => |*data| try c.arena.allocator().print("{s}:{s}", .{ data.header.forker_name, data.header.name }),
        .not_found => "Page not found",
    };
}

// the page's user tab data
fn userNotifications(p: *const ui.Page) ?*const ui.UserNotifications {
    return switch (p.*) {
        .home => |*data| &data.user_notifications,
        .user => |*data| &data.user_notifications,
        .repo => |*data| &data.user_notifications,
        .fork => |*data| &data.user_notifications,
        .not_found => null,
    };
}
