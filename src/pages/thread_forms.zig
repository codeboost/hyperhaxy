const std = @import("std");
const haxy = @import("haxy");
const ui = haxy.ui;
const evt = haxy.event;
const RoutablePage = ui.RoutablePage;
const PatchFailure = ui.Session.FormFeedback.PatchFailure;
const html = @import("../html.zig");
const icons = @import("../icons.zig");
const comments = @import("comments.zig");
const patch = @import("patch.zig");
const threads = @import("threads.zig");
const Ctx = html.Ctx;
const esc = html.esc;
const Data = threads.Data;

// a thread tab's form view, each posting to haxy's own url for it
pub fn page(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind), form: threads.FormView) !void {
    // local mode always writes
    if (c.server() and data.viewer == null) return forbidden(c, kind);
    switch (form) {
        .new => try newThread(c, kind, data),
        .edit => try editThread(c, kind, data),
        .new_comment, .edit_comment => try commentForm(c, kind, data, form == .edit_comment),
        .remove => try remove(c, kind, data),
        .resolve => if (comptime @hasField(Data(kind), "conflict")) try resolve(c, kind, data) else unreachable,
        .publish => if (kind == .patch) try patch.publishConfirm(c, data) else unreachable,
        .merge => if (kind == .patch) try patch.mergeConfirm(c, data) else unreachable,
    }
}

fn forbidden(c: Ctx, comptime kind: evt.EventKind) !void {
    const n = comptime threads.names(kind);
    if (!c.loggedIn()) {
        try c.w.print(
            "<section class=\"medium\"><h2 class=\"title\">Log in to continue</h2><p class=\"mt-3 muted\"><a href=\"{s}\" class=\"link\">Log in</a> to write in this repository's {s}.</p></section>",
            .{ try html.url(c, .{ .home_user = .{} }), n.plural },
        );
        return;
    }
    try html.unavailable(c, "You can't write here", "Your role in this repository doesn't let you write in its " ++ n.plural ++ ".");
}

fn feedbackTag(comptime kind: evt.EventKind) std.meta.Tag(ui.Session.FormFeedback) {
    return switch (kind) {
        .issue => .issue,
        .discuss => .discussion,
        .patch => .patch,
        else => unreachable,
    };
}

// the failure of the thread form posted last, as a patch failure (the thread ones are a subset)
fn savedFailure(c: Ctx, comptime kind: evt.EventKind) ?PatchFailure {
    const saved = c.feedback(comptime feedbackTag(kind)) orelse return null;
    return std.meta.stringToEnum(PatchFailure, @tagName(saved.failure)) orelse unreachable;
}

fn failureText(failure: PatchFailure) []const u8 {
    return switch (failure) {
        .required_title => "Enter a title.",
        .invalid_target_branch => "There is no branch by that name to target.",
        .invalid_source_branch => "There is no source branch by that name.",
        .same_branch => "The source and target branches are the same.",
        .unrelated_branches => "The source and target branches share no history.",
    };
}

const Fields = struct {
    title: []const u8 = "",
    labels: []const u8 = "",
    description: []const u8 = "",
    target_branch: []const u8 = "",
    source_branch: []const u8 = "",
};

// the fields the last failed post retained, when it did
fn savedFields(c: Ctx, comptime kind: evt.EventKind) ?Fields {
    const saved = c.feedback(comptime feedbackTag(kind)) orelse return null;
    const fields = saved.fields orelse return null;
    var result: Fields = .{ .title = fields.title, .labels = fields.labels, .description = fields.description };
    if (kind == .patch) {
        result.target_branch = fields.target_branch;
        result.source_branch = fields.source_branch;
    }
    return result;
}

// title, labels and description, plus a patch's branches; `id_prefix` keeps a second form's ids apart
fn threadFields(c: Ctx, comptime kind: evt.EventKind, comptime id_prefix: []const u8, fields: Fields, failure: ?PatchFailure, source: bool) !void {
    if (failure) |value| try html.formError(c, failureText(value));
    try html.field(c, .{ .label = "Title", .name = "title", .id = id_prefix ++ "title", .value = fields.title, .invalid = failure == .required_title });
    try html.field(c, .{ .label = "Labels", .name = "labels", .id = id_prefix ++ "labels", .value = fields.labels, .hint = "Separate labels with spaces." });
    try html.textArea(c, .{ .label = "Description", .name = "description", .id = id_prefix ++ "description", .value = fields.description, .rows = 12, .hint = "Markdown." });
    if (kind == .patch) {
        const branches_failed = failure == .invalid_source_branch or failure == .same_branch or failure == .unrelated_branches;
        if (source) try html.field(c, .{
            .label = "Source branch",
            .name = "source_branch",
            .value = fields.source_branch,
            .invalid = branches_failed,
            .mono = true,
            .hint = "The branch whose commits the patch proposes; pushes to it update the patch.",
        });
        try html.field(c, .{
            .label = "Target branch",
            .name = "target_branch",
            .id = id_prefix ++ "target_branch",
            .value = fields.target_branch,
            .invalid = failure == .invalid_target_branch or (!source and branches_failed),
            .mono = true,
            .hint = "The branch the patch would be merged into.",
        });
    }
}

