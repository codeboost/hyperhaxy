const std = @import("std");
const haxy = @import("haxy");
const ui = haxy.ui;
const RoutablePage = ui.RoutablePage;
const Patches = ui.Repo.Patches;
const Mergeability = haxy.pch.Mergeability;
const html = @import("../html.zig");
const icons = @import("../icons.zig");
const files = @import("files.zig");
const threads = @import("threads.zig");
const Ctx = html.Ctx;
const esc = html.esc;

const short_oid_len = 10;

const methods = [_]struct { revision: haxy.event.Patch.MergeRevision, label: []const u8, how: []const u8 }{
    .{ .revision = .source, .label = "Merge", .how = "with its source commits" },
    .{ .revision = .squash, .label = "Squash and merge", .how = "as one squashed commit" },
};

// what a patch proposes, merging it, reviewing it and its git commands
pub fn sections(c: Ctx, data: *const Patches, entry: *const Patches.Entry) !void {
    try proposal(c, data, entry);
    try mergeBox(c, data, entry);
    try review(c, data, entry);
    try forkCommands(c, entry, "patch");
}

// haxy's Patches.canMerge, which reads only the host kind from its session
fn canMerge(c: Ctx, entry: *const Patches.Entry) bool {
    const event = &entry.record.event;
    return !entry.draft and
        (entry.fork_exists or event.source_branch != null) and
        !entry.conflicted and
        event.revision != null and
        event.status.kind() == .open and
        c.server();
}

// whether the viewer may merge the patch now, as haxy's merge handler authorizes it
pub fn mergeable(c: Ctx, data: *const Patches, entry: *const Patches.Entry) bool {
    const viewer = data.viewer orelse return false;
    return canMerge(c, entry) and viewer.role.atLeast(.write);
}

fn short(oid: []const u8) []const u8 {
    return oid[0..@min(oid.len, short_oid_len)];
}

fn row(c: Ctx, term: []const u8) !void {
    try c.w.print("<div class=\"proposal-row\"><dt>{s}</dt><dd>", .{term});
}

fn branchLink(c: Ctx, identity: []const u8, branch: []const u8) !void {
    const href = try html.routeUrl(c, RoutablePage.repoFilesRoute(identity, .branch, try ui.urlEncodeRef(c.arena.allocator(), branch), "", 0));
    try c.w.print("Branch <a href=\"{f}\" class=\"link mono\">{f}</a>", .{ esc(href), esc(branch) });
}

fn mergeText(status: Mergeability.Status) []const u8 {
    return switch (status) {
        .clean => "merges cleanly",
        .conflict => "conflicts with the target",
        .unknown => "isn't checked against the target yet",
    };
}

// the source, target and revision, and whether haxy would merge it
fn proposal(c: Ctx, data: *const Patches, entry: *const Patches.Entry) !void {
    const event = &entry.record.event;
    const status = event.status.kind();
    try c.w.writeAll("<section aria-labelledby=\"patch-proposal\" class=\"mt-6\"><h3 id=\"patch-proposal\" class=\"section-title\">Proposal</h3><dl class=\"proposal\">");

    try row(c, "Source");
    if (event.source_branch) |branch| {
        try branchLink(c, data.identity, branch);
    } else if (entry.fork_exists) {
        try c.w.print("The fork <a href=\"{f}\" class=\"link mono\">{f}</a>", .{ esc(try html.routeUrl(c, RoutablePage.forkPatchRoute(entry.fork_identity, entry.id))), esc(entry.fork_identity) });
    } else try c.w.writeAll("A fork that has been removed");
    try c.w.writeAll("</dd></div>");

    try row(c, if (status == .merged) "Merged into" else "Target");
    try branchLink(c, data.identity, event.target_branch);
    try c.w.writeAll("</dd></div>");

    try row(c, "Revision");
    if (entry.revision_oid.len == 0) {
        try c.w.writeAll("Nothing has been pushed yet.");
    } else {
        const squashed = switch (event.status) {
            .merged => |merged| merged.revision == .squash,
            else => false,
        };
        try c.w.print("<span class=\"stack\"><span>{s} commit ", .{if (squashed) "Squashed" else "Source"});
        if (try commitRoute(data.identity, entry)) |route| {
            try c.w.print("<a href=\"{f}\" class=\"link mono\">{f}</a>", .{ esc(try html.url(c, route)), esc(short(entry.revision_oid)) });
        } else try c.w.print("<code class=\"mono\">{f}</code>", .{esc(short(entry.revision_oid))});
        if (entry.base_oid.len != 0) try c.w.print(" based on <code class=\"mono\">{f}</code>", .{esc(short(entry.base_oid))});
        try c.w.writeAll("</span>");
        if (entry.commit_count) |count| {
            try c.w.print("<span>{d} commit{s}</span>", .{ count, if (count == 1) "" else "s" });
        } else try c.w.writeAll("<span>Commit count unavailable</span>");
        try c.w.writeAll("</span>");
    }
    try c.w.writeAll("</dd></div>");

    if (entry.no_changes) {
        try row(c, "Changes");
        try c.w.writeAll("No changes: the target branch is already at this revision.</dd></div>");
    }
    switch (event.status) {
        .merged => |merged| {
            try row(c, "Merged");
            try c.w.writeAll(if (merged.revision == .squash) "As one squashed commit" else "With its source commits");
            try c.w.writeAll("</dd></div>");
        },
        .open => if (!entry.draft and c.server()) {
            try row(c, "Mergeability");
            try c.w.print("<span class=\"stack\"><span>Merging its commits {s}.</span><span>Squash-merging {s}.</span></span></dd></div>", .{ mergeText(entry.mergeability.source), mergeText(entry.mergeability.squash) });
        },
        .closed => {},
    }
    try c.w.writeAll("</dl></section>");
}

