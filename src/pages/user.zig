const std = @import("std");
const haxy = @import("haxy");
const ui = haxy.ui;
const evt = haxy.event;
const html = @import("../html.zig");
const icons = @import("../icons.zig");
const Ctx = html.Ctx;
const esc = html.esc;

// a user's page: their repos, then their forks
pub fn profile(c: Ctx, data: *const ui.User) !void {
    const name = data.user.name;
    const name_array = ui.RoutablePage.Array(evt.User.name_max_len).from(name) orelse return error.RouteTooLong;
    const search = data.repos_search orelse "";
    const aa = c.arena.allocator();

    try c.w.print("<h1 class=\"title\">{f}</h1>", .{esc(name)});

    try c.w.writeAll("<section aria-labelledby=\"repos-heading\" class=\"mt-8\"><h2 id=\"repos-heading\" class=\"subtitle mb-4\">Repositories</h2>");
    try html.searchForm(c, "repos-search", "Search repositories", "Names starting with…", try html.url(c, .{ .user_repos = .{ .name = name_array } }), search);
    if (data.repos.len == 0) {
        if (data.repos_start > 0) {
            try html.empty(c, "No more repositories", "");
        } else if (data.repos_search != null) {
            try html.empty(c, try aa.print("No repositories match “{s}”", .{search}), "Names are matched from their start.");
        } else {
            try html.empty(c, "No repositories", try aa.print("{s} has no repositories you can see.", .{name}));
        }
    } else {
        try c.w.writeAll("<ul aria-label=\"Repositories\" class=\"list\">");
        for (data.repos) |repo| {
            const identity = try aa.print("{s}:{s}", .{ name, repo.event.name });
            const href = try html.routeUrl(c, ui.RoutablePage.repoFilesRoute(identity, null, "", "", 0));
            try c.w.print("<li class=\"row\"><p class=\"row-head\"><a href=\"{f}\" class=\"link\">{f}</a>", .{ esc(href), esc(repo.event.name) });
            if (repo.event.read_access == .private) try c.w.print("<span class=\"pill\">{s}Private</span>", .{icons.lock});
            try c.w.writeAll("</p>");
            if (repo.event.description.len != 0) try c.w.print("<p class=\"mt-1 text-sm muted\">{f}</p>", .{esc(repo.event.description)});
            try c.w.writeAll("</li>");
        }
        try c.w.writeAll("</ul>");
    }
    {
        const previous = if (data.repos_start > 0) try reposUrl(c, name_array, data.repos_start -| ui.User.page_size, search) else null;
        const next = if (data.repos_next_start) |start| try reposUrl(c, name_array, start, search) else null;
        try html.pager(c, "Repository pages", previous, next);
    }
    try c.w.writeAll("</section>");

    try c.w.writeAll("<section aria-labelledby=\"forks-heading\" class=\"mt-10\"><h2 id=\"forks-heading\" class=\"subtitle\">Forks</h2>");
    if (data.forks.len == 0) {
        if (data.forks_start > 0) {
            try html.empty(c, "No more forks", "");
        } else {
            try html.empty(c, "No forks", try aa.print("{s} has no forks you can see.", .{name}));
        }
    } else {
        try c.w.writeAll("<ul aria-label=\"Forks\" class=\"list\">");
        for (data.forks) |fork| {
            // the fork route names the forker
            const identity = try aa.print("{s}:{s}", .{ name, fork.repo_name });
            const href = try html.routeUrl(c, ui.RoutablePage.forkPatchRoute(identity, fork.id));
            try c.w.print("<li class=\"row\"><p class=\"row-head\"><a href=\"{f}\" class=\"link\">{f}</a>", .{ esc(href), esc(fork.title) });
            if (fork.access) |access| {
                if (access == .private) try c.w.print("<span class=\"pill\">{s}Private</span>", .{icons.lock});
            } else try c.w.writeAll("<span class=\"pill\">Target deleted</span>");
            try c.w.print("</p><p class=\"mt-1 text-sm muted\">A fork of {f}</p></li>", .{esc(fork.repo_name)});
        }
        try c.w.writeAll("</ul>");
    }
    {
        const previous = if (data.forks_start > 0) try html.url(c, .{ .user_forks = .{ .name = name_array, .start = data.forks_start -| ui.User.page_size } }) else null;
        const next = if (data.forks_next_start) |start| try html.url(c, .{ .user_forks = .{ .name = name_array, .start = start } }) else null;
        try html.pager(c, "Fork pages", previous, next);
    }
    try c.w.writeAll("</section>");
}

fn reposUrl(c: Ctx, name: ui.RoutablePage.Array(evt.User.name_max_len), start: usize, search: []const u8) ![]const u8 {
    const route: ui.RoutablePage = .{ .user_repos = .{ .name = name, .start = start } };
    return html.routeUrl(c, route.withSearch(search));
}
