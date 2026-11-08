const std = @import("std");
const haxy = @import("haxy");
const ui = haxy.ui;
const evt = haxy.event;
const RoutablePage = ui.RoutablePage;
const Settings = ui.Repo.Settings;
const Members = ui.Repo.Members;
const html = @import("../html.zig");
const icons = @import("../icons.zig");
const Ctx = html.Ctx;
const esc = html.esc;

const View = @FieldType(Settings, "view");

const role_choices = [_]html.Choice{
    .{ .value = "nobody", .label = "Nobody", .hint = "Turned off: the section is hidden." },
    .{ .value = "members", .label = "Members", .hint = "Owners and members." },
    .{ .value = "anybody", .label = "Anybody", .hint = "Anyone signed in who can read the repository." },
};

// the settings tab: a page list beside the page the route names
pub fn panel(c: Ctx, data: *const ui.Repo, settings: *const Settings) !void {
    const id = settings.identity;
    try c.w.writeAll("<div class=\"settings-layout\"><nav aria-label=\"Settings pages\" class=\"settings-nav\">");
    const views = [_]View{ .settings, .members, .branches, .delete };
    const labels = [_][]const u8{ "General", "Members", "Branches", "Delete" };
    for (views, labels) |view, label| {
        const route = switch (view) {
            .settings => RoutablePage.repoSettingsRoute(id),
            .members => RoutablePage.repoMembersRoute(id, 0),
            .branches => RoutablePage.repoBranchesRoute(id),
            .delete => if (settings.delete == null) continue else RoutablePage.repoDeleteRoute(id),
        };
        try c.w.print("<a href=\"{f}\" class=\"settings-link{s}\"{s}>{s}</a>", .{
            esc(try html.routeUrl(c, route)),
            if (view == .delete) " settings-danger" else "",
            if (view == settings.view) " aria-current=\"page\"" else "",
            label,
        });
    }
    try c.w.writeAll("</nav><div class=\"grow\">");
    switch (settings.view) {
        .settings => try general(c, settings),
        .members => try members(c, data, &settings.members),
        .branches => try branches(c, &settings.branches),
        .delete => if (settings.delete) |delete| try deleteForm(c, delete.target, try html.routeUrl(c, RoutablePage.repoDeleteRoute(id))),
    }
    try c.w.writeAll("</div></div>");
}

// the name, description, visibility and who may start each kind of thread
fn general(c: Ctx, settings: *const Settings) !void {
    const saved = c.feedback(.repo_settings);
    const failure = if (saved) |value| value.failure else null;
    const fields = if (saved) |value| value.fields else @FieldType(@FieldType(ui.Session.FormFeedback, "repo_settings"), "fields"){
        .name = settings.name,
        .description = settings.description,
        .access = settings.access,
        .discuss_role = settings.discuss_role,
        .issue_role = settings.issue_role,
        .patch_role = settings.patch_role,
    };
    try c.w.print(
        \\<section aria-labelledby="general-heading" class="medium"><h2 id="general-heading" class="subtitle">General</h2><form aria-label="Repository settings" class="form mt-6" method="post" action="{f}">
    , .{esc(try html.routeUrl(c, RoutablePage.repoSettingsRoute(settings.identity)))});
    if (failure) |value| try html.formError(c, switch (value) {
        .required_name => "Enter a name.",
        .invalid_name => "Names are letters, digits, hyphens, underscores and dots.",
        .name_taken => "You already have a repository with that name.",
        .invalid_copy => "There is no repository you can read by that name.",
    });
    try html.field(c, .{
        .label = "Name",
        .name = "name",
        .value = fields.name,
        .invalid = failure != null,
        .hint = "Renaming changes the repository's urls.",
    });
    try html.field(c, .{ .label = "Description", .name = "description", .value = fields.description });
    try html.radios(c, "Visibility", "access", &.{
        .{ .value = "private", .label = "Private", .hint = "Only owners and the members they add can see it." },
        .{ .value = "public", .label = "Public", .hint = "Anyone can see and clone it." },
    }, @tagName(fields.access), "");
    try html.radios(c, "Who can start discussions", "discuss_role", &role_choices, Settings.roleLabel(fields.discuss_role), "");
    try html.radios(c, "Who can open issues", "issue_role", &role_choices, Settings.roleLabel(fields.issue_role), "");
    try html.radios(c, "Who can propose patches", "patch_role", &role_choices, Settings.roleLabel(fields.patch_role), "");
    try c.w.print(
        \\<div><p class="label">Hash format</p><p class="mt-1 text-sm"><span class="mono">{s}</span><span class="choice-hint">Chosen when the repository was created; it can't be changed.</span></p></div><div><button type="submit" class="btn">{s}Save settings</button></div></form></section>
    , .{ switch (settings.hash_kind) {
        .sha1 => "SHA-1",
        .sha256 => "SHA-256",
    }, icons.save });
}