// the revision's commit page, where that commit lives
fn commitRoute(identity: []const u8, entry: *const Patches.Entry) !?RoutablePage {
    const event = &entry.record.event;
    if (entry.fork_exists and event.status.kind() != .merged)
        return RoutablePage.forkCommitMessageRoute(entry.fork_identity, entry.id, entry.revision_oid) orelse error.RouteTooLong;
    if (event.source_branch == null and event.status.kind() != .merged) return null;
    return RoutablePage.repoCommitMessageRoute(identity, .object, entry.revision_oid, entry.base_oid) orelse error.RouteTooLong;
}

// the revision's files, as haxy's Patches.diffRoute finds its diff
fn filesRoute(identity: []const u8, entry: *const Patches.Entry) !?RoutablePage {
    const event = &entry.record.event;
    const revision_id = switch (event.status) {
        .merged => |merged| merged.patchrev_id,
        .open, .closed => blk: {
            if (entry.fork_exists) return RoutablePage.forkFilesRoute(entry.fork_identity, entry.id, "", "", 0) orelse error.RouteTooLong;
            if (event.source_branch == null) return null;
            break :blk (event.revision orelse return null).id;
        },
    };
    return RoutablePage.repoPatchRevFilesRoute(identity, &revision_id, "", 0) orelse error.RouteTooLong;
}

// links to the revision's files, commits and diff
fn review(c: Ctx, data: *const Patches, entry: *const Patches.Entry) !void {
    const files_route = try filesRoute(data.identity, entry);
    const commits_route = try Patches.commitsRoute(data.identity, entry.*);
    const diff_route = try Patches.diffRoute(data.identity, entry.*);
    try c.w.writeAll("<section aria-labelledby=\"patch-review\" class=\"mt-6\"><h3 id=\"patch-review\" class=\"section-title\">Review</h3>");
    if (files_route == null and commits_route == null and diff_route == null) {
        try c.w.writeAll("<p role=\"status\" class=\"text-sm muted\">There is nothing to review: no revision of this patch is here.</p></section>");
        return;
    }
    try c.w.writeAll("<nav aria-label=\"Review this revision\" class=\"actions\">");
    if (files_route) |route| try c.w.print("<a href=\"{f}\" class=\"btn btn-outline btn-sm\">{s}Files</a>", .{ esc(try html.url(c, route)), icons.file_code_2 });
    if (commits_route) |route| {
        try c.w.print("<a href=\"{f}\" class=\"btn btn-outline btn-sm\">{s}Commits", .{ esc(try html.url(c, route)), icons.git_commit_horizontal });
        if (entry.commit_count) |count| try c.w.print(" ({d})", .{count});
        try c.w.writeAll("</a>");
    }
    if (diff_route) |route| try c.w.print(
        "<a href=\"{f}\" class=\"btn btn-outline btn-sm\">{s}{s}</a>",
        .{ esc(try html.url(c, route)), icons.git_compare_arrows, if (entry.record.event.status.kind() == .merged) "What landed" else "Diff" },
    );
    try c.w.writeAll("</nav></section>");
}

// each way of merging, leading to haxy's merge confirmation when it merges cleanly
fn mergeBox(c: Ctx, data: *const Patches, entry: *const Patches.Entry) !void {
    if (!mergeable(c, data, entry)) return;
    const href = try html.routeUrl(c, Patches.mergeRoute(data.identity, entry.id));
    try c.w.writeAll("<section aria-labelledby=\"patch-merge\" class=\"mt-6\"><h3 id=\"patch-merge\" class=\"section-title\">Merge</h3><div role=\"group\" aria-label=\"Merge actions\" class=\"merge-choices\">");
    for (methods) |method| {
        const status = entry.mergeability.get(method.revision);
        try c.w.writeAll("<span class=\"merge-choice\">");
        if (status == .clean) {
            try c.w.print("<a href=\"{f}\" class=\"btn btn-outline btn-sm\">{s}{s}</a>", .{ esc(href), icons.git_merge, method.label });
        } else try c.w.print("<button type=\"button\" class=\"btn btn-outline btn-sm\" disabled>{s}{s}</button><span class=\"text-xs muted\">{s}</span>", .{ icons.git_merge, method.label, unavailableNote(status) });
        try c.w.writeAll("</span>");
    }
    try c.w.writeAll("</div></section>");
}

