const std = @import("std");
const haxy = @import("haxy");
const ui = haxy.ui;
const html = @import("../html.zig");
const commits = @import("commits.zig");
const diff = @import("diff.zig");
const files = @import("files.zig");
const refs = @import("refs.zig");
const Ctx = html.Ctx;
const esc = html.esc;

// the repo page's tabs, each a panel rendered into every page
pub const Panel = enum { files, changes, refs, discussions, issues, patches, events, undo, settings };

// the repo's "owner:name", empty in local mode where routes elide it
pub fn identity(data: *const ui.Repo) []const u8 {
    return switch (data.handle.location) {
        .repo => |value| value,
        .fork => unreachable,
    };
}

// whether the route names a ref, rather than reading the default branch
pub fn explicitRef(route: ui.RoutablePage) bool {
    return switch (route) {
        .repo_files => |*f| f.ref_kind != null or f.patchrev_id.len != 0,
        .repo_commits => |*cm| cm.ref_or_oid != null or cm.merge.len != 0,
        .repo_diff => |*d| d.ref_or_oid != null or d.patchrev_id.len != 0,
        else => false,
    };
}

// the default branch's name, when the page knows it
pub fn defaultBranch(c: Ctx, data: *const ui.Repo) !?[]const u8 {
    if (data.settings) |*settings| return settings.branches.default_branch;
    if (data.changes == .commits and data.changes.commits.default_branch.len != 0) return try html.decode(c, data.changes.commits.default_branch);
    if (!explicitRef(c.session.current_page) and data.files.ref_or_oid == .branch) return try html.decode(c, data.files.ref_or_oid_value);
    return null;
}

fn currentPanel(route: ui.RoutablePage) ?Panel {
    return switch (route) {
        .repo_files => .files,
        .repo_commits, .repo_diff => .changes,
        .repo_refs => .refs,
        .repo_discussions => .discussions,
        .repo_issues => .issues,
        .repo_patches => .patches,
        .repo_events => .events,
        .repo_undo => .undo,
        .repo_settings, .repo_members, .repo_branches, .repo_delete => .settings,
        else => null,
    };
}

// a tab's url: the current route when it is selected, else the tab's own route as haxy's header builds it
pub fn tabHref(c: Ctx, data: *const ui.Repo, panel: Panel) ![]const u8 {
    if (currentPanel(c.session.current_page) == panel) return try html.url(c, c.session.current_page);
    const id = identity(data);
    const header = &data.header;
    return switch (panel) {
        .files => try html.routeUrl(c, data.files.filesRoute("", 0)),
        .changes => switch (data.changes) {
            .diff => |*d| try html.routeUrl(c, d.route.page(d.window.start, d.path)),
            .commits => |*cm| try html.routeUrl(c, ui.RoutablePage.repoCommitsRoute(id, header.ref_or_oid, header.ref_or_oid_value, cm.base_oid)),
        },
        .refs => try html.routeUrl(c, ui.RoutablePage.repoRefsRoute(id, .branch, "")),
        .discussions => try html.url(c, try ui.widget.thread.searchRoute(ui.RoutablePage.repoDiscussionsRoute(id, ""), header.discussions_search)),
        .issues => try html.url(c, try ui.widget.thread.searchRoute(ui.RoutablePage.repoIssuesRoute(id, .open, ""), header.issues_search)),
        .patches => try html.url(c, try ui.widget.thread.searchRoute(ui.RoutablePage.repoPatchesRoute(id, .open, ""), header.patches_search)),
        .events => try html.routeUrl(c, ui.RoutablePage.repoEventsRoute(id, .active, null, "", null)),
        .undo => try html.routeUrl(c, ui.RoutablePage.repoUndoRoute(id, null)),
        .settings => try html.routeUrl(c, ui.RoutablePage.repoSettingsRoute(id)),
    };
}

// which tabs the viewer has, in haxy's header order
fn shown(data: *const ui.Repo, panel: Panel) bool {
    return switch (panel) {
        .files, .changes, .refs => true,
        .discussions => data.repo.event.discuss_role != null,
        .issues => data.repo.event.issue_role != null,
        .patches => data.repo.event.patch_role != null,
        .events => data.handle.canWrite(),
        .undo => data.undo != null,
        .settings => data.settings != null,
    };
}

// the tab bar, the header's second row
pub fn tabs(c: Ctx, data: *const ui.Repo) !void {
    const current = currentPanel(c.session.current_page);
    try c.w.writeAll("<nav aria-label=\"Repository sections\" class=\"tabs repo-tabs\" data-tabs>");
    for (std.enums.values(Panel)) |panel| {
        if (!shown(data, panel)) continue;
        const label = switch (panel) {
            .files => "Files",
            .changes => if (data.changes == .diff) "Diff" else "Commits",
            .refs => "Refs",
            .discussions => "Discussions",
            .issues => "Issues",
            .patches => "Patches",
            .events => "Events",
            .undo => "Undo",
            .settings => "Settings",
        };
        try c.w.print("<a href=\"{f}\" class=\"tab\" data-tab=\"panel-{s}\"{s}>{s}", .{
            esc(try tabHref(c, data, panel)),
            @tagName(panel),
            if (current == panel) " aria-current=\"page\"" else "",
            label,
        });
        if (panel == .changes and data.changes == .commits) {
            if (data.changes.commits.commit_count) |count| try c.w.print("<span class=\"tab-count\">{d}</span>", .{count});
        }
        try c.w.writeAll("</a>");
    }
    try c.w.writeAll("</nav>");
}

// every tab's panel, the current one shown
pub fn page(c: Ctx, data: *const ui.Repo) !void {
    const current = currentPanel(c.session.current_page) orelse .files;
    try c.w.writeAll("<div class=\"panels\">");
    for (std.enums.values(Panel)) |panel| {
        if (!shown(data, panel)) continue;
        try c.w.print("<div id=\"panel-{s}\" class=\"panel\" data-panel{s}>", .{ @tagName(panel), if (panel == current) "" else " hidden" });
        switch (panel) {
            .files => try files.panel(c, data),
            .changes => switch (data.changes) {
                .commits => |*cm| try commits.panel(c, data, cm),
                .diff => |*d| try diff.panel(c, d),
            },
            .refs => try refs.panel(c, data),
            .discussions, .issues, .patches, .events, .undo, .settings => try c.w.writeAll("<div class=\"card\"><p class=\"muted\">This section isn't built yet.</p></div>"),
        }
        try c.w.writeAll("</div>");
    }
    try c.w.writeAll("</div>");
}
