const std = @import("std");
const haxy = @import("haxy");
const ui = haxy.ui;
const html = @import("../html.zig");
const icons = @import("../icons.zig");
const Ctx = html.Ctx;
const esc = html.esc;

// the new repo form, which posts to its own page
pub fn page(c: Ctx, route: ui.RoutablePage) !void {
    if (!c.server()) return html.unavailable(c, "New repository", "Local mode serves a single repository without accounts, so it can't create others.");
    const name = c.session.user_name orelse {
        try c.w.print(
            \\<section class="medium"><h1 class="title">New repository</h1><p class="mt-3 muted"><a href="{f}" class="link">Log in</a> to create a repository.</p></section>
        , .{esc(try html.url(c, .{ .home_user = .{} }))});
        return;
    };

    const saved = c.feedback(.repo);
    const failure = if (saved) |value| value.failure else null;
    try c.w.print(
        \\<section class="medium"><h1 class="title">New repository</h1><p class="mt-3 text-sm muted">Owned by <strong class="strong">{f}</strong>.</p>
        \\<form aria-label="New repository" class="form mt-8" method="post" action="{f}">
    , .{ esc(name), esc(try html.url(c, route)) });
    if (failure) |value| try html.formError(c, switch (value) {
        .required_name => "Enter a name.",
        .invalid_name => "Names are letters, digits, hyphens, underscores and dots.",
        .name_taken => "You already have a repository with that name.",
        .invalid_copy => "There is no repository you can read by that owner:name.",
    });
    try html.field(c, .{
        .label = "Name",
        .name = "name",
        .value = if (saved) |value| value.fields.name else "",
        .invalid = failure == .required_name or failure == .invalid_name or failure == .name_taken,
        .hint = "Letters, digits, hyphens, underscores and dots.",
    });
    try html.field(c, .{ .label = "Description", .name = "description", .value = if (saved) |value| value.fields.description else "" });
    try html.radios(c, "Visibility", "access", &.{
        .{ .value = "private", .label = "Private", .hint = "Only you and the members you add can see it." },
        .{ .value = "public", .label = "Public", .hint = "Anyone can see and clone it." },
    }, if (saved) |value| @tagName(value.fields.access) else "private", "");
    try html.field(c, .{
        .label = "Copy from (optional)",
        .name = "copy",
        .value = if (saved) |value| value.fields.copy else "",
        .invalid = failure == .invalid_copy,
        .placeholder = "owner:name",
        .hint = "A repository you can read, as owner:name. The copy starts with its files and history, without its issues, discussions or patches.",
    });
    try html.radios(c, "Hash format", "hash", &.{
        .{ .value = "sha1", .label = "SHA-1", .hint = "Works with every Git client." },
        .{ .value = "sha256", .label = "SHA-256", .hint = "Needs Git 2.29 or later, and Git hosts that support it." },
    }, if (saved) |value| @tagName(value.fields.hash) else "sha1", "A copy keeps the hash format of the repository it copies.");
    try c.w.print("<div><button type=\"submit\" class=\"btn\">{s}Create repository</button></div></form></section>", .{icons.plus});
}
