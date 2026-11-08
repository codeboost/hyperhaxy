const std = @import("std");
const haxy = @import("haxy");
const ui = haxy.ui;
const Commits = ui.Repo.Commits;
const html = @import("../html.zig");
const icons = @import("../icons.zig");
const files = @import("files.zig");
const repo = @import("repo.zig");
const Ctx = html.Ctx;
const esc = html.esc;

const short_oid_len = 10;

const CommitStats = @typeInfo(@FieldType(Commits.Commit, "stats")).optional.child;

// the commits tab: the history at a ref, or one commit's whole message; a fork has no repo_data
pub fn panel(c: Ctx, cm: *const Commits, repo_data: ?*const ui.Repo) !void {
    if (cm.no_commits) return files.noCommits(c, cm.handle, "commits-remote");
    if (cm.message and cm.commits.len > 0) return commitView(c, cm, &cm.commits[0]);

    try refLine(c, cm, repo_data);
    if (c.server() and cm.search_available) {
        try c.w.writeAll("<div class=\"mt-4\">");
        try html.searchForm(c, "commits-search", "Search commits", "Words in commit messages", try html.routeUrl(c, searchRoute(cm)), cm.search orelse "");
        try c.w.writeAll("</div>");
    }
    if (cm.search) |query| try c.w.print(
        "<p role=\"status\" class=\"mt-3 text-sm muted\">Showing commits matching “{f}”. <a href=\"{f}\" class=\"link\">Show the whole history</a></p>",
        .{ esc(query), esc(try html.routeUrl(c, searchRoute(cm))) },
    );
    if (cm.commit_count) |count| try c.w.print("<p class=\"mt-4 text-sm muted\">{d} commit{s}</p>", .{ count, if (count == 1) "" else "s" });

    if (cm.commits.len == 0) {
        if (cm.search) |query| return html.empty(c, try c.arena.allocator().print("No commits match “{s}”", .{query}), "Words match from their start, in any order.");
        return html.empty(c, "No commits", "");
    }
    try c.w.writeAll("<ol aria-label=\"Commits\" class=\"list\">");
    for (cm.commits) |*commit| try row(c, cm, commit);
    try c.w.writeAll("</ol>");
    const next = if (cm.next_start) |oid| try html.routeUrl(c, pageRoute(cm, oid)) else null;
    try html.pager(c, "History pages", null, next);
}

// the list a search narrows: an object view or a base-bounded list searches the default branch
fn searchRoute(cm: *const Commits) ?ui.RoutablePage {
    if (cm.default_branch.len != 0) return cm.handle.location.commitsRoute(.branch, cm.default_branch, "");
    return cm.handle.location.commitsRoute(cm.ref_or_oid, cm.ref_or_oid_value, cm.base_oid);
}

// the page starting at `oid`: a branch or tag keeps its ref and query, an object view roots at the commit
fn pageRoute(cm: *const Commits, oid: []const u8) ?ui.RoutablePage {
    if (cm.handle.location != .repo or cm.ref_or_oid == .object) return cm.handle.location.commitsRoute(.object, oid, cm.base_oid);
    const route = cm.handle.location.commitsRoute(cm.ref_or_oid, cm.ref_or_oid_value, cm.base_oid) orelse return null;
    const paged = route.withFrom(oid) orelse return null;
    return paged.withSearch(cm.search orelse return paged);
}

