Static review only: I read the tracked diff and untracked files; no files changed or builds run.

1. **Blocker — MCP argument decoding admits schema-invalid values and a panic path.**  
   [src/mcp.zig:69](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/mcp.zig:69) uses `parseFromValueLeaky` as validation. Zig 0.17.1 accepts numeric enum tags, arrays for byte strings, and strings/floats for integer fields. Consequently, `kind:0,title:[116]` can create an issue despite the advertised string schema.

   More seriously, `get_issue` with `comments_from:18446744073709551616.0` reaches an out-of-range float-to-`usize` conversion on 64-bit targets. The standard library’s upper-bound comparison rounds `maxInt(usize)` to the same float before `@intFromFloat` ([static.zig:573](/opt/homebrew/opt/zig/lib/zig/std/json/static.zig:573)). This is a statically identified panic under the default ReleaseSafe build.

   **Fix:** validate JSON types, enum names and integer ranges before conversion. Return `-32602`; test these inputs through `Server.handle`, including that rejected writes change nothing.

2. **Should-fix — deviation A changes HTTP refusal behaviour. Pre-authorize before reading the body.**  
   Previously, `master:src/web.zig:1155` and `:1415` authorized before body reads. Now [src/web.zig:1215](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1215) and [src/web.zig:1517](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1517) read first. A denied request can therefore wait for a body or encounter `StreamTooLong`, reaching the best-effort 500 handler instead of the previous immediate 403/404. The 64 KiB limit bounds allocation; it does not preserve response precedence or prompt refusal.

   **Fix:** after constructing the context, call `ctx.authorize` and the existing refusal mapper before `readFormBody`. Keep authorization inside the operation too.

   Otherwise, the ordinary response paths remain preserved:

   | Handler | Before and after |
   |---|---|
   | `handleThreadNew`, non-patch | Success: 303 to `base/kind:id`. Invalid title: 303 to the new-thread form through `FormFeedback`; oversized labels: same redirect without feedback. Description CRLF normalization remains. [Evidence](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1221) |
   | `handleCommentNew` | Success: 303 to the new comment permalink. Invalid body: 303 to `base/new`, without flash. Missing object: 404 “comment parent not found”. Body CRLF normalization remains. [Evidence](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1519) |
   | `handleThreadStatus` | Success: 303 to `base`, retaining `keep_alive=false`. Authorization refusals and object-not-found responses retain their established mappings. [Evidence](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:2198) |

   **Deviation B is acceptable:** [repoTabFound](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:613) is a narrow adapter lookup preserving presentation-specific wording. Keep shared `NotFound`; splitting the domain error solely for these response texts is unnecessary.

3. **Should-fix — stale repository/tab access now exits the SSH TUI.**  
   Previously, `Session.authorize` converted `.repo_not_found` into a silent refusal ([src/ui.zig:2702](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui.zig:2702)). The new catches omit `.not_found` in status changes, comment creation and thread creation ([thread.zig:1743](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/widget/thread.zig:1743), [3056](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/widget/thread.zig:3056), [3133](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/widget/thread.zig:3133)). Disabling the tab or removing repository access after rendering now propagates through `ui.inputKey` and terminates the SSH TUI ([serve_ssh.zig:331](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/serve_ssh.zig:331)).

   **Fix:** treat repository/tab disappearance as recoverable and retain the form. To preserve existing object-not-found behaviour precisely, recheck authorization on `NotFound` and swallow `.repo_not_found`.

   Successful paths remain unchanged: new threads clear title/labels/description and navigate to their list/detail route; comments clear the body and navigate to their permalink; status changes navigate to the corresponding status list. Required-title feedback still copies values into the session arena ([thread.zig:3231](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/widget/thread.zig:3231)).

4. **Should-fix — malformed initialization and parameter envelopes receive success.**  
   [src/mcp.zig:151](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/mcp.zig:151) treats missing or wrongly typed `protocolVersion` like an unsupported version. Missing `capabilities`/`clientInfo` are also accepted. [jsonrpc.zig:68](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/mcp/jsonrpc.zig:68) permits scalar `params`, so even `ping` with `params:42` succeeds.

   **Fix:** validate the envelope and method parameters separately: malformed envelopes → `-32600`; invalid initialize fields → `-32602`. Reserve version fallback for a valid, unsupported version string. The required initialize fields are specified by the [MCP lifecycle](https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle).

   Supported/unsupported string negotiation, unanswered valid notifications, batch rejection, unknown-method `-32601`, unknown-tool `-32602`, and string/signed-64-bit ID echoing otherwise look correct.

