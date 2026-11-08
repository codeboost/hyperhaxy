const std = @import("std");
const haxy = @import("haxy");
const ui = haxy.ui;
const evt = haxy.event;
const html = @import("../html.zig");
const icons = @import("../icons.zig");
const Ctx = html.Ctx;
const esc = html.esc;

const no_accounts = "Local mode serves a single repository without accounts.";

// a page's user tab: the login form, or the viewer's notifications and settings
pub fn userTab(c: Ctx, data: *const ui.UserNotifications, route: ui.RoutablePage) !void {
    if (!c.server()) return html.unavailable(c, "Account", no_accounts);
    if (!c.loggedIn()) return login(c, route);
    const view = route.userTab().view;
    if (view == .notifications) return notifications(c, data, route);

    const name = c.session.user_name orelse unreachable;
    try c.w.print("<h1 class=\"title\">Account</h1><p class=\"mt-2 muted\">Signed in as <strong class=\"strong\">{f}</strong>.</p>", .{esc(name)});
    try c.w.writeAll("<nav aria-label=\"Account sections\" class=\"tabs mt-6\">");
    for ([_]ui.RoutablePage.UserView{ .settings, .keys, .delete }, [_][]const u8{ "Settings", "SSH keys", "Delete account" }) |tab_view, label| {
        const href = try html.url(c, route.withUserTab(.{ .view = tab_view }));
        try c.w.print("<a href=\"{f}\" class=\"tab\"{s}>{s}</a>", .{ esc(href), if (tab_view == view) " aria-current=\"page\"" else "", label });
    }
    try c.w.writeAll("</nav><div class=\"mt-8\">");
    switch (view) {
        .settings => try settings(c, route),
        .keys => try keys(c, &data.ssh_keys, route),
        .delete => try delete(c, route),
        .notifications => unreachable,
    }
    try c.w.writeAll("</div>");
}

fn login(c: Ctx, route: ui.RoutablePage) !void {
    // the form posts under the page's default user tab, which a failure returns to
    const action = try html.url(c, route.withUserTab(.{}));
    const saved = c.feedback(.login);
    try c.w.print(
        \\<section class="narrow"><h1 class="title">Log in</h1><p class="mt-3 text-sm muted">Use your haxy account. No account yet? <a href="{f}" class="link">Create one</a>.</p>
        \\<form class="form mt-8" method="post" action="{f}/login">
    , .{ esc(try html.url(c, .home_user_new)), esc(action) });
    if (saved) |value| try html.formError(c, switch (value.failure) {
        .unknown_user => "There is no user with that name.",
        .wrong_password => "That password is wrong.",
    });
    try html.field(c, .{
        .label = "Username",
        .name = "username",
        .value = if (saved) |value| value.username else "",
        .invalid = if (saved) |value| value.failure == .unknown_user else false,
        .autocomplete = "username",
    });
    try html.field(c, .{
        .label = "Password",
        .name = "password",
        .type = "password",
        .invalid = if (saved) |value| value.failure == .wrong_password else false,
        .autocomplete = "current-password",
    });
    try c.w.writeAll("<button type=\"submit\" class=\"btn btn-block\">Log in</button></form></section>");
}

// the register form, which posts to its own page
pub fn register(c: Ctx, route: ui.RoutablePage) !void {
    if (!c.server()) return html.unavailable(c, "Create an account", no_accounts);
    if (c.session.user_name) |name| {
        try c.w.print(
            \\<section class="medium"><h1 class="title">Already logged in</h1><p class="mt-3 muted">You are logged in as <strong class="strong">{f}</strong>. Log out to create another account.</p><a href="{f}" class="link inline-block mt-6 text-sm">Your account</a></section>
        , .{ esc(name), esc(try html.url(c, .{ .home_user = .{ .view = .settings } })) });
        return;
    }
    const saved = c.feedback(.user);
    try c.w.print(
        \\<section class="narrow"><h1 class="title">Create an account</h1><p class="mt-3 text-sm muted">Already have one? <a href="{f}" class="link">Log in</a>.</p>
        \\<form class="form mt-8" method="post" action="{f}">
    , .{ esc(try html.url(c, .{ .home_user = .{} })), esc(try html.url(c, route)) });
    const failure = if (saved) |value| value.failure else null;
    if (failure) |value| try html.formError(c, userFailureText(value));
    try html.field(c, .{
        .label = "Username",
        .name = "name",
        .value = if (saved) |value| value.fields.name else "",
        .invalid = failure == .required_name or failure == .invalid_name or failure == .name_taken,
        .autocomplete = "username",
    });
    try html.field(c, .{
        .label = "Email",
        .name = "email",
        .type = "email",
        .value = if (saved) |value| value.fields.email else "",
        .invalid = failure == .required_email or failure == .email_taken,
        .autocomplete = "email",
    });
    try html.field(c, .{ .label = "Password", .name = "password", .type = "password", .invalid = failure == .required_password, .autocomplete = "new-password" });
    try html.field(c, .{ .label = "Confirm password", .name = "password_again", .type = "password", .invalid = failure == .password_mismatch, .autocomplete = "new-password" });
    try c.w.writeAll("<button type=\"submit\" class=\"btn btn-block\">Create account</button></form></section>");
}