// which ref the history is read at, and where else to go from it
fn refLine(c: Ctx, cm: *const Commits, repo_data: ?*const ui.Repo) !void {
    const route = c.session.current_page;
    try c.w.writeAll("<section aria-label=\"Ref\" class=\"ref-line\">");
    if (route == .repo_commits and route.repo_commits.merge.len != 0) {
        const merge = route.repo_commits.merge.slice();
        try c.w.print("<span class=\"ref-line-name\"><span class=\"muted\">{s}</span><span>Commits merged in by <code class=\"strong mono\">{f}</code></span></span>", .{ icons.git_merge, esc(short(merge)) });
    } else {
        const kind: []const u8, const icon: []const u8, const name: []const u8 = switch (cm.ref_or_oid) {
            .branch => .{ "Branch", icons.git_branch, try html.decode(c, cm.ref_or_oid_value) },
            .tag => .{ "Tag", icons.tag, try html.decode(c, cm.ref_or_oid_value) },
            .object => .{ "Commit", icons.git_commit_horizontal, short(cm.ref_or_oid_value) },
        };
        try c.w.print("<span class=\"ref-line-name\"><span class=\"muted\">{s}</span><span>{s} <code class=\"strong mono\">{f}</code></span></span>", .{ icon, kind, esc(name) });
    }
    if (cm.base_oid.len != 0) try c.w.print("<span class=\"muted\">back to <code class=\"mono\">{f}</code></span>", .{esc(short(cm.base_oid))});
    try c.w.print("<a href=\"{f}\" class=\"link\">Browse files</a>", .{esc(try html.routeUrl(c, cm.handle.location.filesRoute(cm.ref_or_oid, cm.ref_or_oid_value, "", 0)))});
    if (repo_data) |data| {
        try c.w.print("<a href=\"{f}\" class=\"link\" data-tab=\"panel-refs\">Branches and tags</a>", .{esc(try repo.tabHref(c, data, .refs))});
        if (repo.explicitRef(route)) try c.w.print("<a href=\"{f}\" class=\"link\">Default branch</a>", .{esc(try html.routeUrl(c, ui.RoutablePage.repoCommitsRoute(repo.identity(data), null, "", "")))});
    }
    try c.w.writeAll("</section>");
}

fn row(c: Ctx, cm: *const Commits, commit: *const Commits.Commit) !void {
    const location = cm.handle.location;
    try c.w.print("<li class=\"row\"><div class=\"row-split\"><div class=\"grow\"><p class=\"row-head\"><a href=\"{f}\" class=\"commit-summary\">{f}</a>", .{
        esc(try html.routeUrl(c, location.commitMessageRoute(.object, commit.oid, cm.base_oid))),
        esc(summary(commit.message)),
    });
    if (commit.merge) try mergePill(c);
    try c.w.print("</p><div class=\"row-meta\"><code class=\"mono\">{f}</code>", .{esc(short(commit.oid))});
    try person(c, "by", commit.author);
    if (commit.committer != .unknown) try person(c, "committed by", commit.committer);
    try html.time(c, commit.timestamp);
    try c.w.writeAll("</div>");
    if (commit.stats) |stats| {
        try c.w.writeAll("<p class=\"mt-1 text-xs\">");
        try statsText(c, stats);
        try c.w.writeAll("</p>");
    }
    try c.w.print("</div><div class=\"row-links\"><a href=\"{f}\" class=\"link\">Diff</a><a href=\"{f}\" class=\"link\">Files</a></div></div></li>", .{
        esc(try html.routeUrl(c, location.commitDiffRoute(commit.oid, commit.parent_oid))),
        esc(try html.routeUrl(c, location.filesRoute(.object, commit.oid, "", 0))),
    });
}