// a members route acting on `name`, asking first when `confirm` is set
fn memberRoute(identity: []const u8, start: usize, name: []const u8, confirm: ?Members.Action) !RoutablePage {
    var route = RoutablePage.repoMembersRoute(identity, start) orelse return error.RouteTooLong;
    route.repo_members.user = RoutablePage.Array(evt.User.name_max_len).from(name) orelse return error.RouteTooLong;
    route.repo_members.confirm = confirm;
    return route;
}

// the main owner, then a window of the members, each with its role's actions
fn members(c: Ctx, data: *const ui.Repo, win: *const Members) !void {
    const list_url = try html.routeUrl(c, RoutablePage.repoMembersRoute(win.identity, win.start));
    try c.w.writeAll("<section aria-labelledby=\"members-heading\" class=\"wide\"><h2 id=\"members-heading\" class=\"subtitle\">Members</h2>");
    if (win.confirm) |confirm| {
        const self = if (c.session.user_name) |name| std.mem.eql(u8, name, confirm.name) else false;
        const question = switch (confirm.action) {
            .demote => if (self)
                "Demote yourself to member? You'll no longer manage this repository."
            else
                try c.arena.allocator().print("Demote {s} to member? They'll no longer manage this repository.", .{confirm.name}),
            else => if (self)
                "Remove yourself? You'll lose the access this repository gives its members."
            else
                try c.arena.allocator().print("Remove {s}? They lose the access this repository gives its members.", .{confirm.name}),
        };
        const confirm_url = try html.url(c, try memberRoute(win.identity, win.start, confirm.name, confirm.action));
        try c.w.print(
            \\<div role="alertdialog" aria-labelledby="member-confirm" class="confirm-box mt-6"><p id="member-confirm" class="text-sm">{f}</p><form method="post" action="{f}" class="actions mt-3"><button type="submit" class="btn btn-destructive btn-sm">{s}{s}</button><a href="{f}" class="btn btn-outline btn-sm">Cancel</a></form></div></section>
        , .{ esc(question), esc(confirm_url), icons.user_minus, if (confirm.action == .demote) "Demote to member" else "Remove", esc(list_url) });
        return;
    }

    try c.w.writeAll("<p class=\"mt-1 text-sm muted\"><strong class=\"strong\">Members</strong> can push to this repository. <strong class=\"strong\">Owners</strong> can also manage its settings, members and branches.</p>");
    const saved = c.feedback(.repo_members);
    try c.w.print("<form aria-label=\"Add a member\" class=\"inline-form mt-6\" method=\"post\" action=\"{f}/grant\">", .{esc(list_url)});
    if (saved) |value| try html.formError(c, switch (value.failure) {
        .not_found => "No account has that name.",
        .already_added => "They're a member already.",
    });
    try c.w.print(
        \\<label class="label" for="member-name">Add a member</label><div class="inline-row"><input class="input" id="member-name" name="name" value="{f}" placeholder="Username" autocomplete="off" autocapitalize="none" spellcheck="false"{s}><button type="submit" class="btn btn-outline">{s}Add</button></div></form>
    , .{ esc(if (saved) |value| value.name else ""), if (saved != null) " aria-invalid=\"true\"" else "", icons.user_plus });

    try c.w.writeAll("<ul aria-label=\"Members\" class=\"list\">");
    if (win.start == 0 and data.header.owner_name.len != 0) try c.w.print(
        \\<li class="row row-split"><a href="{f}" class="link strong">{f}</a><span class="pill">{s}Main owner</span></li>
    , .{ esc(try html.userUrl(c, data.header.owner_name)), esc(data.header.owner_name), icons.crown });
    for (win.rows) |member| {
        const row_url = try html.url(c, try memberRoute(win.identity, win.start, member.name, null));
        const owner = member.role == .owner;
        try c.w.print(
            \\<li class="row row-split"><span class="row-head"><a href="{f}" class="link">{f}</a><span class="pill">{s}</span></span><span class="actions">
        , .{ esc(try html.userUrl(c, member.name)), esc(member.name), if (owner) "Owner" else "Member" });
        // taking a role away asks first
        if (owner) {
            try c.w.print("<a href=\"{f}\" class=\"btn btn-outline btn-sm\" aria-label=\"Demote {f} to member\">Demote to member</a>", .{ esc(try html.url(c, try memberRoute(win.identity, win.start, member.name, .demote))), esc(member.name) });
        } else try c.w.print("<form method=\"post\" action=\"{f}/promote\"><button type=\"submit\" class=\"btn btn-outline btn-sm\" aria-label=\"Promote {f} to owner\">Promote to owner</button></form>", .{ esc(row_url), esc(member.name) });
        try c.w.print("<a href=\"{f}\" class=\"btn btn-outline btn-sm\" aria-label=\"Remove {f}\">{s}Remove</a></span></li>", .{ esc(try html.url(c, try memberRoute(win.identity, win.start, member.name, .revoke))), esc(member.name), icons.user_minus });
    }
    try c.w.writeAll("</ul>");
    if (win.rows.len == 0 and win.start == 0) try c.w.writeAll("<p class=\"mt-3 text-sm muted\">No one else is a member yet.</p>");
    const previous = if (win.start > 0) try html.routeUrl(c, RoutablePage.repoMembersRoute(win.identity, win.start -| Members.page_size)) else null;
    const next = if (win.next_start) |start| try html.routeUrl(c, RoutablePage.repoMembersRoute(win.identity, start)) else null;
    try html.pager(c, "Member pages", previous, next);
    try c.w.writeAll("</section>");
}