fn newThread(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind)) !void {
    const n = comptime threads.names(kind);
    const back = try threads.listUrl(c, kind, data.identity, std.enums.values(Data(kind).Status)[0], "");
    const action = try html.routeUrl(c, RoutablePage.repoThreadNewRoute(kind, data.identity));
    const saved = savedFields(c, kind);
    const failure = savedFailure(c, kind);
    // drafts live on a server, and a failed fork form comes back to its own form
    const fork_form = kind == .patch and c.server();
    const fork_failed = fork_form and forkFailed(c);
    var fields = if (fork_failed) Fields{} else saved orelse Fields{};
    if (kind == .patch and (saved == null or fork_failed)) fields.target_branch = data.default_target_branch;
    try c.w.writeAll("<section class=\"wide\">");
    try threads.backLink(c, back, n.title);
    try c.w.writeAll("<h2 class=\"title mt-3\">New " ++ n.noun ++ "</h2>");
    if (kind == .patch) try c.w.writeAll("<p class=\"mt-2 text-sm muted\">Propose a branch of this repository; pushes to it update the patch.</p>");
    try c.w.print("<form aria-label=\"New {s}\" class=\"form mt-6\" method=\"post\" action=\"{f}\">", .{ n.noun, esc(action) });
    try threadFields(c, kind, "", fields, if (fork_failed) null else failure, true);
    try c.w.print("<div class=\"actions\"><button type=\"submit\" class=\"btn\">{s}Create {s}</button><a href=\"{f}\" class=\"btn btn-ghost\">Cancel</a></div></form>", .{ icons.plus, n.noun, esc(back) });
    if (fork_form) {
        var fork_fields = if (fork_failed) saved orelse Fields{} else Fields{};
        if (!fork_failed) fork_fields.target_branch = data.default_target_branch;
        // a fork-backed draft is the same post without a source branch
        try c.w.print(
            \\<details class="disclosure mt-8"{s}><summary class="disclosure-summary">{s}No branch to propose from? Start with a new fork</summary><div class="disclosure-body"><p class="text-sm muted">Haxy copies the repository into a fork of your own, where you push your commits. The patch stays your draft until you publish it.</p><form aria-label="New draft" class="form mt-6" method="post" action="{f}">
        , .{ if (fork_failed) " open" else "", icons.git_fork, esc(action) });
        try threadFields(c, kind, "fork-", fork_fields, if (fork_failed) failure else null, false);
        try c.w.print("<div class=\"actions\"><button type=\"submit\" class=\"btn\">{s}Start with a new fork</button></div></form></div></details>", .{icons.git_fork});
    }
    try c.w.writeAll("</section>");
}

// whether the patch form that failed was the fork form, which sends no source branch
fn forkFailed(c: Ctx) bool {
    const saved = c.feedback(.patch) orelse return false;
    const fields = saved.fields orelse return false;
    return fields.source_kind == .fork;
}

fn editThread(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind)) !void {
    const n = comptime threads.names(kind);
    const entry = data.selectedThread() orelse return threads.notFound(c, kind, data);
    const event = &entry.record.event;
    const fields = savedFields(c, kind) orelse Fields{
        .title = event.title,
        .labels = event.labels,
        .description = event.description,
        .target_branch = switch (kind) {
            .patch => event.target_branch,
            else => "",
        },
    };
    const back = try threads.threadUrl(c, kind, data.identity, entry.id);
    try c.w.writeAll("<section class=\"wide\">");
    try threads.backLink(c, back, "Back to the " ++ n.noun);
    try c.w.print("<h2 class=\"title mt-3\">Edit {s}</h2><p class=\"mt-1 muted\">{f}</p>", .{ n.noun, esc(event.title) });
    try c.w.print("<form aria-label=\"Edit {s}\" class=\"form mt-6\" method=\"post\" action=\"{f}\">", .{ n.noun, esc(try html.routeUrl(c, RoutablePage.repoThreadEditRoute(kind, data.identity, entry.id))) });
    try threadFields(c, kind, "", fields, savedFailure(c, kind), false);
    try c.w.print("<div class=\"actions\"><button type=\"submit\" class=\"btn\">{s}Save changes</button><a href=\"{f}\" class=\"btn btn-ghost\">Cancel</a></div></form></section>", .{ icons.save, esc(back) });
}

