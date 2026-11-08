const std = @import("std");
const haxy = @import("haxy");
const ui = haxy.ui;
const evt = haxy.event;
const RoutablePage = ui.RoutablePage;
const html = @import("../html.zig");
const icons = @import("../icons.zig");
const markdown = @import("../markdown.zig");
const comments = @import("comments.zig");
const thread_forms = @import("thread_forms.zig");
const Ctx = html.Ctx;
const esc = html.esc;

// a thread tab's page data
pub fn Data(comptime kind: evt.EventKind) type {
    return switch (kind) {
        .issue => ui.Repo.Issues,
        .discuss => ui.Repo.Discussions,
        .patch => ui.Repo.Patches,
        else => @compileError("not a thread kind: " ++ @tagName(kind)),
    };
}

pub const Names = struct {
    noun: []const u8,
    plural: []const u8,
    title: []const u8,
    placeholder: []const u8,
};

// how a thread tab names its threads
pub fn names(comptime kind: evt.EventKind) Names {
    return switch (kind) {
        .issue => .{ .noun = "issue", .plural = "issues", .title = "Issues", .placeholder = "Words, label:name, assignee:name" },
        .discuss => .{ .noun = "discussion", .plural = "discussions", .title = "Discussions", .placeholder = "Words, label:name" },
        .patch => .{ .noun = "patch", .plural = "patches", .title = "Patches", .placeholder = "Words, label:name" },
        else => @compileError("not a thread kind: " ++ @tagName(kind)),
    };
}

// the views that show a form or a confirmation instead of threads
pub const FormView = enum { new, edit, new_comment, edit_comment, remove, resolve, publish, merge };

// a thread tab: its lists, a thread, or a form, as its data's view says
pub fn panel(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind)) !void {
    const view = @tagName(data.view);
    if (std.meta.stringToEnum(FormView, view)) |form| return thread_forms.page(c, kind, data, form);
    if (std.mem.eql(u8, view, "labels")) return labelsView(c, kind, data);
    if (comptime @hasField(Data(kind), "conflicts")) {
        if (std.mem.eql(u8, view, "conflicts")) return conflictsView(c, kind, data);
    }
    // null is the drafts list
    const status = std.meta.stringToEnum(Data(kind).Status, view);
    if (data.selected_id.len == 0 or listWindow(c, kind)) return listView(c, kind, data, status);
    const entry = data.selectedThread() orelse return notFound(c, kind, data);
    if (data.comment_page) |*page| return comments.permalink(c, kind, data, entry, page);
    if (data.description_page) return descriptionPage(c, kind, data, entry);
    try detail(c, kind, data, entry);
}

// whether the page's route only roots this tab's list window at its selected thread
fn listWindow(c: Ctx, comptime kind: evt.EventKind) bool {
    return switch (c.session.current_page) {
        .repo_issues => |*r| kind == .issue and r.start,
        .repo_patches => |*r| kind == .patch and r.start,
        .repo_discussions => |*r| kind == .discuss and r.start,
        else => false,
    };
}

pub fn statusOf(comptime kind: evt.EventKind, entry: *const Data(kind).Entry) Data(kind).Status {
    return switch (kind) {
        .discuss => .recent,
        else => Data(kind).statusKind(entry.record.event),
    };
}

pub fn isDraft(comptime kind: evt.EventKind, entry: *const Data(kind).Entry) bool {
    return switch (kind) {
        .patch => entry.draft,
        else => false,
    };
}

pub fn isConflicted(comptime kind: evt.EventKind, entry: *const Data(kind).Entry) bool {
    return if (@hasField(Data(kind).Entry, "conflicted")) entry.conflicted else false;
}

fn statusLabel(status: anytype) []const u8 {
    return switch (status) {
        inline else => |value| comptime capitalized(@tagName(value)),
    };
}

