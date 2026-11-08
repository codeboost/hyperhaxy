const std = @import("std");
const haxy = @import("haxy");
const ui = haxy.ui;
const evt = haxy.event;
const RoutablePage = ui.RoutablePage;
const Events = ui.Repo.Events;
const html = @import("../html.zig");
const icons = @import("../icons.zig");
const Ctx = html.Ctx;
const esc = html.esc;

fn kindLabel(kind: evt.EventKind) []const u8 {
    return switch (kind) {
        .user => "User",
        .repo => "Repository",
        .fork => "Fork",
        .grant => "Grant",
        .notify => "Notification",
        .discuss => "Discussion",
        .issue => "Issue",
        .comment => "Comment",
        .attach => "Attachment",
        .assign => "Assignment",
        .patchrev => "Patch revision",
        .patch => "Patch",
    };
}

// the events tab: the local sync, then a window of the active or removed events
pub fn panel(c: Ctx, events: *const Events) !void {
    if (events.header.sync_status) |status| try sync(c, status);
    if (events.moment) |index| try c.w.print(
        "<div class=\"heading-row mt-6\"><h2 class=\"subtitle\">Transaction {d}</h2><a href=\"{f}\" class=\"link text-sm\">All events</a></div>",
        .{ index, esc(try html.routeUrl(c, RoutablePage.repoEventsRoute(events.identity, .active, null, "", null))) },
    );

    try c.w.writeAll("<nav aria-label=\"Event lists\" class=\"tabs sub-tabs mt-6\">");
    for ([_]RoutablePage.EventsView{ .active, .removed }, [_][]const u8{ "Active", "Removed" }) |view, label| {
        const win = switch (view) {
            .active => &events.active,
            .removed => &events.removed,
        };
        try c.w.print("<a href=\"{f}\" class=\"tab\"{s}>{s}<span class=\"tab-count\">{d}</span></a>", .{
            esc(try html.routeUrl(c, RoutablePage.repoEventsRoute(events.identity, view, null, "", events.moment))),
            if (view == events.view) " aria-current=\"page\"" else "",
            label,
            win.count,
        });
    }
    try c.w.writeAll("</nav>");

    const win = switch (events.view) {
        .active => &events.active,
        .removed => &events.removed,
    };
    const list_name = if (events.view == .active) "active events" else "removed events";
    if (win.events.len == 0) {
        try html.empty(c, if (events.selected != null) "No more events" else try c.arena.allocator().print("No {s}", .{list_name}), "");
    } else {
        try c.w.print("<ul aria-label=\"{s}\" class=\"list\">", .{list_name});
        for (win.events) |*item| {
            const selected = if (events.selected) |value| std.mem.eql(u8, value.id, item.id) else false;
            try c.w.print("<li class=\"row event-row\"{s}><span class=\"strong\">{s}</span><span class=\"muted\">by ", .{ if (selected) " aria-current=\"true\"" else "", kindLabel(item.kind) });
            try html.author(c, item.author);
            try c.w.print("</span><code class=\"mono text-xs muted\">{s}</code><span class=\"row-end\">", .{item.id[0..@min(item.id.len, 10)]});
            if (item.view_url) |href| try c.w.print("<a href=\"{f}\" class=\"link\">View</a>", .{esc(href)});
            try c.w.writeAll("</span></li>");
        }
        try c.w.writeAll("</ul>");
    }
    // haxy windows from an event onward, so only the next window has a link
    const next = if (win.next) |value| try html.routeUrl(c, RoutablePage.repoEventsRoute(events.identity, events.view, value.kind, value.id, events.moment)) else null;
    const first = if (events.selected != null) try html.routeUrl(c, RoutablePage.repoEventsRoute(events.identity, events.view, null, "", events.moment)) else null;
    if (first != null or next != null) {
        try c.w.writeAll("<nav aria-label=\"Event pages\" class=\"pager\">");
        if (first) |href| try c.w.print("<a href=\"{f}\">First page</a>", .{esc(href)});
        if (next) |href| try c.w.print("<a href=\"{f}\">Next page</a>", .{esc(href)});
        try c.w.writeAll("</nav>");
    }
}

// local mode's sync with its remote, posting to haxy's sync url
fn sync(c: Ctx, status: []const u8) !void {
    try c.w.print(
        \\<section aria-labelledby="sync-heading" class="sync-card"><div class="heading-row"><h2 id="sync-heading" class="sync-title">Sync with the remote</h2><form method="post" action="/sync" class="push-end"><button type="submit" class="btn btn-sm">{s}Sync now</button></form></div>
    , .{icons.refresh_cw});
    if (c.session.sync_failure) |failure| {
        try c.w.writeAll("<div class=\"mt-3\">");
        try html.formError(c, try c.arena.allocator().print("The last sync failed: {s}", .{failure}));
        try c.w.writeAll("</div>");
    } else try c.w.print("<p role=\"status\" class=\"mt-2 text-sm muted\">Status: {f}</p>", .{esc(status)});
    try c.w.writeAll("</section>");
}
