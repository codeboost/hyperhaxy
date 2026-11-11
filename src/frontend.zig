const haxy = @import("haxy");
const render = @import("render.zig");

pub const frontend: haxy.web.Frontend = .{
    .files = &.{
        .{ .path = "index.html", .content_type = "text/html; charset=utf-8", .body = @embedFile("embed/index.html") },
        .{ .path = "style.css", .content_type = "text/css; charset=utf-8", .body = @embedFile("embed/style.css") },
        .{ .path = "app.js", .content_type = "text/javascript; charset=utf-8", .body = @embedFile("embed/app.js") },
    },
    .renderHtml = render.page,
    .site_name = "Hyper",
};
