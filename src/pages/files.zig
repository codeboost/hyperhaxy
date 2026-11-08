const std = @import("std");
const haxy = @import("haxy");
const ui = haxy.ui;
const Files = ui.Repo.Files;
const html = @import("../html.zig");
const icons = @import("../icons.zig");
const markdown = @import("../markdown.zig");
const repo = @import("repo.zig");
const Ctx = html.Ctx;
const esc = html.esc;

// a longer markdown file shows as numbered source, as in haxy
const max_markdown_lines = 2000;

// the files tab: the toolbar, then a file or a listing; a fork has no repo_data
pub fn panel(c: Ctx, files: *const Files, name: []const u8, repo_data: ?*const ui.Repo) !void {
    if (files.no_commits) return noCommits(c, files.handle, "files-remote");
    try toolbar(c, files, repo_data);
    if (selectedEntry(files)) |entry| return fileView(c, files, name, entry);
    try listing(c, files, name);
}

// a repo without commits, with the remote to push to for a viewer who can
pub fn noCommits(c: Ctx, handle: ui.RepoHandle, copy_id: []const u8) !void {
    const ssh_url = if (c.server() and handle.canWrite()) c.session.git_ssh_url else null;
    const base = ssh_url orelse return html.empty(c, "No commits yet", "Nothing has been pushed to this repository.");
    try html.empty(c, "No commits yet", "Push a branch to this repository to see its files and history.");
    try c.w.print("<section aria-labelledby=\"{s}-heading\" class=\"commands-card\"><h2 id=\"{s}-heading\" class=\"commands-title\">Push an existing repository</h2><ul class=\"commands\">", .{ copy_id, copy_id });
    const remote = switch (handle.location) {
        .repo => |identity| try c.arena.allocator().print("{s}/{s}", .{ base, identity }),
        .fork => |f| try c.arena.allocator().print("{s}/{s}+{s}", .{ base, f.identity, f.id }),
    };
    try command(c, "SSH", copy_id, try c.arena.allocator().print("git remote add origin {s}", .{remote}));
    try c.w.writeAll("</ul></section>");
}

// one git command, selectable, with a copy button app.js reveals
pub fn command(c: Ctx, label: []const u8, id: []const u8, text: []const u8) !void {
    try c.w.print(
        \\<li class="command"><span class="command-label">{s}</span><pre class="command-text"><code id="{s}">{f}</code></pre><button type="button" class="btn btn-outline btn-icon copy" data-copy="{s}" aria-label="Copy {s} command" data-js hidden>{s}</button></li>
    , .{ label, id, esc(text), id, label, icons.copy });
}

fn toolbar(c: Ctx, files: *const Files, repo_data: ?*const ui.Repo) !void {
    try c.w.writeAll("<section aria-label=\"Ref\" class=\"toolbar\">");
    if (repo_data) |data| {
        try refPicker(c, data);
        if (repo.explicitRef(c.session.current_page)) try c.w.print(
            "<a href=\"{f}\" class=\"toolbar-link\">{s}Default branch</a>",
            .{ esc(try html.routeUrl(c, ui.RoutablePage.repoFilesRoute(repo.identity(data), null, "", "", 0))), icons.undo_2 },
        );
        try refCount(c, data, "Branch", "Branches", icons.git_branch, &data.refs.branches);
        try refCount(c, data, "Tag", "Tags", icons.tag, &data.refs.tags);
    }
    try c.w.writeAll("<div class=\"toolbar-end\">");
    if (files.find_available) {
        const action = try html.routeUrl(c, files.handle.location.filesRoute(files.ref_or_oid, files.ref_or_oid_value, "", 0));
        try c.w.print(
            \\<form role="search" aria-label="Go to file" class="find" method="post" action="{f}/search">{s}<input name="search" type="search" value="{f}" aria-label="Go to file" placeholder="Go to file" autocomplete="off" spellcheck="false"></form>
        , .{ esc(action), icons.search, esc(files.find orelse "") });
    }
    if (repo_data) |data| if (c.server()) try codeMenu(c, data);
    try c.w.writeAll("</div></section>");
}

// the branch or tag count, from the refs tab's first window
fn refCount(c: Ctx, data: *const ui.Repo, one: []const u8, many: []const u8, icon: []const u8, column: *const ui.Repo.Refs.Column) !void {
    try c.w.print("<a href=\"{f}\" class=\"toolbar-link\" data-tab=\"panel-refs\">{s}", .{ esc(try repo.tabHref(c, data, .refs)), icon });
    if (data.refs.from.len == 0 and data.refs.search == null) {
        const count = column.names.len;
        try c.w.print("<strong class=\"strong\">{d}{s}</strong>{s}</a>", .{ count, if (column.next != null) "+" else "", if (count == 1 and column.next == null) one else many });
    } else try c.w.print("{s}</a>", .{many});
}

