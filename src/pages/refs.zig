const std = @import("std");
const haxy = @import("haxy");
const ui = haxy.ui;
const html = @import("../html.zig");
const icons = @import("../icons.zig");
const repo = @import("repo.zig");
const Ctx = html.Ctx;
const esc = html.esc;

// the refs tab: the search, then a column each of branches and tags
pub fn panel(c: Ctx, data: *const ui.Repo) !void {
    const refs = &data.refs;
    const id = repo.identity(data);
    try c.w.writeAll("<section aria-labelledby=\"refs-heading\"><h2 id=\"refs-heading\" class=\"sr-only\">Branches and tags</h2>");
    try html.searchForm(c, "refs-search", "Search branches and tags", "Names starting with…", try html.routeUrl(c, ui.RoutablePage.repoRefsRoute(id, .branch, "")), refs.search orelse "");
    const default_branch = try repo.defaultBranch(c, data);
    try c.w.writeAll("<div class=\"ref-columns\">");
    try column(c, id, refs.search, .branch, &refs.branches, default_branch);
    try column(c, id, refs.search, .tag, &refs.tags, null);
    try c.w.writeAll("</div></section>");
}

fn column(c: Ctx, id: []const u8, search: ?[]const u8, kind: ui.RoutablePage.RefKind, data: *const ui.Repo.Refs.Column, default_branch: ?[]const u8) !void {
    const title, const noun, const icon, const ref_or_oid: ui.RoutablePage.RefOrOid = switch (kind) {
        .branch => .{ "Branches", "branches", icons.git_branch, .branch },
        .tag => .{ "Tags", "tags", icons.tag, .tag },
    };
    try c.w.print("<section aria-label=\"{s}\"><h3 class=\"column-title\">{s}{s}</h3>", .{ title, icon, title });
    if (data.names.len == 0) {
        if (data.prev != null) {
            try html.empty(c, try c.arena.allocator().print("No more {s}", .{noun}), "");
        } else if (search) |term| {
            try html.empty(c, try c.arena.allocator().print("No {s} match “{s}”", .{ noun, term }), "Names are matched from their start.");
        } else {
            try html.empty(c, try c.arena.allocator().print("No {s} yet", .{noun}), "");
        }
    } else {
        try c.w.print("<ul aria-label=\"{s}\" class=\"list\">", .{title});
        for (data.names) |name| {
            const href = try html.routeUrl(c, ui.RoutablePage.repoFilesRoute(id, ref_or_oid, try ui.urlEncodeRef(c.arena.allocator(), name), "", 0));
            try c.w.print("<li><a href=\"{f}\" class=\"file-row\"><span class=\"muted\">{s}</span><span class=\"file-name\">{f}</span>", .{ esc(href), icon, esc(name) });
            if (default_branch) |branch| if (std.mem.eql(u8, branch, name)) try c.w.writeAll("<span class=\"pill\">Default</span>");
            try c.w.writeAll("</a></li>");
        }
        try c.w.writeAll("</ul>");
    }
    const previous = if (data.prev) |from| try windowUrl(c, id, kind, from, search) else null;
    const next = if (data.next) |from| try windowUrl(c, id, kind, from, search) else null;
    try html.pager(c, try c.arena.allocator().print("{s} pages", .{title}), previous, next);
    try c.w.writeAll("</section>");
}

// the window of `kind`'s column starting at ref `from` ("" = the first)
fn windowUrl(c: Ctx, id: []const u8, kind: ui.RoutablePage.RefKind, from: []const u8, search: ?[]const u8) ![]const u8 {
    const route = ui.RoutablePage.repoRefsRoute(id, kind, try ui.urlEncodeRef(c.arena.allocator(), from)) orelse return error.RouteTooLong;
    return html.routeUrl(c, route.withSearch(search orelse ""));
}