fn capitalized(comptime word: []const u8) []const u8 {
    comptime {
        var buf: [word.len]u8 = word[0..word.len].*;
        buf[0] = std.ascii.toUpper(buf[0]);
        const result = buf;
        return &result;
    }
}

pub fn seconds(timestamp: u64) i64 {
    return std.math.cast(i64, timestamp) orelse -1;
}

// a thread's own url, at its first comment window
pub fn threadUrl(c: Ctx, comptime kind: evt.EventKind, identity: []const u8, id: []const u8) ![]const u8 {
    return html.routeUrl(c, RoutablePage.repoThreadCommentsRoute(kind, identity, id, 0));
}

// a status list's first window, narrowed to `search`
pub fn listUrl(c: Ctx, comptime kind: evt.EventKind, identity: []const u8, status: Data(kind).Status, search: []const u8) ![]const u8 {
    return html.url(c, try ui.widget.thread.searchRoute(Data(kind).listRoute(identity, status, ""), if (search.len == 0) null else search));
}

// `search` with its `prefix` terms replaced by one for `value`, put first
pub fn withFilter(c: Ctx, search: []const u8, prefix: []const u8, value: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(c.arena.allocator());
    try out.writer.print("{s}{s}", .{ prefix, value });
    var terms = std.mem.tokenizeAny(u8, search, &std.ascii.whitespace);
    while (terms.next()) |term| {
        if (!std.mem.startsWith(u8, term, prefix)) try out.writer.print(" {s}", .{term});
    }
    return out.written();
}

pub fn backLink(c: Ctx, href: []const u8, label: []const u8) !void {
    try c.w.print("<a href=\"{f}\" class=\"back-link\">{s}{f}</a>", .{ esc(href), icons.arrow_left, esc(label) });
}

pub fn notFound(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind)) !void {
    const n = comptime names(kind);
    try html.empty(c, comptime capitalized(n.noun) ++ " not found", "There is no " ++ n.noun ++ " with this id in this repository. It may have been removed.");
    try c.w.print("<p class=\"mt-4 text-sm\"><a href=\"{f}\" class=\"link\">All {s}</a></p>", .{ esc(try firstListUrl(c, kind, data)), n.plural });
}

fn firstListUrl(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind)) ![]const u8 {
    return listUrl(c, kind, data.identity, std.enums.values(Data(kind).Status)[0], "");
}

// the list tabs: one per status with its count, the labels, then drafts and conflicts when there are any
fn subTabs(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind)) !void {
    const n = comptime names(kind);
    const view = @tagName(data.view);
    const search = data.search orelse "";
    try c.w.print("<nav aria-label=\"{s} lists\" class=\"tabs sub-tabs\">", .{n.title});
    for (std.enums.values(Data(kind).Status)) |status| {
        const win = data.window(status);
        try subTab(c, try listUrl(c, kind, data.identity, status, search), statusLabel(status), std.mem.eql(u8, view, @tagName(status)), win.count, win.more);
    }
    const labels_url = try html.url(c, try ui.widget.thread.searchRoute(RoutablePage.repoThreadLabelsRoute(kind, data.identity), data.search));
    try subTab(c, labels_url, "Labels", std.mem.eql(u8, view, "labels"), null, false);
    switch (kind) {
        .patch => if (c.server() and (data.drafts.count > 0 or data.view == .drafts)) {
            try subTab(c, try html.routeUrl(c, Data(kind).draftsRoute(data.identity)), "Drafts", data.view == .drafts, data.drafts.count, false);
        },
        else => {},
    }
    if (comptime @hasField(Data(kind), "conflicts")) {
        if (data.conflicts.count > 0) {
            try subTab(c, try html.routeUrl(c, Data(kind).conflictsRoute(data.identity, "")), "Conflicts", std.mem.eql(u8, view, "conflicts"), data.conflicts.count, false);
        }
    }
    try c.w.writeAll("</nav>");
}

