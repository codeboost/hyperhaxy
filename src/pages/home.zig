const std = @import("std");
const haxy = @import("haxy");
const ui = haxy.ui;
const html = @import("../html.zig");
const markdown = @import("../markdown.zig");
const Ctx = html.Ctx;
const esc = html.esc;

// the server's about page, or a welcome when it has none
pub fn about(c: Ctx, data: *const ui.Home.About) !void {
    if (data.title == null and std.mem.trim(u8, data.text, " \t\r\n").len == 0) {
        try c.w.writeAll(
            \\<p class="eyebrow">Your code. Your forge.</p><h1 class="hero">haxy</h1><p class="mt-5 lead muted">A multi-user haxy server.</p>
        );
        if (c.session.user_name) |name| try c.w.print("<p class=\"mt-3 lead muted\">Signed in as <strong class=\"strong\">{f}</strong>.</p>", .{esc(name)});
        return;
    }
    try c.w.print("<article class=\"wide\"><h1 class=\"title mb-6\">{f}</h1>", .{esc(data.title orelse "About")});
    try markdown.render(c, data.text);
    try c.w.writeAll("</article>");
}

pub fn users(c: Ctx, data: *const ui.Home.Users) !void {
    const search = data.search orelse "";
    try c.w.writeAll("<section><h1 class=\"title mb-6\">Users</h1>");
    try html.searchForm(c, "users-search", "Search users", "Names starting with…", try html.url(c, .{ .home_users = .{} }), search);
    if (data.users.len == 0) {
        if (data.start > 0) {
            try html.empty(c, "No more users", "");
        } else if (data.search != null) {
            try html.empty(c, try c.arena.allocator().print("No users match “{s}”", .{search}), "Names are matched from their start.");
        } else {
            try html.empty(c, "No users yet", "Nobody has registered on this server.");
        }
    } else {
        try c.w.writeAll("<ul aria-label=\"Users\" class=\"list\">");
        for (data.users) |user| {
            try c.w.print("<li><a href=\"{f}\" class=\"row-link\">{f}</a></li>", .{ esc(try html.userUrl(c, user.name)), esc(user.name) });
        }
        try c.w.writeAll("</ul>");
    }
    const previous = if (data.start > 0) try usersUrl(c, data.start -| ui.Home.Users.page_size, search) else null;
    const next = if (data.next_start) |start| try usersUrl(c, start, search) else null;
    try html.pager(c, "User pages", previous, next);
    try c.w.writeAll("</section>");
}

fn usersUrl(c: Ctx, start: usize, search: []const u8) ![]const u8 {
    const route: ui.RoutablePage = .{ .home_users = .{ .start = start } };
    return html.routeUrl(c, route.withSearch(search));
}
