This is an experiment that replaces Haxy's web UI with a more typical, normie-friendly, GitHub-inspired UI.

This is meant to show self-hosters how to customize or replace Haxy's web UI without forking Haxy. Instead, you can bring Haxy in as a library and replace some or all of its frontend by re-exporting `pub const haxy_frontend: haxy.web.Frontend` in your main file.

You can try it like this:

```
zig build try
```

This will launch a server with fake data that it stores in the `temp-try` directory. You can view the web UI at http://localhost:8080.

![Screenshot of HyperHaxy](screenshot.avif)