fn branchesFailure(failure: ui.Session.FormFeedback.BranchesFailure) []const u8 {
    return switch (failure) {
        .not_found => "There is no branch by that name.",
        .already_added => "That branch is protected already.",
        .too_many => "As many branches are protected as allowed. Unprotect one first.",
        .too_long => "That branch name is too long.",
    };
}

// the default branch, then the protected branches
fn branches(c: Ctx, data: *const ui.Repo.Branches) !void {
    const aa = c.arena.allocator();
    const list_url = try html.routeUrl(c, RoutablePage.repoBranchesRoute(data.identity));
    const saved = c.feedback(.repo_branches);
    const default_failure = if (saved) |value| if (value.default) value.failure else null else null;
    const protect_failure = if (saved) |value| if (value.default) null else value.failure else null;
    try c.w.writeAll("<section aria-labelledby=\"branches-heading\" class=\"wide\"><h2 id=\"branches-heading\" class=\"subtitle\">Branches</h2>");

    try c.w.print("<form aria-label=\"Default branch\" class=\"inline-form mt-6\" method=\"post\" action=\"{f}/default\">", .{esc(list_url)});
    if (default_failure) |value| try html.formError(c, branchesFailure(value));
    try c.w.print(
        \\<label class="label" for="default-branch">Default branch</label><div class="inline-row"><input class="input mono" id="default-branch" name="name" value="{f}" autocomplete="off" autocapitalize="none" spellcheck="false"{s}><button type="submit" class="btn btn-outline">{s}Save</button></div><p class="hint">What the repository page shows and clones check out.</p></form>
    , .{
        esc(if (saved) |value| (if (value.default) value.name else data.default_branch) else data.default_branch),
        if (default_failure != null) " aria-invalid=\"true\"" else "",
        icons.save,
    });

    try c.w.writeAll("<h3 class=\"mt-10 strong\">Protected branches</h3><p class=\"mt-1 text-sm muted\">Protected branches can't be deleted or force-pushed. Owners can push to them directly; members can only change them by merging a patch.</p>");
    try c.w.print("<form aria-label=\"Protect a branch\" class=\"inline-form mt-4\" method=\"post\" action=\"{f}/protect\">", .{esc(list_url)});
    if (protect_failure) |value| try html.formError(c, branchesFailure(value));
    try c.w.print(
        \\<label class="label" for="protect-branch">Protect a branch</label><div class="inline-row"><input class="input mono" id="protect-branch" name="name" value="{f}" autocomplete="off" autocapitalize="none" spellcheck="false"{s}><button type="submit" class="btn btn-outline">{s}Protect</button></div></form>
    , .{
        esc(if (saved) |value| (if (value.default) "" else value.name) else ""),
        if (protect_failure != null) " aria-invalid=\"true\"" else "",
        icons.shield_check,
    });

    if (data.names.len == 0) {
        try c.w.writeAll("<p class=\"mt-4 text-sm muted\">No branch is protected.</p></section>");
        return;
    }
    try c.w.writeAll("<ul aria-label=\"Protected branches\" class=\"list\">");
    for (data.names) |branch| {
        const encoded = try ui.urlEncodeRef(aa, branch);
        var route = RoutablePage.repoBranchesRoute(data.identity) orelse return error.RouteTooLong;
        route.repo_branches.branch = RoutablePage.Array(RoutablePage.ref_route_max_len).from(encoded) orelse return error.RouteTooLong;
        try c.w.print(
            \\<li class="row row-split"><a href="{f}" class="link mono">{f}</a><form method="post" action="{f}/unprotect"><button type="submit" class="btn btn-outline btn-sm" aria-label="Unprotect {f}">{s}Unprotect</button></form></li>
        , .{
            esc(try html.routeUrl(c, RoutablePage.repoFilesRoute(data.identity, .branch, encoded, "", 0))),
            esc(branch),
            esc(try html.url(c, route)),
            esc(branch),
            icons.shield_off,
        });
    }
    try c.w.writeAll("</ul></section>");
}