// a new comment on the thread or a reply to a comment, or a comment's edit
fn commentForm(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind), editing: bool) !void {
    const n = comptime threads.names(kind);
    const entry = data.selectedThread() orelse return threads.notFound(c, kind, data);
    const thread_url = try threads.threadUrl(c, kind, data.identity, entry.id);
    try c.w.writeAll("<section class=\"wide\">");
    if (data.comment_page) |*comment_page| {
        const selected = &comment_page.selected;
        const comment_url = try html.routeUrl(c, RoutablePage.repoThreadCommentRoute(kind, data.identity, entry.id, &selected.id, 0));
        try threads.backLink(c, comment_url, "Back to the comment");
        if (editing) {
            try c.w.print("<h2 class=\"title mt-3\">Edit comment</h2><p class=\"mt-1 muted\">On <a href=\"{f}\" class=\"link\">{f}</a></p>", .{ esc(thread_url), esc(entry.record.event.title) });
        } else {
            try c.w.print("<h2 class=\"title mt-3\">Reply to {f}</h2><div class=\"mt-6\">", .{esc(html.authorText(selected.author))});
            try comments.card(c, kind, data, selected, false);
            try c.w.writeAll("</div>");
        }
        const action = if (editing)
            RoutablePage.repoThreadCommentEditRoute(kind, data.identity, entry.id, &selected.id)
        else
            RoutablePage.repoThreadCommentNewRoute(kind, data.identity, entry.id, &selected.id);
        try commentBody(c, try html.routeUrl(c, action), if (editing) selected.comment.event.body else "", if (editing) "Save comment" else "Reply", comment_url);
    } else {
        // an edit route always names its comment
        if (editing) unreachable;
        try threads.backLink(c, thread_url, "Back to the " ++ n.noun);
        try c.w.print("<h2 class=\"title mt-3\">Comment on {f}</h2>", .{esc(entry.record.event.title)});
        try commentBody(c, try html.routeUrl(c, RoutablePage.repoThreadCommentNewRoute(kind, data.identity, entry.id, "")), "", "Comment", thread_url);
    }
    try c.w.writeAll("</section>");
}

fn commentBody(c: Ctx, action: []const u8, body: []const u8, submit: []const u8, back: []const u8) !void {
    try c.w.print("<form class=\"form mt-6\" method=\"post\" action=\"{f}\">", .{esc(action)});
    try html.textArea(c, .{ .label = "Comment", .name = "body", .value = body, .rows = 8, .required = true, .hint = "Markdown." });
    try c.w.print("<div class=\"actions\"><button type=\"submit\" class=\"btn\">{s}{s}</button><a href=\"{f}\" class=\"btn btn-ghost\">Cancel</a></div></form>", .{ icons.message_square_plus, submit, esc(back) });
}