// one commit: who and when, its statistics, and its whole message
fn commitView(c: Ctx, cm: *const Commits, commit: *const Commits.Commit) !void {
    const location = cm.handle.location;
    try c.w.print(
        "<article aria-labelledby=\"commit-heading\"><p class=\"text-sm\"><a href=\"{f}\" class=\"link\">Back to the history</a></p><h2 id=\"commit-heading\" class=\"commit-title\">{f}",
        .{ esc(try html.routeUrl(c, location.commitsRoute(.object, commit.oid, cm.base_oid))), esc(summary(commit.message)) },
    );
    if (commit.merge) try mergePill(c);
    try c.w.print("</h2><dl class=\"facts\"><dt>Commit</dt><dd><code class=\"mono\">{f}</code></dd><dt>Author</dt><dd>", .{esc(commit.oid)});
    try html.author(c, commit.author);
    try c.w.writeAll("</dd>");
    if (commit.committer != .unknown) {
        try c.w.writeAll("<dt>Committer</dt><dd>");
        try html.author(c, commit.committer);
        try c.w.writeAll("</dd>");
    }
    try c.w.writeAll("<dt>Committed</dt><dd>");
    try html.time(c, commit.timestamp);
    try c.w.writeAll("</dd><dt>Parent</dt><dd>");
    if (std.mem.allEqual(u8, commit.parent_oid, '0')) {
        try c.w.writeAll("None (a root commit)");
    } else try c.w.print("<a href=\"{f}\" class=\"link mono\">{f}</a>", .{
        esc(try html.routeUrl(c, location.commitMessageRoute(.object, commit.parent_oid, cm.base_oid))),
        esc(short(commit.parent_oid)),
    });
    try c.w.writeAll("</dd>");
    if (commit.stats) |stats| {
        try c.w.writeAll("<dt>Statistics</dt><dd>");
        try statsText(c, stats);
        try c.w.writeAll("</dd>");
    }
    try c.w.print("</dl><p class=\"links mt-4\"><a href=\"{f}\" class=\"link\">View changes</a><a href=\"{f}\" class=\"link\">Browse files at this commit</a>", .{
        esc(try html.routeUrl(c, location.commitDiffRoute(commit.oid, commit.parent_oid))),
        esc(try html.routeUrl(c, location.filesRoute(.object, commit.oid, "", 0))),
    });
    if (commit.merge) if (location.commitsMergeRoute(commit.oid)) |route| {
        try c.w.print("<a href=\"{f}\" class=\"link\">Commits from this merge</a>", .{esc(try html.url(c, route))});
    };
    try c.w.writeAll("</p>");
    if (commit.message_truncated) try c.w.writeAll("<p role=\"status\" class=\"notice mt-4\">This message is longer than haxy reads; only its start is shown.</p>");
    try c.w.print("<pre aria-label=\"Commit message\" class=\"message\">{f}</pre></article>", .{esc(commit.message)});
}

fn mergePill(c: Ctx) !void {
    try c.w.print("<span class=\"pill\">{s}Merge</span>", .{icons.git_merge});
}

fn person(c: Ctx, role: []const u8, value: ui.Author) !void {
    try c.w.print("<span>{s} ", .{role});
    try html.author(c, value);
    try c.w.writeAll("</span>");
}

// the counts that aren't zero, and the byte delta always, as haxy's stats box shows them
fn statsText(c: Ctx, stats: CommitStats) !void {
    const bytes_added = stats.bytes_added >= stats.bytes_removed;
    const bytes = if (bytes_added) stats.bytes_added - stats.bytes_removed else stats.bytes_removed - stats.bytes_added;
    const parts = [_]struct { u64, []const u8, []const u8, bool }{
        .{ stats.lines_added, "line", "added", false },
        .{ stats.lines_changed, "line", "changed", false },
        .{ stats.lines_removed, "line", "removed", false },
        .{ bytes, "byte", if (bytes_added) "added" else "removed", true },
        .{ stats.files_added, "file", "added", false },
        .{ stats.files_changed, "file", "changed", false },
        .{ stats.files_removed, "file", "removed", false },
    };
    var first = true;
    for (parts) |part| {
        const count, const noun, const verb, const always = part;
        if (count == 0 and !always) continue;
        if (!first) try c.w.writeAll(" · ");
        first = false;
        try c.w.print("{d} {s}{s} {s}", .{ count, noun, if (count == 1) "" else "s", verb });
    }
}

// a message's first line
fn summary(message: []const u8) []const u8 {
    const line = if (std.mem.indexOfScalar(u8, message, '\n')) |nl| std.mem.trimEnd(u8, message[0..nl], " \t\r") else message;
    return if (line.len == 0) "(no message)" else line;
}

fn short(oid: []const u8) []const u8 {
    return oid[0..@min(oid.len, short_oid_len)];
}