5. **Should-fix — server setup failures are reported as tool execution failures.**  
   Failure opening the configured admin repository at [src/mcp.zig:99](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/mcp.zig:99) is caught by [src/mcp.zig:84](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/mcp.zig:84) and becomes `isError:true`; only OOM receives `-32603`. This happens before the operation runs.

   **Fix:** separate context/setup failures from operation failures and return `-32603` for internal server setup failures. Preserve `isError:true` for expected operation failures. MCP distinguishes server/protocol failures from tool execution failures in its [error handling rules](https://modelcontextprotocol.io/specification/2025-06-18/server/tools#error-handling). Successful `content` plus object-valued `structuredContent`, including `{}` for void results, are correctly shaped.

6. **Should-fix — `Failure.changed=false` is incorrect after a local Git commit succeeds.**  
   This is earlier code exposed by the new operations. [src/event.zig:722](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/event.zig:722) commits events before fallible local-database opening/consumption. If those subsequent steps fail, the write operations propagate the error, while [domain.classify](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain.zig:425) reports an internal failure with `changed=false`. A caller retrying creation can duplicate an already-committed write.

   **Fix:** distinguish failure after a successful nonempty event commit, classify it with `changed=true`, and communicate that the write committed but refresh failed. Add an operation-level fault-path test. The newly introduced `InvalidTitle`, `InvalidLabels` and `InvalidBody` classifications and their existing form-feedback projections otherwise look consistent.

7. **Should-fix — phase-2 completion is not adequately demonstrated by the tests.**  
   The tests use the right public seams and independent expectations: schemas and replies are handwritten ([test/mcp.zig:224](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/mcp.zig:224)); comparing text content with structured content is a useful consistency check, not a tautological expected-value generator.

   Missing coverage includes the changed web response paths, TUI submission/refusal behaviour, malformed initialization, numeric coercions, internal-server errors, and a complete local MCP list/create/comment interaction. CLI tests stop at dispatch ([test/mcp/cli.zig:9](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/mcp/cli.zig:9)). `RefreshLocal`’s local `NotFound` failure is untested, as are successful patch comment/status paths. Optional schema handling exists but no registered operation exercises it.

   Also, the purported “removed after startup” MCP test uses an account already removed during fixture construction ([fixture.zig:66](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/domain/fixture.zig:66)).

   **Fix:** add those seam tests, including removal between two calls, and record the required Inspector/Claude Code smoke demonstration. Static review cannot establish either that demonstration or test-first chronology.

8. **Should-fix — tool annotations understate actual effects.**  
   [src/mcp.zig:202](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/mcp.zig:202) marks reads read-only, but every local call first runs refresh, which can write patch revisions. `SetThreadStatus` inherits `destructiveHint:false` at [src/mcp.zig:206](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/mcp.zig:206), although it replaces existing status. MCP defines read-only as not modifying the environment, and false destructive hints as additive-only behaviour. [Annotation definitions](https://modelcontextprotocol.io/specification/2025-06-18/schema#toolannotations).

   **Fix:** annotate the complete tool execution, including preparation, conservatively; give status changes their own annotations.

9. **Nit — local refresh remains duplicated and explicitly calling it runs it twice.**  
   The page still performs consume/refresh directly ([ui/Repo.zig:313](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo.zig:313)); MCP automatically refreshes and then invokes the requested operation, including `RefreshLocal` itself ([src/mcp.zig:105](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/mcp.zig:105)).

   **Fix:** add `RefreshLocal.runOpen` for the page’s existing handle and skip automatic preparation when the requested operation is already `RefreshLocal`. The percent-escape/decode bridge preserves literal `%` and Unicode correctly; remove that round trip when decoding moves fully into adapters in phase 5.

Phase 3 can use this architecture, but I would fix the blocker and behaviour regressions before stacking more operations on it. The six operations are exported; status authorization precedes `canModify`; results and admin-repository lifetimes look sound. Operator host/user selection comes from startup configuration, fresh contexts reject removed/logged-out writers, and MCP does not construct `SessionStore`. Stdio framing is bounded, newline-delimited, flushed and EOF-safe; I found no allocation proportional to a client-supplied numeric size, although finding 1 exposes a numeric-conversion crash. The changed widget calls retain comptime wasm guards, MCP stays out of `ui.zig`/`web.zig`, and the test step depends on wasm compilation ([build.zig:90](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/build.zig:90)). One target-shape limitation remains: bridged reads leave `notify_action` null because enrichment still lives in `Repo.readNotify`; document that deferral explicitly. **A should be corrected; B can stay.**