// haxy's confirmation before removing a thread, a comment or an attachment
fn remove(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind)) !void {
    const n = comptime threads.names(kind);
    const aa = c.arena.allocator();
    const entry = data.selectedThread() orelse return threads.notFound(c, kind, data);
    const attachment_id = c.session.current_page.threadAttachment();
    const thread_url = try threads.threadUrl(c, kind, data.identity, entry.id);
    const title: []const u8, const message: []const u8, const button: []const u8, const back: []const u8 = blk: {
        if (attachment_id.len != 0) {
            const name = for (entry.attachments) |*attachment| {
                if (std.mem.eql(u8, &attachment.id, attachment_id)) break attachment.name;
            } else return threads.notFound(c, kind, data);
            break :blk .{ "Remove attachment", try aa.print("Remove {s} from this {s}? It is removed for everyone.", .{ name, n.noun }), "Remove attachment", thread_url };
        }
        if (data.comment_id.len != 0) {
            const comment_url = try html.routeUrl(c, RoutablePage.repoThreadCommentRoute(kind, data.identity, entry.id, data.comment_id, 0));
            break :blk .{ "Remove comment", "Remove this comment? It shows as removed for everyone; its replies stay.", "Remove comment", comment_url };
        }
        break :blk .{ "Remove " ++ n.noun, "Remove this " ++ n.noun ++ "? It is removed for everyone, with its comments.", "Remove " ++ n.noun, thread_url };
    };
    const action = try html.routeUrl(c, RoutablePage.repoThreadRemoveRoute(kind, data.identity, entry.id, data.comment_id, attachment_id));
    try c.w.writeAll("<section class=\"medium\">");
    try threads.backLink(c, back, "Back");
    try c.w.print(
        \\<h2 class="title mt-3">{s}</h2><p class="mt-1 muted">{f}</p><div role="alertdialog" aria-labelledby="{s}-remove-message" class="confirm-box mt-6"><p id="{s}-remove-message" class="text-sm">{f}</p><form method="post" action="{f}" class="actions mt-3"><button type="submit" class="btn btn-destructive btn-sm">{s}{s}</button><a href="{f}" class="btn btn-outline btn-sm">Cancel</a></form></div></section>
    , .{ title, esc(entry.record.event.title), n.plural, n.plural, esc(message), esc(action), icons.trash_2, button, esc(back) });
}

// a thread's metadata conflict: each side of every conflicted field, and the values that settle it
fn resolve(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind)) !void {
    const n = comptime threads.names(kind);
    const entry = data.selectedThread() orelse return threads.notFound(c, kind, data);
    // haxy only picks the resolve view once it has read the conflict
    const conflict = if (data.conflict) |*value| value else unreachable;
    try c.w.writeAll("<section class=\"wide\">");
    try threads.backLink(c, try threads.threadUrl(c, kind, data.identity, entry.id), "Back to the " ++ n.noun);
    try c.w.print("<h2 class=\"title mt-3\">Resolve metadata conflict</h2><p class=\"mt-1 muted\">{f}</p>", .{esc(entry.record.event.title)});
    try c.w.writeAll("<p class=\"mt-4 text-sm muted\">This " ++ n.noun ++ "'s details were edited differently on two hosts. Each conflicting field shows both versions; “Use this” fills in a version, then resolving saves the values below.</p>");
    try c.w.print("<form aria-label=\"Resolve the conflict\" class=\"resolve-form mt-6\" method=\"post\" action=\"{f}/resolve\">", .{esc(try html.routeUrl(c, Data(kind).resolveRoute(data.identity, entry.id, data.theirs_picks)))});
    if (conflict.title) |*fc| try textConflict(c, kind, data, "title", "Title", fc);
    if (conflict.labels) |*fc| try textConflict(c, kind, data, "labels", "Labels", fc);
    if (kind == .patch) {
        if (conflict.status) |*fc| try choiceConflict(c, kind, data, "status", "Status", fc);
        if (conflict.revision) |*fc| try choiceConflict(c, kind, data, "revision", "Revision", fc);
        if (conflict.target_branch) |*fc| try choiceConflict(c, kind, data, "target_branch", "Target branch", fc);
    }
    if (conflict.description) |*description| {
        try c.w.writeAll("<fieldset class=\"conflict-field\"><legend class=\"conflict-legend\">Description</legend>");
        var part: usize = 0;
        for (description.chunks) |chunk| switch (chunk) {
            .same => |text| try c.w.print("<pre class=\"chunk-same\">{f}</pre>", .{esc(text)}),
            .auto => |auto| {
                const author = if (auto.theirs) description.theirs_author else description.ours_author;
                try c.w.print("<div class=\"chunk-auto\"><p class=\"text-xs muted\">Changed only on the {s} side, so it stands: edited by ", .{if (auto.theirs) "merged-in" else "current"});
                try html.author(c, author);
                try c.w.print("</p><pre class=\"side-text\">{f}</pre></div>", .{esc(auto.text orelse "(removed)")});
            },
            .conflict => |hunk| {
                const name = try c.arena.allocator().print("d{d}", .{part});
                part += 1;
                const theirs = data.theirsPicked(name);
                try c.w.print("<div role=\"group\" aria-label=\"Conflicting part {d}\" class=\"chunk-conflict\"><div class=\"sides\">", .{part});
                try side(c, "Current", description.ours_author, hunk.ours orelse "", try useUrl(c, kind, data, name, false), !theirs, "Prefilled");
                try side(c, "Merged in", description.theirs_author, hunk.theirs orelse "", try useUrl(c, kind, data, name, true), theirs, "Prefilled");
                try c.w.writeAll("</div>");
                try html.textArea(c, .{
                    .label = try c.arena.allocator().print("Resolved part {d}", .{part}),
                    .name = name,
                    .value = (if (theirs) hunk.theirs else hunk.ours) orelse "",
                    .rows = 4,
                    .hint = "Leave it empty to drop this part.",
                });
                try c.w.writeAll("</div>");
            },
        };
        try c.w.writeAll("</fieldset>");
    }
    try c.w.print("<div><button type=\"submit\" class=\"btn\">{s}Resolve conflict</button></div></form></section>", .{icons.check});
}