fn unavailableNote(status: Mergeability.Status) []const u8 {
    return switch (status) {
        .clean => "",
        .conflict => "Conflicts with the target branch.",
        .unknown => "Not checked against the target branch yet.",
    };
}

// the git commands for the fork a patch lives in
pub fn forkCommands(c: Ctx, entry: *const Patches.Entry, noun: []const u8) !void {
    if (!entry.fork_exists or entry.record.event.status.kind() == .merged) return;
    const ssh_url = c.session.git_ssh_url orelse return;
    const aa = c.arena.allocator();
    const prefix = c.session.git_ssh_prefix;
    const url = try aa.print("{s}/{s}+{s}", .{ ssh_url, entry.fork_identity, entry.id });
    try c.w.print("<section aria-labelledby=\"fork-commands\" class=\"commands-card\"><h3 id=\"fork-commands\" class=\"commands-title\">Work on this {s} with Git</h3><ul class=\"commands\">", .{noun});
    // a fork whose target is gone can't be pushed to
    if (!entry.target_deleted) try files.command(c, "Push", "fork-push", try aa.print("{s}git push {s} HEAD:patch", .{ prefix, url }));
    try files.command(c, "Clone", "fork-clone", try aa.print("{s}git clone {s}", .{ prefix, url }));
    try files.command(c, "Merge", "fork-merge", try aa.print("{s}git fetch '{s}' refs/heads/patch && git merge FETCH_HEAD", .{ prefix, url }));
    try c.w.writeAll("</ul></section>");
}

// haxy's merge confirmation: a form per way of merging that merges cleanly
pub fn mergeConfirm(c: Ctx, data: *const Patches) !void {
    const entry = data.selectedThread() orelse return threads.notFound(c, .patch, data);
    const event = &entry.record.event;
    const thread_url = try threads.threadUrl(c, .patch, data.identity, entry.id);
    try c.w.writeAll("<section class=\"medium\">");
    try threads.backLink(c, thread_url, "Back to the patch");
    try c.w.print("<h2 class=\"title mt-3\">Merge patch</h2><p class=\"mt-1 muted\">{f}</p>", .{esc(event.title)});
    if (!mergeable(c, data, entry)) {
        try c.w.writeAll("<p role=\"status\" class=\"mt-6 text-sm muted\">This patch can't be merged now: it may be a draft, closed, conflicted, have nothing pushed, or you may not be a member.</p></section>");
        return;
    }
    const action = try html.routeUrl(c, Patches.mergeRoute(data.identity, entry.id));
    for (methods) |method| {
        const status = entry.mergeability.get(method.revision);
        if (status != .clean) {
            try c.w.print("<p role=\"status\" class=\"mt-6 text-sm muted\">{s} isn't available. {s}</p>", .{ method.label, unavailableNote(status) });
            continue;
        }
        try c.w.print(
            \\<div role="alertdialog" aria-labelledby="merge-{s}-text" class="confirm-panel mt-6"><p id="merge-{s}-text" class="text-sm">Merge “{f}” into <span class="mono">{f}</span> {s}? The target branch moves for everyone.</p><form method="post" action="{f}{s}" class="actions mt-3"><button type="submit" class="btn btn-sm">{s}{s}</button><a href="{f}" class="btn btn-outline btn-sm">Cancel</a></form></div>
        , .{
            @tagName(method.revision),
            @tagName(method.revision),
            esc(event.title),
            esc(event.target_branch),
            method.how,
            esc(action),
            if (method.revision == .squash) "/squash" else "",
            icons.git_merge,
            method.label,
            esc(thread_url),
        });
    }
    try c.w.writeAll("</section>");
}

// haxy's publish confirmation for a draft
pub fn publishConfirm(c: Ctx, data: *const Patches) !void {
    const entry = data.selectedThread() orelse return threads.notFound(c, .patch, data);
    const event = &entry.record.event;
    const thread_url = try threads.threadUrl(c, .patch, data.identity, entry.id);
    try c.w.writeAll("<section class=\"medium\">");
    try threads.backLink(c, thread_url, "Back to the draft");
    try c.w.print("<h2 class=\"title mt-3\">Publish draft</h2><p class=\"mt-1 muted\">{f}</p>", .{esc(event.title)});
    if (!entry.draft) {
        try c.w.writeAll("<p role=\"status\" class=\"mt-6 text-sm muted\">This patch is published already.</p></section>");
        return;
    }
    try c.w.print(
        \\<div role="alertdialog" aria-labelledby="publish-text" class="confirm-panel mt-6"><p id="publish-text" class="text-sm">Publish “{f}” as a patch to <span class="mono">{f}</span>? Everyone who can read this repository's patches sees it, and members can merge it.</p><form method="post" action="{f}" class="actions mt-3"><button type="submit" class="btn btn-sm">{s}Publish</button><a href="{f}" class="btn btn-outline btn-sm">Cancel</a></form></div></section>
    , .{ esc(event.title), esc(event.target_branch), esc(try html.routeUrl(c, Patches.publishRoute(data.identity, entry.id))), icons.send, esc(thread_url) });
}
