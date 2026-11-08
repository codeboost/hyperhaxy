const std = @import("std");
const haxy = @import("haxy");
const ui = haxy.ui;
const Diff = ui.Repo.Diff;
const html = @import("../html.zig");
const Ctx = html.Ctx;
const esc = html.esc;

const short_oid_len = 10;

// one window of a diff, each file's hunks under its path
pub fn panel(c: Ctx, d: *const Diff) !void {
    try c.w.writeAll("<article aria-labelledby=\"diff-heading\">");
    try heading(c, d.route);
    const all_files = try html.routeUrl(c, d.route.page(0, ""));
    if (d.path.len != 0) try c.w.print(
        "<p role=\"status\" class=\"mt-4 text-sm\">Showing changes to <code class=\"mono\">{f}</code>. <a href=\"{f}\" class=\"link\">Show all files</a></p>",
        .{ esc(d.path), esc(all_files) },
    );

    const hunks = d.window.hunks;
    if (hunks.len == 0) {
        if (d.window.truncated) {
            try html.empty(c, "These changes are incomplete", "Haxy couldn't read this far into the diff: it is too large.");
        } else if (d.window.start > 0) {
            try html.empty(c, "No more changes", "");
        } else if (d.path.len != 0) {
            try html.empty(c, "No changes to this file", "");
        } else {
            try html.empty(c, "No changes", "");
        }
    } else {
        try c.w.writeAll("<section aria-label=\"Changes\" class=\"diff-files\">");
        var i: usize = 0;
        while (i < hunks.len) {
            // a file's later hunks carry no path
            var end = i + 1;
            while (end < hunks.len and hunks[end].path == null) end += 1;
            try fileChanges(c, d, hunks[i..end]);
            i = end;
        }
        try c.w.writeAll("</section>");
        if (d.window.truncated) try c.w.writeAll("<p role=\"status\" class=\"notice mt-4\">The rest of the diff is too large to show.</p>");
    }

    const previous = if (d.window.start > 0) try html.routeUrl(c, d.route.page(d.window.start -| Diff.page_size, d.path)) else null;
    const next = if (d.window.has_more) try html.routeUrl(c, d.route.page(d.window.start + hunks.len, d.path)) else null;
    try html.pager(c, "Diff pages", previous, next);
    try c.w.writeAll("</article>");
}

// what the diff compares, and where to read its files
fn heading(c: Ctx, route: Diff.Route) !void {
    switch (route) {
        .repo => |r| {
            if (r.ref_or_oid == .object) {
                try c.w.print("<h2 id=\"diff-heading\" class=\"commit-title\">Changes in commit <code class=\"mono\">{f}</code></h2>", .{esc(short(r.value))});
            } else {
                try c.w.print("<h2 id=\"diff-heading\" class=\"commit-title\">Changes at <code class=\"mono\">{f}</code></h2>", .{esc(try html.decode(c, r.value))});
            }
            try c.w.writeAll("<p class=\"links mt-2 text-sm muted\">");
            if (std.mem.allEqual(u8, r.base_oid, '0')) {
                try c.w.writeAll("<span>A root commit: every file it holds is added.</span>");
            } else try c.w.print("<span>Compared with <a href=\"{f}\" class=\"link mono\">{f}</a></span>", .{
                esc(try html.routeUrl(c, ui.RoutablePage.repoCommitMessageRoute(r.identity, .object, r.base_oid, ""))),
                esc(short(r.base_oid)),
            });
            try c.w.print("<a href=\"{f}\" class=\"link\">Back to the commit</a>", .{esc(try html.routeUrl(c, ui.RoutablePage.repoCommitMessageRoute(r.identity, r.ref_or_oid, r.value, "")))});
            try c.w.print("<a href=\"{f}\" class=\"link\">Browse files at this commit</a></p>", .{esc(try html.routeUrl(c, ui.RoutablePage.repoFilesRoute(r.identity, r.ref_or_oid, r.value, "", 0)))});
        },
        .patchrev => |r| try c.w.print(
            "<h2 id=\"diff-heading\" class=\"commit-title\">Changes in patch revision <code class=\"mono\">{f}</code></h2><p class=\"links mt-2 text-sm\"><a href=\"{f}\" class=\"link\">Browse its files</a></p>",
            .{ esc(short(r.id)), esc(try html.routeUrl(c, ui.RoutablePage.repoPatchRevFilesRoute(r.identity, r.id, "", 0))) },
        ),
        .fork => |f| try c.w.print(
            "<h2 id=\"diff-heading\" class=\"commit-title\">Changes</h2><p class=\"links mt-2 text-sm\"><a href=\"{f}\" class=\"link\">Browse its files</a></p>",
            .{esc(try html.routeUrl(c, ui.RoutablePage.forkFilesRoute(f.identity, f.id, f.oid, "", 0)))},
        ),
    }
}