// the danger zone deleting a repo, fork or account, posting under its delete page's url
pub fn deleteForm(c: Ctx, target: ui.Delete.Target, page_url: []const u8) !void {
    const saved = if (c.feedback(.delete)) |value| if (value.target == std.meta.activeTag(target)) value else null else null;
    const noun, const lead, const what, const after: []const u8 = switch (target) {
        .repo => .{ "repository", "", ": its files and history, every branch and tag, its issues, discussions and patches, and the access it gives its members.", "Copies people have already cloned keep what they hold. This can't be undone." },
        .fork => .{ "fork", "the fork ", " and everything pushed to it. A draft goes with it; a published patch stays, but can't be merged or pushed to any more.", "Copies people have already cloned keep what they hold. This can't be undone." },
        .user => .{ "account", "the account ", " and every repository and fork you own, with all of their history, issues, discussions and patches.", "You won't be able to log in again, your SSH keys stop working, and this can't be undone." },
    };
    const confirm_text = target.confirmText();
    try c.w.print(
        \\<section aria-labelledby="delete-heading" class="danger"><h2 id="delete-heading" class="danger-title">Delete {s}</h2><div class="mt-3 text-sm muted"><p>This permanently deletes {s}<strong class="strong">{f}</strong>{s}</p><p class="mt-2">{s}</p></div>
        \\<form aria-label="Delete {s}" class="form mt-6 narrow" method="post" action="{f}/delete">
    , .{ noun, lead, esc(confirm_text), what, after, noun, esc(page_url) });
    if (saved) |value| try html.formError(c, switch (value.failure) {
        .wrong_confirm => "The name you typed doesn't match.",
        .wrong_password => "That password is wrong.",
    });
    try html.field(c, .{
        .label = try c.arena.allocator().print("Type {s} to confirm", .{confirm_text}),
        .name = "confirm",
        .value = if (saved) |value| value.confirm else "",
        .invalid = if (saved) |value| value.failure == .wrong_confirm else false,
    });
    try html.field(c, .{
        .label = "Password",
        .name = "password",
        .type = "password",
        .invalid = if (saved) |value| value.failure == .wrong_password else false,
        .autocomplete = "current-password",
    });
    try c.w.print("<div><button type=\"submit\" class=\"btn btn-destructive\">{s}Permanently delete this {s}</button></div></form></section>", .{ icons.trash_2, noun });
}