fn userFailureText(failure: ui.Session.FormFeedback.UserFailure) []const u8 {
    return switch (failure) {
        .required_name => "Enter a username.",
        .invalid_name => "Usernames are 3 to 32 letters, digits and single hyphens, not starting or ending with a hyphen.",
        .name_taken => "That username is taken.",
        .required_email => "Enter an email address.",
        .email_taken => "That email address belongs to another account.",
        .required_password => "Enter a password.",
        .password_mismatch => "The passwords don't match.",
        .wrong_password => "The current password is wrong.",
    };
}

fn notifications(c: Ctx, data: *const ui.UserNotifications, route: ui.RoutablePage) !void {
    const unread = c.session.unread_notifs;
    try c.w.writeAll("<h1 class=\"title\">Notifications</h1>");
    if (unread == 0)
        try c.w.writeAll("<p class=\"mt-2 muted\">Everything is read.</p>")
    else
        try c.w.print("<p class=\"mt-2 muted\">{d} unread.</p>", .{unread});

    if (data.rows.len == 0) {
        if (data.start == 0) {
            try html.empty(c, "No notifications", "Activity by others on threads you opened, are assigned to, commented on or subscribed to shows here.");
        } else {
            try html.empty(c, "No more notifications", "");
        }
    } else {
        try c.w.writeAll("<ul aria-label=\"Notifications\" class=\"list\">");
        for (data.rows) |row| {
            try c.w.print(
                \\<li class="row notif{s}"><span class="dot-slot" aria-hidden="true">{s}</span><div class="grow"><a href="{f}" class="notif-title{s}">{f}</a>{s}<div class="row-meta"><span>{f}</span>{s}</div></div></li>
            , .{
                if (row.unread) " row-unread" else "",
                if (row.unread) "<span class=\"dot\"></span>" else "",
                esc(row.url),
                if (row.unread) " unread" else "",
                esc(row.title),
                if (row.unread) "<span class=\"sr-only\"> (unread)</span>" else "",
                esc(row.identity),
                if (row.unread) "<span class=\"pill pill-primary\">Unread</span>" else "",
            });
        }
        try c.w.writeAll("</ul>");
    }

    const previous = if (data.start > 0) try html.url(c, route.withUserTab(.{ .start = data.start -| ui.UserNotifications.page_size })) else null;
    const next = if (data.next_start) |start| try html.url(c, route.withUserTab(.{ .start = start })) else null;
    try html.pager(c, "Notification pages", previous, next);
}

fn settings(c: Ctx, route: ui.RoutablePage) !void {
    const saved = c.feedback(.user_settings);
    const failure = if (saved) |value| value.failure else null;
    try c.w.print("<form class=\"form narrow\" method=\"post\" action=\"{f}/user\">", .{esc(try html.url(c, route.withUserTab(.{ .view = .settings })))});
    if (failure) |value| try html.formError(c, switch (value) {
        .required_password => "Enter a new password.",
        else => userFailureText(value),
    });
    try c.w.writeAll("<h2 class=\"subtitle\">Email address</h2>");
    try html.field(c, .{
        .label = "Email",
        .name = "email",
        .type = "email",
        .value = if (saved) |value| value.fields.email else c.session.user_email orelse "",
        .invalid = failure == .required_email or failure == .email_taken,
        .autocomplete = "email",
    });
    try c.w.print(
        \\<h2 class="subtitle mt-4">Password</h2><p class="hint">Fill in all three to change it, or leave them empty.</p>
        \\<input type="text" name="username" autocomplete="username" value="{f}" readonly hidden>
    , .{esc(c.session.user_name orelse "")});
    try html.field(c, .{ .label = "Current password", .name = "current_password", .type = "password", .invalid = failure == .wrong_password, .autocomplete = "current-password" });
    try html.field(c, .{ .label = "New password", .name = "new_password", .type = "password", .invalid = failure == .required_password, .autocomplete = "new-password" });
    try html.field(c, .{ .label = "Confirm new password", .name = "new_password_again", .type = "password", .invalid = failure == .password_mismatch, .autocomplete = "new-password" });
    try c.w.writeAll("<div><button type=\"submit\" class=\"btn\">Save changes</button></div></form>");
}

// a key's comment, or its type when it has none
fn keyLabel(key: []const u8) []const u8 {
    var tokens = std.mem.tokenizeAny(u8, key, " \t");
    const key_type = tokens.next() orelse return "";
    _ = tokens.next();
    const comment = std.mem.trim(u8, tokens.rest(), " \t");
    return if (comment.len > 0) comment else key_type;
}