// one file's hunks in the window, under its path
fn fileChanges(c: Ctx, d: *const Diff, hunks: []const Diff.Hunk) !void {
    const first = hunks[0];
    const path = first.path orelse d.path;
    const status_label, const status_class = switch (first.status) {
        .added => .{ "Added", " pill-added" },
        .removed => .{ "Removed", " pill-removed" },
        .changed => .{ "Changed", "" },
        .binary => .{ "Binary", "" },
    };
    try c.w.print(
        "<section aria-label=\"{f}\" class=\"diff-file\"><header class=\"diff-head\"><code class=\"diff-path\">{f}</code><span class=\"pill{s}\">{s}</span><span class=\"diff-links\"><a href=\"{f}\" class=\"link\">View file</a>",
        .{ esc(path), esc(path), status_class, status_label, esc(try html.routeUrl(c, fileRoute(d.route, path, first.status))) },
    );
    if (d.path.len == 0 and first.status == .changed) try c.w.print("<a href=\"{f}\" class=\"link\">Only this file</a>", .{esc(try html.routeUrl(c, d.route.page(0, path)))});
    try c.w.writeAll("</span></header>");
    switch (first.status) {
        .added => try c.w.writeAll("<p class=\"diff-note\">A new file; open it to read it.</p>"),
        .removed => try c.w.writeAll("<p class=\"diff-note\">The file was removed; open it to read what it held.</p>"),
        .binary => try c.w.writeAll("<p class=\"diff-note\">Binary file not shown.</p>"),
        .changed => for (hunks) |*hunk| try hunkTable(c, path, hunk),
    }
    try c.w.writeAll("</section>");
}

// a hunk's lines as number, sign and code, stripping the number and prefix haxy bakes into each line
fn hunkTable(c: Ctx, path: []const u8, hunk: *const Diff.Hunk) !void {
    try c.w.print("<div class=\"hunk\"><table class=\"diff-table\" aria-label=\"Changes to {f}\"><tbody>", .{esc(path)});
    var lines = std.mem.splitScalar(u8, hunk.text, '\n');
    for (hunk.prefixes) |prefix| {
        const line = lines.next() orelse break;
        const rest = std.mem.trimStart(u8, line, " ");
        const digits = std.mem.indexOfNone(u8, rest, "0123456789") orelse rest.len;
        // a space and the prefix follow the number
        const text = if (digits + 2 <= rest.len) rest[digits + 2 ..] else "";
        const class: []const u8 = switch (prefix) {
            '+' => " class=\"add\"",
            '-' => " class=\"del\"",
            else => "",
        };
        try c.w.print("<tr{s}><td class=\"diff-num\">{s}</td><td class=\"diff-sign\">{c}</td><td class=\"diff-code\">{f}</td></tr>", .{ class, rest[0..digits], prefix, esc(text) });
    }
    try c.w.writeAll("</tbody></table></div>");
}

// the file in the files view, from the base commit for a removed file, as haxy links it
fn fileRoute(route: Diff.Route, path: []const u8, status: Diff.Status) ?ui.RoutablePage {
    if (status == .removed) return switch (route) {
        .repo => |r| ui.RoutablePage.repoFilesRoute(r.identity, .object, r.base_oid, path, 0),
        .patchrev => |r| ui.RoutablePage.repoFilesRoute(r.identity, .object, r.base_oid, path, 0),
        .fork => |f| ui.RoutablePage.forkFilesRoute(f.identity, f.id, if (f.base_oid.len != 0) f.base_oid else f.patch_base_oid, path, 0),
    };
    return switch (route) {
        .repo => |r| ui.RoutablePage.repoFilesRoute(r.identity, r.ref_or_oid, r.value, path, 0),
        .patchrev => |r| ui.RoutablePage.repoPatchRevFilesRoute(r.identity, r.id, path, 0),
        .fork => |f| ui.RoutablePage.forkFilesRoute(f.identity, f.id, f.oid, path, 0),
    };
}

fn short(oid: []const u8) []const u8 {
    return oid[0..@min(oid.len, short_oid_len)];
}