// the ref the listing reads, opening a list of branches and tags
fn refPicker(c: Ctx, data: *const ui.Repo) !void {
    const files = &data.files;
    const kind: []const u8, const icon: []const u8, const name: []const u8 = if (files.patchrev_id) |patchrev|
        .{ "Patch revision", icons.git_commit_horizontal, patchrev[0..@min(patchrev.len, 10)] }
    else switch (files.ref_or_oid) {
        .branch => .{ "Branch", icons.git_branch, try html.decode(c, files.ref_or_oid_value) },
        .tag => .{ "Tag", icons.tag, try html.decode(c, files.ref_or_oid_value) },
        .object => .{ "Commit", icons.git_commit_horizontal, files.ref_or_oid_value[0..@min(files.ref_or_oid_value.len, 10)] },
    };
    try c.w.print(
        \\<details class="menu ref-picker"><summary class="btn btn-outline btn-sm ref-button">{s}<span class="ref-name"><span class="sr-only">{s} </span>{f}</span><span class="muted">{s}</span></summary>
        \\<div class="menu-popover picker"><p class="picker-title">Switch branches or tags</p>
        \\<div class="picker-filter" data-js hidden><input class="input" type="search" aria-label="Filter branches and tags" placeholder="Filter branches and tags…" data-filter="ref-options" autocomplete="off" spellcheck="false"></div>
        \\<div id="ref-options" class="picker-options">
    , .{ icon, kind, esc(name), icons.chevron_down });
    try refGroup(c, data, "Branches", .branch, data.refs.branches.names);
    try refGroup(c, data, "Tags", .tag, data.refs.tags.names);
    try c.w.print(
        "</div><div class=\"picker-foot\"><a href=\"{f}\" class=\"link\" data-tab=\"panel-refs\">View all branches and tags</a></div></div></details>",
        .{esc(try repo.tabHref(c, data, .refs))},
    );
}

fn refGroup(c: Ctx, data: *const ui.Repo, title: []const u8, kind: ui.RoutablePage.RefOrOid, names: []const []const u8) !void {
    const files = &data.files;
    try c.w.print("<p class=\"picker-group\">{s}</p>", .{title});
    if (names.len == 0) return c.w.writeAll("<p class=\"picker-note\">None.</p>");
    try c.w.print("<ul aria-label=\"{s}\" class=\"picker-list\">", .{title});
    for (names) |name| {
        const encoded = try ui.urlEncodeRef(c.arena.allocator(), name);
        const href = try html.routeUrl(c, ui.RoutablePage.repoFilesRoute(repo.identity(data), kind, encoded, "", 0));
        const current = files.patchrev_id == null and files.ref_or_oid == kind and std.mem.eql(u8, files.ref_or_oid_value, encoded);
        try c.w.print(
            \\<li data-name="{f}"><a href="{f}" class="picker-item"{s}><span class="picker-check">{s}</span><span class="picker-name">{f}</span></a></li>
        , .{ esc(name), esc(href), if (current) " aria-current=\"true\"" else "", if (current) icons.check else "", esc(name) });
    }
    try c.w.writeAll("</ul>");
}

// the clone commands behind a Code button, by haxy's rules for which a repo offers
fn codeMenu(c: Ctx, data: *const ui.Repo) !void {
    const aa = c.arena.allocator();
    const id = repo.identity(data);
    const http_url = if (data.handle.read_access == .public) c.session.git_http_url else null;
    const ssh_url = c.session.git_ssh_url;
    if (http_url == null and ssh_url == null) return;
    try c.w.print(
        \\<details class="menu"><summary class="btn btn-sm">{s}Code{s}</summary><div class="menu-popover clone"><p class="commands-title">Clone</p><ul class="commands">
    , .{ icons.code_xml, icons.chevron_down });
    if (http_url) |base| try command(c, "HTTP", "clone-http", try aa.print("git clone {s}/{s}", .{ base, id }));
    if (ssh_url) |base| try command(c, "SSH", "clone-ssh", try aa.print("{s}git clone {s}/{s}", .{ c.session.git_ssh_prefix, base, id }));
    try c.w.writeAll("</ul></div></details>");
}

