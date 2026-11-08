const html = @import("../html.zig");
const Ctx = html.Ctx;

pub fn page(c: Ctx) !void {
    try c.w.writeAll(
        \\<section><h1 class="title">Page not found</h1><p class="mt-3 muted">There is no page at this address, or you can't see it.</p><a href="/" class="link inline-block mt-6 text-sm">Go to the home page</a></section>
    );
}
