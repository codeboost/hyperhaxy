const std = @import("std");
const haxy = @import("haxy");
const ui = haxy.ui;
const html = @import("html.zig");
const icons = @import("icons.zig");
const repo_page = @import("pages/repo.zig");
const Ctx = html.Ctx;
const esc = html.esc;
const site_name = @import("frontend.zig").frontend.site_name;

// the site header, up to the opening of the page's main content
pub fn header(c: Ctx, page: *const ui.Page) !void {
    try c.w.writeAll("<header class=\"site-header\"><div class=\"container\"><div class=\"header-row\">");
    try c.w.print("<a href=\"{s}\" class=\"logo\" aria-label=\"{s} home\"><span class=\"logo-mark\">{s}</span><span class=\"logo-text\">{s}</span></a>", .{ try html.url(c, .home_about), site_name, icons.git_branch, site_name });

    const in_repo = switch (page.*) {
        .repo => |*repo| blk: {
            const owner = repo.header.owner_name;
            const identity = if (owner.len == 0) "" else try c.arena.allocator().print("{s}:{s}", .{ owner, repo.header.name });
            const home = try html.routeUrl(c, ui.RoutablePage.repoFilesRoute(identity, null, "", "", 0));
            try breadcrumb(c, owner, repo.header.name, home, c.server() and repo.repo.event.read_access == .private, false);
            break :blk true;
        },
        .fork => |*fork| blk: {
            const identity = try c.arena.allocator().print("{s}:{s}", .{ fork.header.forker_name, fork.header.name });
            const home = try html.routeUrl(c, ui.RoutablePage.forkPatchRoute(identity, fork.header.id));
            try breadcrumb(c, fork.header.forker_name, fork.header.name, home, false, true);
            break :blk true;
        },
        else => blk: {
            try c.w.writeAll("<nav aria-label=\"Main\" class=\"nav nav-main\">");
            try navItem(c, try html.url(c, .home_about), "Home", c.session.current_page == .home_about);
            if (c.server()) try navItem(c, try html.url(c, .{ .home_users = .{} }), "Users", c.session.current_page == .home_users);
            try c.w.writeAll("</nav>");
            break :blk false;
        },
    };

    try c.w.writeAll("<div class=\"header-end\">");
    if (c.server()) {
        // inside a repo the header names it, so users stays one click away
        if (in_repo) {
            try c.w.writeAll("<nav aria-label=\"Main\" class=\"nav\">");
            try navItem(c, try html.url(c, .{ .home_users = .{} }), "Users", false);
            try c.w.writeAll("</nav>");
        }
        if (c.loggedIn()) try viewerMenu(c) else try c.w.print(
            \\<a href="{s}" class="btn btn-ghost btn-sm">{s}Register</a><a href="{s}" class="btn btn-outline btn-sm">{s}Log in</a>
        , .{ try html.url(c, .home_user_new), icons.user_plus, try html.url(c, .{ .home_user = .{} }), icons.log_in });
    }
    try c.w.writeAll("</div></div>");
    if (page.* == .repo) try repo_page.tabs(c, &page.repo);
    try c.w.print("</div></header>\n<main class=\"container main{s}\">\n", .{if (page.* == .repo) " main-tabs" else ""});
}

fn navItem(c: Ctx, href: []const u8, label: []const u8, current: bool) !void {
    try c.w.print("<a href=\"{s}\" class=\"nav-item\"{s}>{s}</a>", .{ href, if (current) " aria-current=\"page\"" else "", label });
}

// `/ owner / name`, the open repo or fork
fn breadcrumb(c: Ctx, owner: []const u8, name: []const u8, home: []const u8, private: bool, is_fork: bool) !void {
    try c.w.writeAll("<p class=\"breadcrumb\"><span aria-hidden=\"true\" class=\"muted\">/</span>");
    if (owner.len != 0) try c.w.print(
        "<a href=\"{f}\" class=\"crumb crumb-owner\">{f}</a><span aria-hidden=\"true\" class=\"muted\">/</span>",
        .{ esc(try html.userUrl(c, owner)), esc(owner) },
    );
    try c.w.print("<a href=\"{f}\" class=\"crumb crumb-name\">{f}</a>", .{ esc(home), esc(name) });
    if (private) try c.w.print("<span class=\"pill\">{s}Private</span>", .{icons.lock});
    if (is_fork) try c.w.print("<span class=\"pill\">{s}Fork</span>", .{icons.git_fork});
    try c.w.writeAll("</p>");
}

// the bell, the new repo button and the user menu of a logged-in viewer
fn viewerMenu(c: Ctx) !void {
    const name = c.session.user_name orelse unreachable;
    const unread = c.session.unread_notifs;
    const bell_label = if (unread == 0) "Notifications" else try c.arena.allocator().print("Notifications, {d} unread", .{unread});
    const user_url = try html.url(c, .{ .home_user = .{} });
    try c.w.print("<a href=\"{s}\" class=\"btn btn-ghost btn-sm\" aria-label=\"{s}\" title=\"{s}\">{s}", .{ user_url, bell_label, bell_label, icons.bell });
    if (unread > 99)
        try c.w.writeAll("<span class=\"badge\">99+</span>")
    else if (unread > 0)
        try c.w.print("<span class=\"badge\">{d}</span>", .{unread});
    try c.w.writeAll("</a>");

    try c.w.print(
        \\<a href="{s}" class="btn btn-ghost btn-sm btn-icon" aria-label="New repository" title="New repository">{s}</a>
    , .{ try html.url(c, .home_repo_new), icons.plus });
    try c.w.print(
        \\<details class="menu"><summary class="btn btn-ghost btn-sm"><span class="avatar" aria-hidden="true">{f}</span><span class="menu-name"><span class="sr-only">Signed in as </span>{f}</span><span class="muted">{s}</span></summary>
        \\<div class="menu-popover">
        \\<a class="menu-item" href="{s}">{s}Account</a>
        \\<a class="menu-item" href="{s}">{s}SSH keys</a>
        \\<a class="menu-item" href="{f}">{s}Your repositories</a>
        \\<div class="menu-sep"></div>
        \\<form method="post" action="{s}/logout"><button type="submit" class="menu-item">{s}Log out</button></form>
        \\</div></details>
    , .{
        esc(if (name.len == 0) "?" else name[0..1]),
        esc(name),
        icons.chevron_down,
        try html.url(c, .{ .home_user = .{ .view = .settings } }),
        icons.user_round,
        try html.url(c, .{ .home_user = .{ .view = .keys } }),
        icons.key_round,
        esc(try html.userUrl(c, name)),
        icons.folder_git_2,
        user_url,
        icons.log_out,
    });
}