// the route's file, when it named one
fn selectedEntry(files: *const Files) ?*const Files.Entry {
    const name = files.selected_file orelse return null;
    for (files.entries) |*entry| {
        if (!entry.is_dir and std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

// the path from the repo root, each directory leading back up, plus the history at this ref
fn pathBar(c: Ctx, files: *const Files, name: []const u8, path: []const u8, attached: bool) !void {
    try c.w.print("<div class=\"path-bar{s}\"><nav aria-label=\"Path\" class=\"crumbs\">", .{if (attached) " attached" else ""});
    if (path.len == 0) {
        try c.w.print("<span aria-current=\"page\" class=\"strong\">{f}</span>", .{esc(name)});
    } else {
        try c.w.print("<a href=\"{f}\" class=\"link\">{f}</a>", .{ esc(try html.routeUrl(c, plainRoute(files, ""))), esc(name) });
        var segments = std.mem.splitScalar(u8, path, '/');
        while (segments.next()) |segment| {
            const end = segments.index orelse {
                try c.w.print("<span aria-hidden=\"true\" class=\"muted\">/</span><span aria-current=\"page\" class=\"strong\">{f}</span>", .{esc(segment)});
                break;
            };
            try c.w.print("<span aria-hidden=\"true\" class=\"muted\">/</span><a href=\"{f}\" class=\"link\">{f}</a>", .{ esc(try html.routeUrl(c, plainRoute(files, path[0 .. end - 1]))), esc(segment) });
        }
    }
    try c.w.writeAll("</nav>");
    if (files.patchrev_id == null) {
        const history = try html.routeUrl(c, files.handle.location.commitsRoute(files.ref_or_oid, files.ref_or_oid_value, ""));
        try c.w.print("<a href=\"{f}\" class=\"toolbar-link\">{s}History</a>", .{ esc(history), icons.history });
    }
    try c.w.writeAll("</div>");
}

// a files route at the listing's ref, without its search
fn plainRoute(files: *const Files, path: []const u8) ?ui.RoutablePage {
    if (files.patchrev_id != null) return files.filesRoute(path, 0);
    return files.handle.location.filesRoute(files.ref_or_oid, files.ref_or_oid_value, path, 0);
}

fn listing(c: Ctx, files: *const Files, name: []const u8) !void {
    const aa = c.arena.allocator();
    if (files.find) |term| {
        try c.w.print(
            "<div class=\"path-bar attached\"><p class=\"text-sm\">Files matching <strong class=\"strong\">“{f}”</strong></p><a href=\"{f}\" class=\"toolbar-link\">Clear search</a></div>",
            .{ esc(term), esc(try html.routeUrl(c, plainRoute(files, ""))) },
        );
    } else try pathBar(c, files, name, files.dir, true);

    if (files.entries.len == 0 and files.dir.len == 0) {
        if (files.find) |term| return html.empty(c, try aa.print("No files match “{s}”", .{term}), "");
        return html.empty(c, "This directory is empty", "");
    }

    try c.w.writeAll("<ul aria-label=\"Files\" class=\"list attached\">");
    if (files.dir.len != 0) {
        const parent = if (std.mem.lastIndexOfScalar(u8, files.dir, '/')) |slash| files.dir[0..slash] else "";
        try c.w.print(
            "<li><a href=\"{f}\" class=\"file-row\" aria-label=\"Parent directory\"><span class=\"muted\">{s}</span>..</a></li>",
            .{ esc(try html.routeUrl(c, files.filesRoute(parent, 0))), icons.corner_left_up },
        );
    }
    for (files.entries) |entry| {
        const path = try Files.childDir(aa, files.dir, entry.name);
        try c.w.print("<li><a href=\"{f}\" class=\"file-row\">", .{esc(try html.routeUrl(c, files.filesRoute(path, 0)))});
        if (entry.is_dir) {
            try c.w.print("<span class=\"icon-dir\">{s}</span><span class=\"file-name\">{f}</span>", .{ icons.folder, esc(entry.name) });
        } else if (files.find != null) {
            // a result is named by its full path
            const slash = std.mem.lastIndexOfScalar(u8, entry.name, '/');
            const base = if (slash) |s| entry.name[s + 1 ..] else entry.name;
            try c.w.print("<span class=\"muted\">{s}</span><span class=\"file-name\">{f}</span>", .{ icons.file, esc(base) });
            if (slash) |s| try c.w.print("<span class=\"file-dir\">{f}</span>", .{esc(entry.name[0..s])});
        } else {
            try c.w.print("<span class=\"muted\">{s}</span><span class=\"file-name\">{f}</span>", .{ icons.file, esc(entry.name) });
        }
        try c.w.writeAll("</a></li>");
    }
    if (files.capped) try c.w.writeAll("<li class=\"row text-sm muted\">This list is cut short; there are more entries than it shows.</li>");
    try c.w.writeAll("</ul>");

    if (files.find != null) return;
    for (files.entries) |*entry| {
        if (entry.is_dir or !isReadme(entry.name)) continue;
        const path = try Files.childDir(aa, files.dir, entry.name);
        try c.w.print("<section aria-labelledby=\"readme-heading\" class=\"readme\"><h2 id=\"readme-heading\" class=\"readme-title\">{f}</h2><div class=\"readme-body\">", .{esc(entry.name)});
        try fileBody(c, files, path, entry, try html.routeUrl(c, files.filesRoute(path, 0)));
        try c.w.writeAll("</div></section>");
        break;
    }
}

fn fileView(c: Ctx, files: *const Files, name: []const u8, entry: *const Files.Entry) !void {
    const path = try Files.childDir(c.arena.allocator(), files.dir, entry.name);
    try pathBar(c, files, name, path, false);
    if (files.find != null) try c.w.print(
        "<p class=\"mt-3 text-sm\"><a href=\"{f}\" class=\"link\">Back to the results</a></p>",
        .{esc(try html.routeUrl(c, files.filesRoute("", 0)))},
    );
    try c.w.print("<section aria-labelledby=\"file-heading\" class=\"mt-4\"><h2 id=\"file-heading\" class=\"file-title\">{f}</h2>", .{esc(std.Io.Dir.path.basenamePosix(entry.name))});
    try fileBody(c, files, path, entry, "");
    try c.w.writeAll("</section>");
}

// a file's content: rendered markdown, numbered lines, or why it has none.
// line links go to `file_url` plus the line's anchor.
fn fileBody(c: Ctx, files: *const Files, path: []const u8, entry: *const Files.Entry, file_url: []const u8) !void {
    if (!entry.loaded) {
        try html.empty(c, "This file isn't loaded", "");
        try c.w.print("<p class=\"mt-3 text-sm\"><a href=\"{f}\" class=\"link\">Open the file</a></p>", .{esc(try html.routeUrl(c, files.filesRoute(path, 0)))});
        return;
    }
    if (entry.is_binary) return html.empty(c, "Binary file not shown", "Haxy only shows text files.");
    const first = entry.window_start == 0 and !entry.has_more;
    if (entry.lines.len == 0 and first) return html.empty(c, "This file is empty", "");
    if (isMarkdown(entry.name) and first and entry.lines.len <= max_markdown_lines) {
        return markdown.render(c, try std.mem.join(c.arena.allocator(), "\n", entry.lines));
    }

    const start = entry.window_start + 1;
    if (!first) {
        try c.w.print("<p role=\"status\" class=\"notice\"><span>Showing lines {d}–{d}.</span>", .{ start, entry.window_start + entry.lines.len });
        if (entry.window_start > 0) try c.w.print("<a href=\"{f}\" class=\"link\">First lines</a>", .{esc(try html.routeUrl(c, files.filesRoute(path, 0)))});
        if (entry.has_more) try c.w.print("<a href=\"{f}\" class=\"link\">Next lines</a>", .{esc(try html.routeUrl(c, files.filesRoute(path, entry.window_start + entry.lines.len + 1)))});
        try c.w.writeAll("</p>");
    }
    try c.w.print("<div class=\"code\"><table class=\"code-table\" aria-label=\"{f}\"><tbody>", .{esc(path)});
    for (entry.lines, start..) |line, number| {
        try c.w.print(
            "<tr id=\"L{d}\"><td class=\"code-num\"><a href=\"{f}#L{d}\" aria-label=\"Line {d}\">{d}</a></td><td class=\"code-line\">{f}</td></tr>",
            .{ number, esc(file_url), number, number, number, esc(line) },
        );
    }
    try c.w.writeAll("</tbody></table></div>");
}

fn isMarkdown(name: []const u8) bool {
    const extension = std.Io.Dir.path.extension(name);
    return std.ascii.eqlIgnoreCase(extension, ".md") or std.ascii.eqlIgnoreCase(extension, ".markdown");
}

fn isReadme(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "README") or std.ascii.eqlIgnoreCase(name, "README.md");
}
