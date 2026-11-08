const std = @import("std");
const haxy = @import("haxy");
const ui = haxy.ui;
const RoutablePage = ui.RoutablePage;
const Patches = ui.Repo.Patches;
const html = @import("../html.zig");
const icons = @import("../icons.zig");
const commits = @import("commits.zig");
const diff = @import("diff.zig");
const files = @import("files.zig");
const patch = @import("patch.zig");
const settings = @import("settings.zig");
const threads = @import("threads.zig");
const Ctx = html.Ctx;
const esc = html.esc;

// the fork page's tabs, each a panel rendered into every page
const Panel = enum { patch, files, commits, diff, delete };

// the fork's "forker:name", as its routes name it
fn identity(c: Ctx, data: *const ui.Fork) ![]const u8 {
    return c.arena.allocator().print("{s}:{s}", .{ data.header.forker_name, data.header.name });
}

fn currentPanel(route: RoutablePage) ?Panel {
    return switch (route) {
        .fork_patch => .patch,
        .fork_files => .files,
        .fork_commits => .commits,
        .fork_diff => .diff,
        .fork_delete => .delete,
        else => null,
    };
}

// a tab's url: the current route when it is selected, else the tab's own route as haxy's fork header builds it
fn tabHref(c: Ctx, data: *const ui.Fork, panel: Panel) ![]const u8 {
    if (currentPanel(c.session.current_page) == panel) return html.url(c, c.session.current_page);
    const id = try identity(c, data);
    const header = &data.header;
    return html.routeUrl(c, switch (panel) {
        .patch => RoutablePage.forkPatchRoute(id, header.id),
        .files => RoutablePage.forkFilesRoute(id, header.id, header.oid, "", 0),
        .commits => RoutablePage.forkCommitsRoute(id, header.id, header.oid),
        .diff => RoutablePage.forkDiffRoute(id, header.id, "", "", 0, ""),
        .delete => RoutablePage.forkDeleteRoute(id, header.id),
    });
}

// a fork: who made it and what it proposes, then every tab's panel, the current one shown
pub fn page(c: Ctx, data: *const ui.Fork) !void {
    const entry = data.patch.selectedThread();
    const current = currentPanel(c.session.current_page) orelse .patch;
    try c.w.print(
        "<header><p class=\"fork-eyebrow\">{s}Fork <a href=\"{f}\" class=\"link\">{f}</a>/{f}</p><h1 class=\"title mt-1\">{f}</h1></header>",
        .{ icons.git_fork, esc(try html.userUrl(c, data.header.forker_name)), esc(data.header.forker_name), esc(data.header.name), esc(if (entry) |value| value.record.event.title else data.header.name) },
    );

    try c.w.writeAll("<nav aria-label=\"Fork sections\" class=\"tabs mt-4\" data-tabs>");
    for (std.enums.values(Panel)) |panel| {
        if (panel == .delete and data.delete == null) continue;
        try c.w.print("<a href=\"{f}\" class=\"tab\" data-tab=\"panel-{s}\"{s}>{s}", .{
            esc(try tabHref(c, data, panel)),
            @tagName(panel),
            if (current == panel) " aria-current=\"page\"" else "",
            switch (panel) {
                .patch => "Patch",
                .files => "Files",
                .commits => "Commits",
                .diff => "Diff",
                .delete => "Delete",
            },
        });
        if (panel == .commits) if (data.commits.commit_count) |count| try c.w.print("<span class=\"tab-count\">{d}</span>", .{count});
        try c.w.writeAll("</a>");
    }
    try c.w.writeAll("</nav><div class=\"panels mt-6\">");
    for (std.enums.values(Panel)) |panel| {
        if (panel == .delete and data.delete == null) continue;
        try c.w.print("<div id=\"panel-{s}\" class=\"panel\" data-panel{s}>", .{ @tagName(panel), if (panel == current) "" else " hidden" });
        switch (panel) {
            .patch => try about(c, data),
            .files => try files.panel(c, &data.files, data.header.name, null),
            .commits => try commits.panel(c, &data.commits, null),
            .diff => try diff.panel(c, &data.diff),
            .delete => if (data.delete) |delete| try settings.deleteForm(c, delete.target, try html.routeUrl(c, RoutablePage.forkDeleteRoute(try identity(c, data), data.header.id))),
        }
        try c.w.writeAll("</div>");
    }
    try c.w.writeAll("</div>");
}