// a conflicted title or labels: both sides, and the text that resolves it
fn textConflict(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind), comptime name: []const u8, comptime label: []const u8, fc: anytype) !void {
    const theirs = data.theirsPicked(name);
    try c.w.writeAll("<fieldset class=\"conflict-field\"><legend class=\"conflict-legend\">" ++ label ++ "</legend><div class=\"sides\">");
    try side(c, "Current", fc.ours.author, fc.ours.text, try useUrl(c, kind, data, name, false), !theirs, "Prefilled");
    try side(c, "Merged in", fc.theirs.author, fc.theirs.text, try useUrl(c, kind, data, name, true), theirs, "Prefilled");
    try c.w.writeAll("</div>");
    try html.field(c, .{ .label = "Resolved " ++ comptime lower(label), .name = name, .value = if (theirs) fc.theirs.text else fc.ours.text });
    try c.w.writeAll("</fieldset>");
}

// a conflicted field that takes one side whole, picked through the url
fn choiceConflict(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind), comptime name: []const u8, comptime label: []const u8, fc: anytype) !void {
    const theirs = data.theirsPicked(name);
    try c.w.writeAll("<fieldset class=\"conflict-field\"><legend class=\"conflict-legend\">" ++ label ++ "</legend><div class=\"sides\">");
    try side(c, "Current", fc.ours.author, fc.ours.text, try useUrl(c, kind, data, name, false), !theirs, "Chosen");
    try side(c, "Merged in", fc.theirs.author, fc.theirs.text, try useUrl(c, kind, data, name, true), theirs, "Chosen");
    try c.w.writeAll("</div></fieldset>");
}

fn lower(comptime text: []const u8) []const u8 {
    comptime {
        var buf: [text.len]u8 = undefined;
        _ = std.ascii.lowerString(&buf, text);
        const result = buf;
        return &result;
    }
}

// one side of a conflict: who set it, its value, and the way to use it
fn side(c: Ctx, which: []const u8, author: ui.Author, text: []const u8, use_url: []const u8, picked: bool, picked_label: []const u8) !void {
    try c.w.print("<div role=\"group\" aria-label=\"{s}\" class=\"side-card{s}\"><div class=\"side-head\"><span class=\"text-sm\"><span class=\"strong\">{s}</span> <span class=\"text-xs muted\">edited by ", .{ which, if (picked) " picked" else "", which });
    try html.author(c, author);
    try c.w.writeAll("</span></span>");
    if (picked)
        try c.w.print("<span class=\"pill pill-primary\">{s}{s}</span>", .{ icons.check, picked_label })
    else
        try c.w.print("<a href=\"{f}\" class=\"btn btn-outline btn-sm\">Use this</a>", .{esc(use_url)});
    try c.w.print("</div><pre class=\"side-text\">{f}</pre></div>", .{esc(if (text.len == 0) "(empty)" else text)});
}

// the resolve page with `name` picked from their side or ours, as haxy's links flip it
fn useUrl(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind), name: []const u8, theirs: bool) ![]const u8 {
    var picks: std.ArrayList(u8) = .empty;
    const aa = c.arena.allocator();
    var iter = std.mem.splitScalar(u8, data.theirs_picks, ',');
    while (iter.next()) |pick| {
        if (pick.len == 0 or std.mem.eql(u8, pick, name)) continue;
        if (picks.items.len > 0) try picks.append(aa, ',');
        try picks.appendSlice(aa, pick);
    }
    if (theirs) {
        if (picks.items.len > 0) try picks.append(aa, ',');
        try picks.appendSlice(aa, name);
    }
    return html.routeUrl(c, Data(kind).resolveRoute(data.identity, data.selected_id, picks.items));
}
