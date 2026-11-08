const std = @import("std");
const haxy = @import("haxy");
const ui = haxy.ui;
const evt = haxy.event;
const RoutablePage = ui.RoutablePage;
const Comment = ui.Repo.Comment;
const html = @import("../html.zig");
const icons = @import("../icons.zig");
const markdown = @import("../markdown.zig");
const threads = @import("threads.zig");
const Ctx = html.Ctx;
const esc = html.esc;
const Data = threads.Data;

// a thread's comments in time order, a window at a time, then the composer
pub fn conversation(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind), entry: *const Data(kind).Entry) !void {
    const n = comptime threads.names(kind);
    const win = &entry.comments;
    try c.w.print("<section aria-labelledby=\"{s}-conversation\" class=\"conversation\"><h3 id=\"{s}-conversation\" class=\"section-title\">Conversation <span class=\"muted\">({d})</span></h3>", .{ n.plural, n.plural, win.count });
    if (win.comments.len == 0) {
        try c.w.writeAll(if (win.start > 0) "<p class=\"text-sm muted\">No more comments.</p>" else "<p class=\"text-sm muted\">No comments yet.</p>");
    } else {
        try c.w.writeAll("<ol aria-label=\"Comments\" class=\"comments\">");
        for (win.comments) |*comment| {
            try c.w.writeAll("<li>");
            try card(c, kind, data, comment, false);
            try c.w.writeAll("</li>");
        }
        try c.w.writeAll("</ol>");
    }
    try pager(c, kind, data.identity, entry.id, null, win, "Comment pages");
    try composer(c, kind, data, try html.routeUrl(c, RoutablePage.repoThreadCommentNewRoute(kind, data.identity, entry.id, "")), "Add a comment", "Comment");
    try c.w.writeAll("</section>");
}

// one comment: who wrote it when (its permalink), what it replies to, its actions and body
pub fn card(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind), comment: *const Comment.CommentWithId, focused: bool) !void {
    const thread_id: []const u8 = &comment.comment.event.thread_id;
    const parent_id: []const u8 = &comment.comment.event.parent_id;
    try c.w.print("<article id=\"comment-{s}\" aria-label=\"Comment by {f}\" class=\"comment{s}\"><header class=\"comment-head\">", .{ &comment.id, esc(html.authorText(comment.author)), if (focused) " comment-focused" else "" });
    try html.avatar(c, comment.author, .md);
    try c.w.writeAll("<span class=\"strong\">");
    try html.author(c, comment.author);
    try c.w.print("</span><span aria-hidden=\"true\">·</span><a href=\"{f}\" class=\"link\" aria-label=\"Permalink\">", .{esc(try html.routeUrl(c, RoutablePage.repoThreadCommentRoute(kind, data.identity, thread_id, &comment.id, 0)))});
    try html.time(c, threads.seconds(comment.comment.created_timestamp));
    try c.w.writeAll("</a>");
    if (!std.mem.eql(u8, parent_id, thread_id)) try c.w.print(
        "<a href=\"{f}\" class=\"link meta-item\">{s}replying to {f}</a>",
        .{ esc(try html.routeUrl(c, RoutablePage.repoThreadCommentRoute(kind, data.identity, thread_id, parent_id, 0))), icons.corner_down_right, esc(if (comment.parent_author) |parent| html.authorText(parent) else "a comment") },
    );
    try c.w.writeAll("<span class=\"comment-actions\">");
    if (data.viewer != null) try c.w.print(
        "<a href=\"{f}\" class=\"comment-action\">{s}Reply</a>",
        .{ esc(try html.routeUrl(c, RoutablePage.repoThreadCommentNewRoute(kind, data.identity, thread_id, &comment.id))), icons.message_square_reply },
    );
    if (comment.can_modify and !comment.comment.removed) {
        try c.w.print("<a href=\"{f}\" class=\"comment-action\">{s}Edit</a>", .{ esc(try html.routeUrl(c, RoutablePage.repoThreadCommentEditRoute(kind, data.identity, thread_id, &comment.id))), icons.pencil });
        try c.w.print("<a href=\"{f}\" class=\"comment-action\">{s}Remove</a>", .{ esc(try html.routeUrl(c, RoutablePage.repoThreadRemoveRoute(kind, data.identity, thread_id, &comment.id, ""))), icons.trash_2 });
    }
    try c.w.writeAll("</span></header><div class=\"comment-body\">");
    if (comment.comment.removed) try c.w.writeAll("<p class=\"removed\">(removed)</p>") else try markdown.render(c, comment.comment.event.body);
    try c.w.writeAll("</div></article>");
}