fn row(c: Ctx, term: []const u8) !void {
    try c.w.print("<div class=\"proposal-row\"><dt>{s}</dt><dd>", .{term});
}

// what the fork proposes and where it stands, its draft's actions, its git commands and its description
fn about(c: Ctx, data: *const ui.Fork) !void {
    const entry = data.patch.selectedThread() orelse {
        try html.empty(c, "This fork's patch isn't here", "The patch it was made for may have been removed.");
        return;
    };
    const event = &entry.record.event;
    const target = data.patch.identity;
    try c.w.writeAll("<section aria-label=\"About this fork\"><dl class=\"proposal\">");
    try row(c, "Status");
    try c.w.writeAll(if (entry.draft) "Draft" else switch (event.status.kind()) {
        .open => "Open patch",
        .closed => "Closed patch",
        .merged => "Merged patch",
    });
    try c.w.writeAll("</dd></div>");

    try row(c, "Target");
    if (entry.target_deleted) {
        try c.w.writeAll("A deleted repository");
    } else try c.w.print("Branch <code class=\"mono\">{f}</code> of <a href=\"{f}\" class=\"link\">{f}</a>", .{
        esc(event.target_branch),
        esc(try html.routeUrl(c, RoutablePage.repoFilesRoute(target, null, "", "", 0))),
        esc(target),
    });
    try c.w.writeAll("</dd></div>");

    try row(c, "Patch");
    // a draft shows only to its author, who is the forker
    if (entry.target_deleted) {
        try c.w.writeAll("Its patch went with the repository.");
    } else if (entry.draft and data.delete == null) {
        try c.w.writeAll("A draft only its author can open.");
    } else try c.w.print("<a href=\"{f}\" class=\"link\">{s}</a>", .{ esc(try threads.threadUrl(c, .patch, target, entry.id)), if (entry.draft) "Open the draft" else "Open the patch" });
    try c.w.writeAll("</dd></div>");

    try row(c, "Pushed");
    if (data.commits.commit_count) |count| try c.w.print("{d} commit{s}, at ", .{ count, if (count == 1) "" else "s" });
    try c.w.print("<code class=\"mono\">{f}</code></dd></div></dl></section>", .{esc(entry.revision_oid[0..@min(entry.revision_oid.len, 10)])});

    if (entry.target_deleted) try c.w.writeAll(
        \\<section aria-label="Target deleted" class="notice-card mt-4"><p class="strong">The repository this fork was made from has been deleted.</p><p class="mt-1 muted">Only you can see the fork now. You can still browse its files, commits and diff, clone it or fetch its changes, and delete it, but it can't be pushed to, published or merged any more.</p></section>
    );
    // haxy acts on a draft through its target repo, for its author only
    if (entry.draft and data.delete != null and data.patch.repo_source != null) try draftActions(c, &data.patch, entry);
    try patch.forkCommands(c, entry, "fork");
    try c.w.writeAll("<div class=\"mt-6\">");
    try threads.openingPost(c, .patch, &data.patch, entry, false);
    try c.w.writeAll("</div>");
}

fn draftActions(c: Ctx, data: *const Patches, entry: *const Patches.Entry) !void {
    try c.w.print(
        \\<div class="actions mt-6"><a href="{f}" class="btn btn-sm">{s}Publish</a><a href="{f}" class="btn btn-outline btn-sm">{s}Edit</a><a href="{f}" class="btn btn-outline btn-sm btn-danger">{s}Remove</a></div>
    , .{
        esc(try html.routeUrl(c, Patches.publishRoute(data.identity, entry.id))),
        icons.send,
        esc(try html.routeUrl(c, RoutablePage.repoThreadEditRoute(.patch, data.identity, entry.id))),
        icons.pencil,
        esc(try html.routeUrl(c, RoutablePage.repoThreadRemoveRoute(.patch, data.identity, entry.id, "", ""))),
        icons.trash_2,
    });
}