fn subTab(c: Ctx, href: []const u8, label: []const u8, current: bool, count: ?usize, more: bool) !void {
    try c.w.print("<a href=\"{f}\" class=\"tab\"{s}>{s}", .{ esc(href), if (current) " aria-current=\"page\"" else "", label });
    if (count) |value| try c.w.print("<span class=\"tab-count\">{d}{s}</span>", .{ value, if (more) "+" else "" });
    try c.w.writeAll("</a>");
}

// the search, and the way to open a thread for a viewer who may
fn toolbar(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind)) !void {
    const n = comptime names(kind);
    const View = Data(kind).View;
    try c.w.writeAll("<div class=\"list-toolbar\">");
    const action = try html.routeUrl(c, View.searchListRoute(data.identity, View.viewIndex(data.view)));
    try html.searchForm(c, n.plural ++ "-search", "Search " ++ n.plural, n.placeholder, action, data.search orelse "");
    if (data.viewer != null) try c.w.print(
        "<a href=\"{f}\" class=\"btn btn-sm\">{s}New {s}</a>",
        .{ esc(try html.routeUrl(c, RoutablePage.repoThreadNewRoute(kind, data.identity))), icons.plus, n.noun },
    );
    try c.w.writeAll("</div>");
}

// one status's window, or the drafts' when `status` is null
fn listView(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind), status: ?Data(kind).Status) !void {
    const n = comptime names(kind);
    const aa = c.arena.allocator();
    const win = if (status) |value| data.window(value) else switch (kind) {
        .patch => &data.drafts,
        else => unreachable,
    };
    const list_name = if (status) |value| try aa.print("{s} {s}", .{ @tagName(value), n.plural }) else "drafts";
    try subTabs(c, kind, data);
    try toolbar(c, kind, data);
    if (comptime @hasField(Data(kind), "assignee_unknown")) {
        if (data.assignee_unknown) try c.w.writeAll("<p role=\"status\" class=\"notice mt-4\">An assignee in the search names no account, so nothing is assigned to it. Search by email to name someone without an account.</p>");
    }
    if (data.search) |query| try c.w.print(
        "<p role=\"status\" class=\"mt-3 text-sm muted\">Showing {s} matching “{f}”. <a href=\"{f}\" class=\"link\">Clear the search</a></p>",
        .{ list_name, esc(query), esc(if (status) |value| try listUrl(c, kind, data.identity, value, "") else try firstListUrl(c, kind, data)) },
    );

    if (win.items.len == 0) {
        if (win.prev_id != null) {
            try html.empty(c, try aa.print("No more {s}", .{list_name}), "");
        } else if (data.search != null) {
            try html.empty(c, try aa.print("No {s} match this search", .{list_name}), "");
        } else {
            try html.empty(c, try aa.print("No {s}", .{list_name}), "");
        }
    } else {
        try c.w.print("<ul aria-label=\"{s}\" class=\"list\">", .{list_name});
        for (win.items) |*entry| try row(c, kind, data, entry);
        try c.w.writeAll("</ul>");
    }
    try windowPager(c, kind, data, if (status) |value| .{ .status = value } else .drafts, win);
}

fn row(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind), entry: *const Data(kind).Entry) !void {
    const status = statusOf(kind, entry);
    try c.w.print("<li class=\"row\"><p class=\"row-head\"><a href=\"{f}\" class=\"thread-link\">{f}</a>", .{
        esc(try threadUrl(c, kind, data.identity, entry.id)),
        esc(entry.record.event.title),
    });
    if (isDraft(kind, entry)) try c.w.writeAll("<span class=\"pill\">Draft</span>");
    try c.w.writeAll("</p><div class=\"row-meta\">");
    try opened(c, entry);
    if (entry.comments.count > 0) try c.w.print("<span class=\"meta-item\">{s}{d} comment{s}</span>", .{ icons.message_square, entry.comments.count, if (entry.comments.count == 1) "" else "s" });
    if (isConflicted(kind, entry)) try c.w.print("<span class=\"meta-item conflict\">{s}Conflict</span>", .{icons.triangle_alert});
    if (entry.assignees.len > 0) {
        try c.w.writeAll("<span class=\"meta-item\">Assigned to");
        for (entry.assignees) |assignee| try filterChip(c, kind, data, status, "assignee:", assignee.display());
        try c.w.writeAll("</span>");
    }
    try labelChips(c, kind, data, status, entry.record.event.labels);
    try c.w.writeAll("</div></li>");
}

