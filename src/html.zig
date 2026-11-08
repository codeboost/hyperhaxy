const std = @import("std");
const haxy = @import("haxy");
const ui = haxy.ui;
const icons = @import("icons.zig");

// what every render function writes with
pub const Ctx = struct {
    w: *std.Io.Writer,
    arena: *std.heap.ArenaAllocator,
    session: *const ui.Session.Data,

    pub fn loggedIn(c: Ctx) bool {
        return c.session.user_id != null;
    }

    pub fn server(c: Ctx) bool {
        return c.session.host_kind == .server;
    }

    // the failed form retained for this page, when it is of kind `tag`
    pub fn feedback(c: Ctx, comptime tag: std.meta.Tag(ui.Session.FormFeedback)) ?@FieldType(ui.Session.FormFeedback, @tagName(tag)) {
        const f = c.session.form_feedback orelse return null;
        return if (f == tag) @field(f, @tagName(tag)) else null;
    }
};

// text escaped for html content and quoted attributes, printed with {f}
pub const Escaped = struct {
    s: []const u8,

    pub fn format(self: Escaped, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var start: usize = 0;
        for (self.s, 0..) |ch, i| {
            const entity: []const u8 = switch (ch) {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                '"' => "&quot;",
                '\'' => "&#39;",
                else => continue,
            };
            try w.writeAll(self.s[start..i]);
            try w.writeAll(entity);
            start = i + 1;
        }
        try w.writeAll(self.s[start..]);
    }
};

pub fn esc(s: []const u8) Escaped {
    return .{ .s = s };
}

pub fn url(c: Ctx, route: ui.RoutablePage) ![]const u8 {
    return route.toUrl(c.arena);
}

// a route built by one of haxy's builders, which return null when it doesn't fit
pub fn routeUrl(c: Ctx, route: ?ui.RoutablePage) ![]const u8 {
    return url(c, route orelse return error.RouteTooLong);
}

// a url-encoded route value as text
pub fn decode(c: Ctx, encoded: []const u8) ![]const u8 {
    return std.Uri.percentDecodeInPlace(try c.arena.allocator().dupe(u8, encoded));
}

// a relative time with the exact utc time in its title
pub fn time(c: Ctx, seconds: i64) !void {
    const text = try ui.timestamp.format(c.arena.allocator(), seconds, c.session.now);
    if (text.exact.len == 0) return c.w.print("<span>{s}</span>", .{text.relative});
    try c.w.print("<time datetime=\"{s}\" title=\"{s}\">{s}</time>", .{ text.exact, text.exact, text.relative });
}

// the url of user `name`'s page
pub fn userUrl(c: Ctx, name: []const u8) ![]const u8 {
    const parsed = ui.RoutablePage.Array(haxy.event.User.name_max_len).from(name) orelse return error.RouteTooLong;
    return url(c, .{ .user_repos = .{ .name = parsed } });
}

pub fn formError(c: Ctx, message: []const u8) !void {
    try c.w.print("<p role=\"alert\" class=\"form-error\">{f}</p>", .{esc(message)});
}

pub const Field = struct {
    label: []const u8,
    name: []const u8,
    type: []const u8 = "text",
    value: []const u8 = "",
    invalid: bool = false,
    autocomplete: []const u8 = "off",
    placeholder: []const u8 = "",
    hint: []const u8 = "",
    mono: bool = false,
};

// a labelled input
pub fn field(c: Ctx, f: Field) !void {
    try c.w.print(
        "<div><label class=\"label\" for=\"f-{s}\">{f}</label><input class=\"input{s}\" id=\"f-{s}\" name=\"{s}\" type=\"{s}\" value=\"{f}\" autocomplete=\"{s}\"",
        .{ f.name, esc(f.label), if (f.mono) " mono" else "", f.name, f.name, f.type, esc(f.value), f.autocomplete },
    );
    if (f.placeholder.len != 0) try c.w.print(" placeholder=\"{f}\"", .{esc(f.placeholder)});
    if (f.invalid) try c.w.writeAll(" aria-invalid=\"true\"");
    if (!std.mem.eql(u8, f.type, "password") and !std.mem.eql(u8, f.type, "email")) try c.w.writeAll(" autocapitalize=\"none\" spellcheck=\"false\"");
    try c.w.writeAll(">");
    if (f.hint.len != 0) try c.w.print("<p class=\"hint\">{f}</p>", .{esc(f.hint)});
    try c.w.writeAll("</div>");
}

// a list search form, posting to the unsearched list url plus "/search"
pub fn searchForm(c: Ctx, id: []const u8, label: []const u8, placeholder: []const u8, list_url: []const u8, search: []const u8) !void {
    try c.w.print(
        \\<form role="search" class="search" method="post" action="{f}/search"><label class="sr-only" for="{s}">{f}</label><input class="input" id="{s}" type="search" name="search" value="{f}" placeholder="{f}" autocomplete="off"><button type="submit" class="btn btn-outline">{s}Search</button></form>
    , .{ esc(list_url), id, esc(label), id, esc(search), esc(placeholder), icons.search });
}

// previous and next links, either one absent
pub fn pager(c: Ctx, label: []const u8, previous_url: ?[]const u8, next_url: ?[]const u8) !void {
    if (previous_url == null and next_url == null) return;
    try c.w.print("<nav aria-label=\"{f}\" class=\"pager\">", .{esc(label)});
    if (previous_url) |href| try c.w.print("<a href=\"{f}\">Previous page</a>", .{esc(href)});
    if (next_url) |href| try c.w.print("<a href=\"{f}\">Next page</a>", .{esc(href)});
    try c.w.writeAll("</nav>");
}

// a legitimately empty list or page
pub fn empty(c: Ctx, title: []const u8, body: []const u8) !void {
    try c.w.print("<section class=\"empty\"><h2 class=\"empty-title\">{f}</h2>", .{esc(title)});
    if (body.len != 0) try c.w.print("<p class=\"empty-body\">{f}</p>", .{esc(body)});
    try c.w.writeAll("</section>");
}

// a server-only page in local mode
pub fn unavailable(c: Ctx, title: []const u8, message: []const u8) !void {
    try c.w.print("<section><h1 class=\"title\">{f}</h1><p role=\"status\" class=\"mt-3 medium muted\">{f}</p></section>", .{ esc(title), esc(message) });
}
