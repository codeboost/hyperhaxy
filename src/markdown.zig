const std = @import("std");
const haxy = @import("haxy");
const md = haxy.markdown;
const html = @import("html.zig");
const Ctx = html.Ctx;
const esc = html.esc;

// haxy's markdown as html. text is always escaped, so raw html shows as written.
pub fn render(c: Ctx, text: []const u8) !void {
    const doc = try md.parseText(c.arena.allocator(), text);
    try c.w.writeAll("<div class=\"prose\">");
    try blocks(c, doc.blocks);
    try c.w.writeAll("</div>");
}

fn blocks(c: Ctx, list: []const md.Block) std.Io.Writer.Error!void {
    try c.w.writeAll("<div class=\"prose-blocks\">");
    for (list) |block| try writeBlock(c, block);
    try c.w.writeAll("</div>");
}

fn writeBlock(c: Ctx, block: md.Block) !void {
    switch (block) {
        .heading => |h| {
            // the page owns the h1, so document headings start one level below
            const level = @min(@as(u8, @max(h.level, 1)) + 1, 6);
            try c.w.print("<h{d}{s}>", .{ level, if (h.center) " class=\"center\"" else "" });
            try inlines(c, h.inlines);
            try c.w.print("</h{d}>", .{level});
        },
        .paragraph => |p| {
            const class: []const u8 = if (p.center and p.pre) " class=\"center pre\"" else if (p.center) " class=\"center\"" else if (p.pre) " class=\"pre\"" else "";
            try c.w.print("<p{s}>", .{class});
            try inlines(c, p.inlines);
            try c.w.writeAll("</p>");
        },
        .code, .raw => |lines| {
            try c.w.writeAll("<pre>");
            for (lines, 0..) |line, i| {
                if (i != 0) try c.w.writeByte('\n');
                try c.w.print("{f}", .{esc(line)});
            }
            try c.w.writeAll("</pre>");
        },
        .quote => |quoted| {
            try c.w.writeAll("<blockquote>");
            try blocks(c, quoted);
            try c.w.writeAll("</blockquote>");
        },
        .list => |l| {
            if (l.ordered) try c.w.print("<ol start=\"{d}\">", .{l.start}) else try c.w.writeAll("<ul>");
            for (l.items) |item| {
                if (item.task) |done| {
                    try c.w.print(
                        "<li class=\"task-item\"><input class=\"task\" type=\"checkbox\" disabled aria-label=\"{s}\"{s}>",
                        .{ if (done) "Done" else "Not done", if (done) " checked" else "" },
                    );
                } else try c.w.writeAll("<li>");
                try blocks(c, item.blocks);
                try c.w.writeAll("</li>");
            }
            try c.w.writeAll(if (l.ordered) "</ol>" else "</ul>");
        },
        .rule => try c.w.writeAll("<hr>"),
    }
}

fn inlines(c: Ctx, runs: []const md.Inline) !void {
    for (runs) |run| {
        const href = if (run.link) |dest| safeLink(dest) else null;
        if (href) |dest| try c.w.print("<a href=\"{f}\" rel=\"noreferrer noopener\">", .{esc(dest)});
        if (run.style.strike) try c.w.writeAll("<s>");
        if (run.style.italic) try c.w.writeAll("<em>");
        if (run.style.bold) try c.w.writeAll("<strong>");
        if (run.style.code) try c.w.writeAll("<code>");
        // hard breaks arrive as newlines inside the text
        var parts = std.mem.splitScalar(u8, run.text, '\n');
        var first = true;
        while (parts.next()) |part| {
            if (!first) try c.w.writeAll("<br>");
            first = false;
            try c.w.print("{f}", .{esc(part)});
        }
        if (run.style.code) try c.w.writeAll("</code>");
        if (run.style.bold) try c.w.writeAll("</strong>");
        if (run.style.italic) try c.w.writeAll("</em>");
        if (run.style.strike) try c.w.writeAll("</s>");
        if (href != null) try c.w.writeAll("</a>");
    }
}

// only web, mail and same-site links become links
fn safeLink(dest: []const u8) ?[]const u8 {
    for ([_][]const u8{ "http:", "https:", "mailto:" }) |scheme| {
        if (std.ascii.startsWithIgnoreCase(dest, scheme)) return dest;
    }
    if (std.mem.startsWith(u8, dest, "/") and !std.mem.startsWith(u8, dest, "//")) return dest;
    return null;
}