// "Opened <when> by <who>"
fn opened(c: Ctx, entry: anytype) !void {
    try c.w.writeAll("<span>Opened ");
    try html.time(c, seconds(entry.record.created_timestamp));
    try c.w.writeAll(" by ");
    try html.author(c, entry.author);
    try c.w.writeAll("</span>");
}

// a link to `status`'s list narrowed by one filter
fn filterChip(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind), status: Data(kind).Status, prefix: []const u8, value: []const u8) !void {
    const href = try listUrl(c, kind, data.identity, status, try withFilter(c, data.search orelse "", prefix, value));
    try c.w.print("<a href=\"{f}\" class=\"chip\">{f}</a>", .{ esc(href), esc(value) });
}

fn labelChips(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind), status: Data(kind).Status, labels: []const u8) !void {
    if (std.mem.trim(u8, labels, " ").len == 0) return;
    try c.w.writeAll("<span class=\"chips\">");
    var iter = std.mem.splitScalar(u8, labels, ' ');
    while (iter.next()) |label| {
        if (label.len != 0) try filterChip(c, kind, data, status, "label:", label);
    }
    try c.w.writeAll("</span>");
}

// the listing a window belongs to
fn Listing(comptime kind: evt.EventKind) type {
    return union(enum) { status: Data(kind).Status, drafts, conflicts };
}

// previous and next window links, as haxy roots them
fn windowPager(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind), which: Listing(kind), win: anytype) !void {
    const n = comptime names(kind);
    if (win.prev_id == null and win.next_id == null) return;
    try c.w.print("<nav aria-label=\"{s} pages\" class=\"pager\">", .{n.title});
    for ([_]?[]const u8{ win.prev_id, win.next_id }, [_][]const u8{ "Previous page", "Next page" }) |id_maybe, label| {
        const id = id_maybe orelse continue;
        switch (which) {
            .conflicts => if (comptime @hasField(Data(kind), "conflicts")) {
                try c.w.print("<a href=\"{f}\">{s}</a>", .{ esc(try html.routeUrl(c, Data(kind).conflictsRoute(data.identity, id))), label });
            } else unreachable,
            .drafts, .status => {
                const list = switch (which) {
                    .status => |value| Data(kind).listRoute(data.identity, value, ""),
                    else => switch (kind) {
                        .patch => Data(kind).draftsRoute(data.identity),
                        else => unreachable,
                    },
                } orelse return error.RouteTooLong;
                var route = list.startingAt(id) orelse return error.RouteTooLong;
                // drafts are never searched
                if (which == .status) if (data.search) |query| {
                    route = route.withSearch(query) orelse return error.RouteTooLong;
                };
                try c.w.print("<a href=\"{f}\">{s}</a>", .{ esc(try html.url(c, route)), label });
            },
        }
    }
    try c.w.writeAll("</nav>");
}

// every label the tab's threads use, each leading to the first list filtered by it
fn labelsView(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind)) !void {
    const n = comptime names(kind);
    try subTabs(c, kind, data);
    try toolbar(c, kind, data);
    if (data.labels.len == 0) return html.empty(c, "No labels", "No " ++ n.noun ++ " has a label yet.");
    const first = std.enums.values(Data(kind).Status)[0];
    try c.w.writeAll("<ul aria-label=\"Labels\" class=\"chips chips-lg mt-6\">");
    for (data.labels) |label| {
        const href = try listUrl(c, kind, data.identity, first, try withFilter(c, data.search orelse "", "label:", label));
        try c.w.print("<li><a href=\"{f}\" class=\"chip\">{f}</a></li>", .{ esc(href), esc(label) });
    }
    try c.w.writeAll("</ul>");
}

