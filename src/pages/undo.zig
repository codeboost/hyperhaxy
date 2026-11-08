const std = @import("std");
const haxy = @import("haxy");
const ui = haxy.ui;
const RoutablePage = ui.RoutablePage;
const Undo = ui.Repo.Undo;
const html = @import("../html.zig");
const icons = @import("../icons.zig");
const files = @import("files.zig");
const Ctx = html.Ctx;
const esc = html.esc;

// the url in one of haxy's widget actions, without its "a:", "ai:" or "form:" prefix
fn actionUrl(action: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, action, ':') orelse return action;
    return action[colon + 1 ..];
}

// the undo tab: the history's transactions, newest first, each undoable by an owner
pub fn panel(c: Ctx, undo: *const Undo) !void {
    const newest_url = try html.routeUrl(c, RoutablePage.repoUndoRoute(undo.identity, null));
    const paged = c.session.current_page == .repo_undo and c.session.current_page.repo_undo.index != null;
    try c.w.writeAll("<section aria-labelledby=\"undo-heading\"><div class=\"heading-row\"><h2 id=\"undo-heading\" class=\"subtitle\">Undo history</h2>");
    if (paged) try c.w.print("<a href=\"{f}\" class=\"link text-sm\">Newest transactions</a>", .{esc(newest_url)});
    try c.w.writeAll(
        \\</div><p class="mt-2 wide text-sm muted">Every change to this repository is a transaction. Undoing one returns the repository to its state before it, discarding it and every transaction after it. The undo is a transaction of its own, so undoing it restores what it discarded.</p>
    );
    // clearing the history is a push, which needs ssh
    if (c.session.git_ssh_url) |ssh_url| try clearCommand(c, ssh_url, undo.identity);
    if (c.session.undo_failure orelse undo.failure) |failure| {
        try c.w.writeAll("<div class=\"mt-4\">");
        try html.formError(c, try c.arena.allocator().print("Haxy couldn't read or undo the history: {s}", .{failure}));
        try c.w.writeAll("</div>");
    }

    if (undo.items.len == 0) {
        try html.empty(c, "No transactions", "");
    } else {
        try c.w.writeAll("<ul aria-label=\"Undo history\" class=\"list\">");
        for (undo.items) |*item| try row(c, undo, item);
        try c.w.writeAll("</ul>");
    }
    const next = if (undo.next) |index| try html.routeUrl(c, RoutablePage.repoUndoRoute(undo.identity, index)) else null;
    try html.pager(c, "Undo history pages", null, next);
    try c.w.writeAll("</section>");
}

fn clearCommand(c: Ctx, ssh_url: []const u8, identity: []const u8) !void {
    try c.w.writeAll("<section aria-labelledby=\"undo-clear\" class=\"commands-card\"><h3 id=\"undo-clear\" class=\"commands-title\">Clear the undo history</h3><ul class=\"commands\">");
    try files.command(c, "SSH", "undo-clear-command", try c.arena.allocator().print("{s}git push {s}/{s} :{s}", .{ c.session.git_ssh_prefix, ssh_url, identity, haxy.push.clear_undo_ref }));
    try c.w.writeAll("</ul></section>");
}

// one transaction: its index, action and time, its description or details, and its undo
fn row(c: Ctx, undo: *const Undo, item: *const Undo.Item) !void {
    try c.w.print(
        \\<li class="row" aria-label="Transaction {d}"><div class="undo-head"><a href="{f}" class="mono text-xs muted">#{d}</a><span class="strong">{f}</span>
    , .{ item.index, esc(actionUrl(item.link)), item.index, esc(item.action) });
    if (item.undone) try c.w.writeAll("<span class=\"pill\">Undone</span>");
    if (item.timestamp >= 0) {
        try c.w.writeAll("<span class=\"row-end\">");
        try html.time(c, item.timestamp);
        try c.w.writeAll("</span>");
    }
    try c.w.writeAll("</div>");
    if (item.buttons.len == 0) {
        try c.w.print("<p class=\"mt-1 text-sm muted wrap\">{f}</p>", .{esc(item.description)});
    } else {
        try c.w.writeAll("<dl class=\"undo-details\">");
        for (item.buttons) |button| {
            try c.w.print("<dt>{f}</dt><dd>", .{esc(std.mem.trim(u8, button.label, " "))});
            if (button.link) |link| {
                try c.w.print("<a href=\"{f}\" class=\"link\">{f}</a>", .{ esc(actionUrl(link)), esc(button.text) });
            } else try c.w.print("{f}", .{esc(button.text)});
            try c.w.writeAll("</dd>");
        }
        try c.w.writeAll("</dl>");
    }
    // haxy undoes for owners only, and never the initial state
    if (undo.handle.canUndo() and item.index > 0) {
        const label = if (item.index == undo.count - 1) "Undo this" else "Undo this and all after it";
        try c.w.print(
            \\<details class="confirm-details mt-2"><summary class="btn btn-outline btn-sm">{s}{s}</summary><div role="alertdialog" aria-labelledby="undo-{d}-text" class="confirm-box mt-3"><p id="undo-{d}-text" class="text-sm">Undo transaction {d}{s}? The repository returns to its state before it.</p><form method="post" action="{f}" class="actions mt-3"><button type="submit" class="btn btn-destructive btn-sm">{s}{s}</button></form></div></details>
        , .{
            icons.undo_2,
            label,
            item.index,
            item.index,
            item.index,
            if (item.index == undo.count - 1) "" else " and every transaction after it",
            esc(actionUrl(item.form)),
            icons.undo_2,
            label,
        });
    }
    try c.w.writeAll("</li>");
}