fn keys(c: Ctx, data: *const ui.UserKeys, route: ui.RoutablePage) !void {
    const keys_url = try html.url(c, route.withUserTab(.{ .view = .keys }));
    if (data.confirm) |key| {
        const fingerprint = evt.User.fingerprintOfKey(key) orelse unreachable;
        // the confirmation posts to its own url
        try c.w.print(
            \\<section class="wide"><h2 class="subtitle">Remove SSH key</h2><div class="confirm-box mt-4"><p class="text-sm">Remove <strong>{f}</strong>? Git over SSH with it stops working.</p><p class="mt-1 mono text-xs muted">{f}</p>
            \\<form class="actions mt-3" method="post" action="{f}"><button type="submit" class="btn btn-destructive btn-sm">Remove key</button><a href="{f}" class="btn btn-outline btn-sm">Cancel</a></form></div></section>
        , .{ esc(keyLabel(key)), esc(&fingerprint), esc(try html.url(c, route)), esc(keys_url) });
        return;
    }

    try c.w.print(
        \\<section class="wide"><h2 class="subtitle">SSH keys</h2><p class="mt-1 text-sm muted">Keys that may push to your repositories over SSH. Fingerprints are the SHA256 form <code class="inline">ssh-keygen -l</code> prints.</p>
        \\<form class="form mt-4" method="post" action="{f}/addkey">
    , .{esc(keys_url)});
    const saved = c.feedback(.user_keys);
    if (saved) |value| try html.formError(c, switch (value.failure) {
        .invalid => "That isn't a valid OpenSSH public key.",
        .unsupported => "That key type isn't supported.",
        .already_added => "You have already added that key.",
        .too_many => "You have as many keys as allowed. Remove one first.",
    });
    try html.field(c, .{
        .label = "Public key",
        .name = "key",
        .value = if (saved) |value| value.key else "",
        .invalid = saved != null,
        .placeholder = "ssh-ed25519 AAAA… you@host",
        .mono = true,
    });
    try c.w.print("<div><button type=\"submit\" class=\"btn\">{s}Add key</button></div></form>", .{icons.key_round});

    if (data.keys.len == 0) {
        try c.w.writeAll("<p class=\"mt-6 text-sm muted\">You have no SSH keys.</p></section>");
        return;
    }
    try c.w.writeAll("<ul aria-label=\"SSH keys\" class=\"list\">");
    for (data.keys) |key| {
        const fingerprint = evt.User.fingerprintOfKey(key) orelse continue;
        const fingerprint_array = ui.RoutablePage.Array(evt.User.fingerprint_len).from(&fingerprint) orelse unreachable;
        const remove_url = try html.url(c, route.withUserTab(.{ .view = .keys, .key = fingerprint_array, .remove_key = true }));
        const label = keyLabel(key);
        var tokens = std.mem.tokenizeAny(u8, key, " \t");
        const key_type = tokens.next() orelse "";
        try c.w.print(
            \\<li class="row"><div class="row-split"><div class="grow"><p class="strong mono">{f}</p><p class="mt-1 mono text-xs muted">{f}</p>
        , .{ esc(label), esc(&fingerprint) });
        if (!std.mem.eql(u8, label, key_type)) try c.w.print("<p class=\"mt-1 text-xs muted\">{f}</p>", .{esc(key_type)});
        try c.w.print(
            \\</div><a href="{f}" class="btn btn-outline btn-sm" aria-label="Remove {f}">{s}Remove</a></div></li>
        , .{ esc(remove_url), esc(label), icons.trash_2 });
    }
    try c.w.writeAll("</ul></section>");
}

fn delete(c: Ctx, route: ui.RoutablePage) !void {
    const name = c.session.user_name orelse unreachable;
    const saved = if (c.feedback(.delete)) |value| if (value.target == .user) value else null else null;
    try c.w.print(
        \\<section class="danger"><h2 class="danger-title">Delete account</h2><div class="mt-3 text-sm muted"><p>This permanently deletes the account <strong class="strong">{f}</strong> and every repository and fork you own, with all of their history, issues, discussions and patches.</p><p class="mt-2">You won't be able to log in again, your SSH keys stop working, and this can't be undone.</p></div>
        \\<form class="form mt-6 narrow" method="post" action="{f}/delete">
    , .{ esc(name), esc(try html.url(c, route.withUserTab(.{ .view = .delete }))) });
    if (saved) |value| try html.formError(c, switch (value.failure) {
        .wrong_confirm => "The name you typed doesn't match.",
        .wrong_password => "That password is wrong.",
    });
    try html.field(c, .{
        .label = try c.arena.allocator().print("Type {s} to confirm", .{name}),
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
    try c.w.writeAll("<div><button type=\"submit\" class=\"btn btn-destructive\">Permanently delete this account</button></div></form></section>");
}