// the threads with unresolved metadata conflicts, each leading to its resolve page
fn conflictsView(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind)) !void {
    const n = comptime names(kind);
    const win = &data.conflicts;
    try subTabs(c, kind, data);
    try c.w.writeAll("<p class=\"wide text-sm muted\">" ++ n.title ++ " whose details were edited differently on two hosts, which haxy merged without choosing between them. Each keeps this host's values until someone resolves it.</p>");
    if (win.items.len == 0) {
        if (win.prev_id != null) return html.empty(c, "No more conflicts", "");
        return html.empty(c, "No " ++ n.plural ++ " with metadata conflicts", "");
    }
    try c.w.print("<ul aria-label=\"Conflicted {s}\" class=\"list\">", .{n.plural});
    for (win.items) |*entry| {
        try c.w.print("<li class=\"row\"><div class=\"row-split\"><div class=\"grow\"><p class=\"row-head\"><a href=\"{f}\" class=\"thread-link\">{f}</a></p><div class=\"row-meta\"><span class=\"meta-item conflict\">{s}Conflict</span>", .{
            esc(try html.routeUrl(c, Data(kind).resolveRoute(data.identity, entry.id, ""))),
            esc(entry.record.event.title),
            icons.triangle_alert,
        });
        try opened(c, entry);
        try c.w.print("</div></div><div class=\"row-links\"><a href=\"{f}\" class=\"link\">View {s}</a></div></div></li>", .{ esc(try threadUrl(c, kind, data.identity, entry.id)), n.noun });
    }
    try c.w.writeAll("</ul>");
    try windowPager(c, kind, data, .conflicts, win);
}

// one thread: its header and actions, then its posts beside its details
fn detail(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind), entry: *const Data(kind).Entry) !void {
    const n = comptime names(kind);
    const status = statusOf(kind, entry);
    const draft = isDraft(kind, entry);
    const thread_url = try threadUrl(c, kind, data.identity, entry.id);
    try c.w.print("<article aria-labelledby=\"{s}-title\" class=\"thread\">", .{n.plural});
    if (draft) {
        switch (kind) {
            .patch => try backLink(c, try html.routeUrl(c, Data(kind).draftsRoute(data.identity)), "Drafts"),
            else => unreachable,
        }
    } else try backLink(c, try listUrl(c, kind, data.identity, status, data.search orelse ""), try c.arena.allocator().print("{s} {s}", .{ statusLabel(status), n.plural }));

    try c.w.print("<header class=\"thread-header\"><div class=\"grow\"><h2 id=\"{s}-title\" class=\"thread-title\">{f}</h2><div class=\"thread-meta\">", .{ n.plural, esc(entry.record.event.title) });
    try statusPill(c, kind, entry);
    try c.w.writeAll("<span>");
    try html.author(c, entry.author);
    try c.w.writeAll(" opened ");
    try html.time(c, seconds(entry.record.created_timestamp));
    try c.w.print("</span><span aria-hidden=\"true\">·</span><span class=\"meta-item\">{s}{d} comment{s}</span></div></div>", .{ icons.message_square, entry.comments.count, if (entry.comments.count == 1) "" else "s" });
    try actions(c, kind, data, entry, thread_url);
    try c.w.writeAll("</header>");

    if (comptime @hasField(Data(kind), "conflicts")) {
        if (isConflicted(kind, entry)) try c.w.print(
            "<p role=\"status\" class=\"notice mt-4\"><span class=\"meta-item\">{s}This {s} has a metadata conflict.</span><a href=\"{f}\" class=\"link\">Resolve the conflict</a></p>",
            .{ icons.triangle_alert, n.noun, esc(try html.routeUrl(c, Data(kind).resolveRoute(data.identity, entry.id, ""))) },
        );
    }
    if (kind == .patch) try c.w.writeAll("<p class=\"mt-4 text-sm muted\">The patch's changes, merging and reviewing come in a later version of this page.</p>");

    try c.w.writeAll("<div class=\"thread-columns\"><div class=\"thread-main\">");
    try openingPost(c, kind, data, entry, false);
    if (!draft) try comments.conversation(c, kind, data, entry);
    try c.w.writeAll("</div><aside aria-label=\"Details\" class=\"thread-sidebar\">");
    try sidebar(c, kind, data, entry, thread_url);
    try c.w.writeAll("</aside></div></article>");
}