// previous and next comment windows: the thread's, or the replies to `selected`
fn pager(c: Ctx, comptime kind: evt.EventKind, identity: []const u8, thread_id: []const u8, selected: ?[]const u8, win: *const Comment.Window, label: []const u8) !void {
    const has_more = win.start < win.count and win.count - win.start > Comment.page_size;
    const previous = if (win.start > 0) try html.routeUrl(c, windowRoute(kind, identity, thread_id, selected, win.start -| Comment.page_size)) else null;
    const next = if (has_more) try html.routeUrl(c, windowRoute(kind, identity, thread_id, selected, win.start + Comment.page_size)) else null;
    try html.pager(c, label, previous, next);
}

fn windowRoute(comptime kind: evt.EventKind, identity: []const u8, thread_id: []const u8, selected: ?[]const u8, start: usize) ?RoutablePage {
    const id = selected orelse return RoutablePage.repoThreadCommentsRoute(kind, identity, thread_id, start);
    return RoutablePage.repoThreadCommentRoute(kind, identity, thread_id, id, start);
}

// a comment form posting to `action`, for a viewer who may write here
fn composer(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind), action: []const u8, label: []const u8, submit: []const u8) !void {
    const n = comptime threads.names(kind);
    if (data.viewer == null) {
        if (c.server() and !c.loggedIn()) try c.w.print(
            "<p class=\"mt-6 text-sm muted\"><a href=\"{s}\" class=\"link\">Log in</a> to comment on this {s}.</p>",
            .{ try html.url(c, .{ .home_user = .{} }), n.noun },
        );
        return;
    }
    try c.w.print("<form class=\"composer\" method=\"post\" action=\"{f}\">", .{esc(action)});
    try html.textArea(c, .{ .label = label, .name = "body", .rows = 4, .required = true, .hint = "Markdown." });
    try c.w.print("<div><button type=\"submit\" class=\"btn btn-sm\">{s}{s}</button></div></form>", .{ icons.message_square_plus, submit });
}

// a comment's own page: the comment, then a window of its replies and a reply form
pub fn permalink(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind), entry: *const Data(kind).Entry, page: *const Comment.Permalink) !void {
    const n = comptime threads.names(kind);
    const selected = &page.selected;
    const replies = &page.replies;
    const thread_url = try threads.threadUrl(c, kind, data.identity, entry.id);
    try c.w.writeAll("<article class=\"thread\">");
    try threads.backLink(c, thread_url, "Back to the " ++ n.noun);
    try c.w.print("<h2 class=\"thread-title mt-3\">Comment on <a href=\"{f}\" class=\"link\">{f}</a></h2><div class=\"mt-6\">", .{ esc(thread_url), esc(entry.record.event.title) });
    try card(c, kind, data, selected, true);
    try c.w.print("</div><section aria-labelledby=\"{s}-replies\" class=\"replies\"><h3 id=\"{s}-replies\" class=\"section-title\">{d} {s}</h3>", .{ n.plural, n.plural, replies.count, if (replies.count == 1) "reply" else "replies" });
    if (replies.comments.len != 0) {
        try c.w.writeAll("<ol aria-label=\"Replies\" class=\"comments\">");
        for (replies.comments) |*reply| {
            try c.w.writeAll("<li>");
            try card(c, kind, data, reply, false);
            try c.w.writeAll("</li>");
        }
        try c.w.writeAll("</ol>");
    }
    try pager(c, kind, data.identity, entry.id, &selected.id, replies, "Reply pages");
    try composer(
        c,
        kind,
        data,
        try html.routeUrl(c, RoutablePage.repoThreadCommentNewRoute(kind, data.identity, entry.id, &selected.id)),
        try c.arena.allocator().print("Reply to {s}", .{html.authorText(selected.author)}),
        "Reply",
    );
    try c.w.writeAll("</section></article>");
}