fn statusPill(c: Ctx, comptime kind: evt.EventKind, entry: *const Data(kind).Entry) !void {
    if (kind == .discuss) return;
    if (isDraft(kind, entry)) return c.w.print("<span role=\"status\" aria-label=\"Status\" class=\"status status-closed\">{s}Draft</span>", .{icons.git_pull_request_draft});
    const status = statusOf(kind, entry);
    const name = @tagName(status);
    const open = std.mem.eql(u8, name, "open");
    const icon = if (open) icons.circle_dot else if (std.mem.eql(u8, name, "merged")) icons.git_merge else icons.circle_check;
    try c.w.print("<span role=\"status\" aria-label=\"Status\" class=\"status status-{s}\">{s}{s}</span>", .{ if (open) "open" else "closed", icon, statusLabel(status) });
}

// what the viewer may do to the thread: resolve its conflict, or change its status and fields; and remove it
fn actions(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind), entry: *const Data(kind).Entry, thread_url: []const u8) !void {
    const n = comptime names(kind);
    const draft = isDraft(kind, entry);
    // a draft is its author's alone
    if (!entry.can_modify and !draft) return;
    try c.w.writeAll("<div class=\"actions thread-actions\">");
    if (isConflicted(kind, entry)) {
        if (comptime @hasField(Data(kind), "conflicts")) try c.w.print(
            "<a href=\"{f}\" class=\"btn btn-outline btn-sm\">{s}Resolve conflict</a>",
            .{ esc(try html.routeUrl(c, Data(kind).resolveRoute(data.identity, entry.id, ""))), icons.triangle_alert },
        );
    } else {
        const name = @tagName(statusOf(kind, entry));
        if (kind != .discuss and !draft) {
            if (std.mem.eql(u8, name, "open")) {
                try c.w.print("<form method=\"post\" action=\"{f}/close\"><button type=\"submit\" class=\"btn btn-outline btn-sm\">{s}Close {s}</button></form>", .{ esc(thread_url), icons.circle_check, n.noun });
            } else if (std.mem.eql(u8, name, "closed")) {
                try c.w.print("<form method=\"post\" action=\"{f}/open\"><button type=\"submit\" class=\"btn btn-outline btn-sm\">{s}Reopen {s}</button></form>", .{ esc(thread_url), icons.circle_dot, n.noun });
            }
        }
        try c.w.print("<a href=\"{f}\" class=\"btn btn-outline btn-sm\">{s}Edit</a>", .{ esc(try html.routeUrl(c, RoutablePage.repoThreadEditRoute(kind, data.identity, entry.id))), icons.pencil });
    }
    try c.w.print("<a href=\"{f}\" class=\"btn btn-outline btn-sm btn-danger\">{s}Remove</a></div>", .{ esc(try html.routeUrl(c, RoutablePage.repoThreadRemoveRoute(kind, data.identity, entry.id, "", ""))), icons.trash_2 });
}

// the description as the thread's opening post, cut to haxy's preview unless `whole`
pub fn openingPost(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind), entry: *const Data(kind).Entry, whole: bool) !void {
    const n = comptime names(kind);
    const description = entry.record.event.description;
    try c.w.writeAll("<div class=\"post\">");
    try html.avatar(c, entry.author, .lg);
    try c.w.writeAll("<section aria-label=\"Description\" class=\"post-card\"><header class=\"post-head\"><span class=\"strong\">");
    try html.author(c, entry.author);
    try c.w.print("</span> opened this {s} ", .{n.noun});
    try html.time(c, seconds(entry.record.created_timestamp));
    try c.w.writeAll("</header><div class=\"post-body\">");
    if (description.len == 0) {
        try c.w.writeAll("<p class=\"muted\">No description.</p>");
    } else if (if (whole) null else ui.detailPreviewEnd(description)) |end| {
        try markdown.render(c, std.mem.trimEnd(u8, description[0..end], " \t\r\n"));
        try c.w.print(
            "<p class=\"mt-4 text-sm\"><a href=\"{f}\" class=\"link\">Show the whole description</a></p>",
            .{esc(try html.routeUrl(c, RoutablePage.repoThreadDescriptionRoute(kind, data.identity, entry.id)))},
        );
    } else try markdown.render(c, description);
    try c.w.writeAll("</div></section></div>");
}

// a long description shown whole
fn descriptionPage(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind), entry: *const Data(kind).Entry) !void {
    const n = comptime names(kind);
    try c.w.writeAll("<article class=\"thread\">");
    try backLink(c, try threadUrl(c, kind, data.identity, entry.id), "Back to the " ++ n.noun);
    try c.w.print("<h2 class=\"thread-title mt-3\">{f}</h2><div class=\"mt-6\">", .{esc(entry.record.event.title)});
    try openingPost(c, kind, data, entry, true);
    try c.w.writeAll("</div></article>");
}

fn sidePanel(c: Ctx, comptime kind: evt.EventKind, comptime title: []const u8, comptime slug: []const u8) !void {
    const id = comptime names(kind).plural ++ "-side-" ++ slug;
    try c.w.writeAll("<section aria-labelledby=\"" ++ id ++ "\" class=\"side-panel\"><h3 id=\"" ++ id ++ "\" class=\"side-title\">" ++ title ++ "</h3>");
}

fn sidebar(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind), entry: *const Data(kind).Entry, thread_url: []const u8) !void {
    const n = comptime names(kind);
    const status = statusOf(kind, entry);

    try sidePanel(c, kind, "Labels", "labels");
    if (std.mem.trim(u8, entry.record.event.labels, " ").len == 0)
        try c.w.writeAll("<p class=\"muted\">None yet</p>")
    else
        try labelChips(c, kind, data, status, entry.record.event.labels);
    try c.w.writeAll("</section>");

    if (kind == .issue) try assignees(c, kind, data, entry, thread_url);

    if (!isDraft(kind, entry)) {
        try sidePanel(c, kind, "Attachments", "attachments");
        if (entry.attachments.len == 0) {
            try c.w.writeAll("<p class=\"muted\">Nothing is attached to this " ++ n.noun ++ ".</p>");
        } else {
            try c.w.writeAll("<ul aria-label=\"Attached files\" class=\"side-list\">");
            for (entry.attachments) |*attachment| {
                const href = if (data.identity.len == 0)
                    try c.arena.allocator().print("/attachment:{s}", .{&attachment.id})
                else
                    try c.arena.allocator().print("/{s}/attachment:{s}", .{ data.identity, &attachment.id });
                try c.w.print("<li class=\"side-item\"><span class=\"muted\">{s}</span><a href=\"{f}\" class=\"link\" hx-boost=\"false\">{f}</a>", .{ icons.paperclip, esc(href), esc(attachment.name) });
                if (entry.can_modify) try c.w.print(
                    "<a href=\"{f}\" class=\"icon-button\" aria-label=\"Remove {f}\" title=\"Remove {f}\">{s}</a>",
                    .{ esc(try html.routeUrl(c, RoutablePage.repoThreadRemoveRoute(kind, data.identity, entry.id, "", &attachment.id))), esc(attachment.name), esc(attachment.name), icons.x },
                );
                try c.w.writeAll("</li>");
            }
            try c.w.writeAll("</ul>");
        }
        // the upload sends the raw file, which needs js
        if (entry.can_modify and !isConflicted(kind, entry)) try c.w.print(
            \\<div class="side-form" data-js hidden><label class="label" for="{s}-attach">Attach a file</label><input class="file-input" id="{s}-attach" type="file" data-attach="{f}/attach"><p role="alert" class="form-error" data-attach-error hidden></p></div>
        , .{ n.plural, n.plural, esc(thread_url) });
        try c.w.writeAll("</section>");
    }

    if (entry.notify_action) |action| {
        try sidePanel(c, kind, "Notifications", "notifications");
        const text, const label, const icon = switch (action) {
            .mute => .{ "You're notified of activity on this " ++ n.noun ++ ".", "Mute", icons.bell_off },
            .subscribe => .{ "You're not notified of activity on this " ++ n.noun ++ ".", "Subscribe", icons.bell_ring },
        };
        try c.w.print(
            "<p class=\"muted\">{s}</p><form method=\"post\" action=\"{f}/{s}\" class=\"mt-2\"><button type=\"submit\" class=\"btn btn-outline btn-sm\">{s}{s}</button></form></section>",
            .{ text, esc(thread_url), @tagName(action), icon, label },
        );
    }
}

// an issue's assignees, with unassign buttons and an assign form for a viewer who may change it
fn assignees(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind), entry: *const Data(kind).Entry, thread_url: []const u8) !void {
    const n = comptime names(kind);
    const status = statusOf(kind, entry);
    try sidePanel(c, kind, "Assignees", "assignees");
    if (entry.assignees.len == 0) {
        try c.w.writeAll("<p class=\"muted\">Nobody is assigned to this " ++ n.noun ++ ".</p>");
    } else {
        try c.w.writeAll("<ul aria-label=\"Assigned\" class=\"chips\">");
        for (entry.assignees) |assignee| {
            const name = assignee.display();
            const href = try listUrl(c, kind, data.identity, status, try withFilter(c, data.search orelse "", "assignee:", name));
            try c.w.print("<li class=\"chip chip-split\"><a href=\"{f}\" class=\"chip-link\">{f}</a>", .{ esc(href), esc(name) });
            if (entry.can_modify) try c.w.print(
                "<form method=\"post\" action=\"{f}/assignee:{f}/unassign\"><button type=\"submit\" class=\"chip-x\" aria-label=\"Unassign {f}\" title=\"Unassign {f}\">{s}</button></form>",
                .{ esc(thread_url), esc(try ui.urlEncodeRef(c.arena.allocator(), assignee.email)), esc(name), esc(name), icons.x },
            );
            try c.w.writeAll("</li>");
        }
        try c.w.writeAll("</ul>");
    }
    if (entry.can_modify) {
        const saved = c.feedback(.assignment);
        try c.w.print("<form method=\"post\" action=\"{f}/assign\" class=\"side-form\">", .{esc(thread_url)});
        if (saved) |value| try html.formError(c, switch (value.failure) {
            .not_found => "No account has that name.",
            .not_an_email => "That isn't an email address.",
            .already_assigned => "They're assigned already.",
        });
        try c.w.print(
            \\<label class="sr-only" for="{s}-assignee">Assign someone</label><input class="input" id="{s}-assignee" name="assignee" value="{f}" placeholder="{s}" autocomplete="off" autocapitalize="none" spellcheck="false"{s}><div><button type="submit" class="btn btn-outline btn-sm">{s}Assign</button></div></form>
        , .{
            n.plural,
            n.plural,
            esc(if (saved) |value| value.text else ""),
            if (c.server()) "Username or email" else "Email",
            if (saved != null) " aria-invalid=\"true\"" else "",
            icons.user_plus,
        });
    }
    try c.w.writeAll("</section>");
}
