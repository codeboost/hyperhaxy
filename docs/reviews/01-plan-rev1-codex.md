The direction is sound, but I would change the extraction strategy before implementing it. The largest gaps are query semantics, ownership, and preserving behavior currently supplied by `Session` and `Repo.init`.

Paths below refer to `haxy-hyperhaxy/` unless stated otherwise.

1. **The proposed query wrappers work as a bridge; they do not naturally become the components of `Repo.init`.**  
   `Issues.init` builds open, closed, and conflict windows, labels, selection state, and comment detail. It roots the window matching the selected issue’s *actual* status—not necessarily the requested status ([Issues.zig:284](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo/Issues.zig:284), [Issues.zig:340](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo/Issues.zig:340)). Every loaded entry also loads comments, attachments, and assignees ([thread.zig:418](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/widget/thread.zig:418)).

   Wrapping this and returning `.open` is feasible, but calling that wrapper again for `.closed` repeats the whole operation. Opening the repository once does not prevent that. **Recommendation:** initially let MCP wrappers reuse full tab loaders. Later extract shared window/detail loaders beneath both queries and page construction. `GetIssue` through a rooted window is a reasonable temporary implementation, with explicit not-found and comment-pagination behavior.

2. **The plan identifies the wrong source of query-time writes.**  
   Local page construction explicitly calls `evt.consume` and `pch.refreshBranches` before reading tabs ([Repo.zig:313](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo.zig:313)). A standalone `ListIssues` that merely invokes `Issues.init` can therefore read stale—or absent—local event data after a fetch or external git operation.

   Conversely, the mergeability concern at [plan:402](/Users/florinbraghis/code/haxy/hyperhaxy/docs/domain-layer-plan.md:402) is inaccurate: `Patches.init` reads cached mergeability, and `readMergeability` explicitly never refreshes it; stale results become `.unknown` ([Patches.zig:793](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo/Patches.zig:793), [patch.zig:453](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/patch.zig:453)). **Recommendation:** define local preparation/index refresh separately from reading. Preserve the existing merge-cache behavior.

3. **Notifications need an explicit extraction, including a richer query result.**  
   `notify_action` is populated outside the tab initializers. `Repo.readNotify` also marks a viewed notification read ([Repo.zig:452](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo.zig:452)). `UserNotifications.init` mutates the session’s unread count and loads SSH keys; its rows contain no notification ID ([UserNotifications.zig:17](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/UserNotifications.zig:17), [UserNotifications.zig:36](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/UserNotifications.zig:36)).

   **Recommendation:** extract notification enrichment and return notification IDs, unread count, and the observed `last_child_id`. Preserve the latter’s race protection in `MarkRead` ([notify.zig:147](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/notify.zig:147)). Let UI navigation explicitly mark read; an MCP inspection should not silently acknowledge notifications. `MarkRead` and `Dismiss` appear in the module inventory but lack implementation steps.

4. **Repository authorization alone is insufficient, and read authorization is underspecified.**  
   `authorizeUser` checks repository and tab write roles. Object edits additionally call `RepoSource.canModify`, which checks authorship ([ui.zig:2332](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui.zig:2332), [web.zig:1865](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1865)). Repository deletion requires the creator, not merely someone granted `.owner`; account/fork deletion also checks password and confirmation ([Delete.zig:46](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Delete.zig:46)).

   Queries must independently preserve private-repository hiding, disabled tabs, and write-only event-history access ([Repo.zig:259](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo.zig:259), [Repo.zig:287](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo.zig:287)). `resolveRepoPath` itself does not authorize ([serve_common.zig:15](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/serve_common.zig:15)). **Recommendation:** specify read resolution and per-operation checks explicitly; test commands directly without UI prechecks.

5. **“Results live in the call arena” is incomplete for the TUI.**  
   `Session` deliberately distinguishes session-lifetime allocations from page allocations. Navigation retains whole pages and their arenas in back history ([ui.zig:2399](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui.zig:2399), [ui.zig:3257](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui.zig:3257)). Resetting a query arena after `run` would invalidate retained page data.

   The admin moment also contains cursors into the open repository; the web renderer explicitly keeps that repository alive throughout page construction ([web.zig:2453](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:2453)). **Recommendation:** document ownership separately: input-buffer lifetime, scratch allocation, result allocation, and repository lifetime. Let TUI queries allocate into the page arena. Give owning contexts explicit cleanup and stable storage for the admin repository; never return a context pointing into an initializer’s local variable.

6. **Do not drop `Session.HostRequest`.**  
   It carries `show_copyable_text` as well as undo and sync. Sync queues work so the terminal can render “syncing…” before blocking ([ui.zig:2448](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui.zig:2448), [ui.zig:2893](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui.zig:2893), [Events.zig:802](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo/Events.zig:802)).

   **Recommendation:** have the host loop invoke extracted commands while retaining scheduling, navigation, refresh, and failure display in the UI adapter. Also specify the actual mode matrix: sync is local-only; current undo is server/xit-only, including an explicit test that local xit has no undo ([undo.zig:140](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/undo.zig:140)). “Unavailable” should be a capability result, not an authorization failure.

7. **Fork-backed patches require more than replacing two `Patches.init` arguments.**  
   Draft loading uses local/server mode, user ID, **user name**, users directory, repository ID, admin moment, and an open target repository ([Patches.zig:553](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo/Patches.zig:553), [Patches.zig:804](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo/Patches.zig:804)). The user name can be resolved from the ID, but that work must move somewhere.

   Draft creation records state across the user repository and copied fork; editing/removing drafts follows different paths from published patches. Fork browsing also handles renamed/deleted targets ([fork.zig:85](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/fork.zig:85), [Fork.zig:45](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Fork.zig:45)). **Recommendation:** include fork identity in file/commit/diff query addressing, add the missing `DeleteFork` operation, and distinguish draft/conflict views from patch statuses. A status-only `ListPatches` cannot represent every existing window.

8. **The comptime helper is feasible, but it cannot erase generic implementation requirements.**  
   Both backend kind and repository options determine concrete types. Sync additionally opens `AnyRepo` with `.ProgressCtx = Header.Progress`, unlike ordinary handlers ([Events.zig:897](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo/Events.zig:897)). Tests also instantiate git/xit × SHA-1/SHA-256 with `.is_test = true` ([test/event/patch.zig:19](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/event/patch.zig:19)).

   **Recommendation:** keep public `run` non-generic, with generic internal callbacks/`runOpen` functions carrying the exact options. Allow specialized openings for sync, forks, and tests. Centralizing ordinary dispatch is useful; making `withRepo` the sole repository-opening abstraction is unnecessary.

9. **The wasm direction is correct, but enforce it from the first extraction.**  
   `main_wasm.zig` imports both UI and web code, reconstructs snapshots, and calls `web.generateHtml` ([main_wasm.zig:1](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/main_wasm.zig:1), [main_wasm.zig:96](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/main_wasm.zig:96)). Existing submit functions guard before filesystem work ([thread.zig:3078](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/widget/thread.zig:3078)).

   Zig’s lazy analysis makes importing native functionality workable; merely sharing an import is not the problem. **Recommendation:** retain guards before context construction and command calls, keep MCP registration out of the UI dependency path, and run wasm checks immediately. Native `zig build test` is a separate build step ([build.zig:71](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/build.zig:71)).

10. **The existing feedback enums are not a complete domain error vocabulary.**  
    `PatchFailure` covers title and branch validation, but not merge conflicts, stale revisions, unavailable checks, or missing patch data ([ui.zig:2457](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui.zig:2457), [web.zig:1377](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1377)). Issue validation also rejects oversized labels without a corresponding `ThreadFailure` ([Issue.zig:60](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/event/Issue.zig:60)).

    **Recommendation:** inventory expected failures per operation before extracting. `!Outcome` is defensible when failures carry useful payloads, but mandatory per-command unions mostly duplicate Zig errors here. Use `!T` plus an explicit shared error classifier where failures are payload-free; use unions selectively. Queries need the same classification discipline. Also fix the convention mismatch: the sample succeeds with `.created`, whereas MCP supposedly treats every non-`.ok` outcome as failure ([plan:133](/Users/florinbraghis/code/haxy/hyperhaxy/docs/domain-layer-plan.md:133), [plan:199](/Users/florinbraghis/code/haxy/hyperhaxy/docs/domain-layer-plan.md:199)).

11. **Form feedback remains substantial adapter work.**  
    TUI feedback copies submitted values into the session arena, including patch source selection ([thread.zig:3236](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/widget/thread.zig:3236)). Server web feedback serializes fields into flash storage; local web feedback has a narrower cookie-based implementation ([web.zig:472](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:472)). Passwords are deliberately excluded ([ui.zig:2559](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui.zig:2559)).

    **Recommendation:** retain explicit adapter tests for preserving values, selecting the correct form, and avoiding dangling strings or retained passwords. Drop the “every handler under 30 lines” acceptance criterion. Correct ownership and behavior matter more than handler length.

12. **The module split is more elaborate than needed initially, and “writes have no layer” overstates the situation.**  
    There are already substantial domain operations: `evt.createRepo`, user updates, comment updates, attachment creation, patch publishing/merging, and fork creation ([event.zig:2284](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/event.zig:2284), [web.zig:1834](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1834)). Much of the missing layer is authorization and orchestration.

    **Recommendation:** begin with a small context/auth seam and a few cohesive operation modules. Defer the full commands/queries directory taxonomy and generic outcome helpers. Returning `ui.*` types is acceptable transitional coupling, but it does not establish a UI-independent domain layer. Keep feedback wording in presentation code unless sharing it produces an actual benefit.

13. **The command/schema example has concrete defects, and reflection needs explicit metadata.**  
    `CreateThread` declares both `pub const description` and a `description` field ([plan:123](/Users/florinbraghis/code/haxy/hyperhaxy/docs/domain-layer-plan.md:123)). Zig 0.17.1’s `ast-check` rejects this as a duplicate member. Its `evt.EventKind` also exposes user, repo, attachment, and other illegal thread kinds ([event.zig:362](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/event.zig:362)).

    **Recommendation:** use distinct metadata names, a narrow `ThreadKind`, and explicit stable tool names. Snake_case is fine; deriving the public name from a Zig type makes ordinary refactors API changes. Reflection can generate structural schemas, but cannot infer ID formats, branch constraints, field descriptions, or patch-only combinations. Distinguish nullable fields from omittable fields and make unknown-field behavior match the schema.

14. **Existing query inputs contain URL encoding conventions that must not leak into MCP.**  
    `Issues.emptyResult` percent-decodes `search`; `User.init` does the same, and file/ref handling also processes URL-encoded values ([Issues.zig:173](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo/Issues.zig:173), [User.zig:72](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/User.zig:72), [Files.zig:164](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo/Files.zig:164)).

    A raw MCP search containing literal `%20` would silently change meaning if passed straight through. **Recommendation:** define domain inputs as decoded strings and move decoding to route adapters. Until then, bridge the old contract deliberately and test literal percent signs, Unicode, and slash-containing refs.

15. **Attachments break the “every command is directly JSON-parseable” simplification.**  
    Web uploads currently stream from the socket into the object store, with a 10 MiB limit ([web.zig:1642](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1642), [Attachment.zig:32](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/event/Attachment.zig:32)). Requiring a command-owned byte slice introduces full buffering. `contentEncoding: base64` does not cause `std.json.parseFromSlice` to decode anything.

    **Recommendation:** keep a streaming attachment operation and an MCP adapter that explicitly validates/decodes base64. Bound encoded and decoded sizes separately. There is no single existing body limit to reuse: forms use 64 KiB, uploads use their own limit ([web.zig:3188](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:3188)). Specify MCP request, response, and concurrency limits explicitly.

16. **Stdio framing is correct; lifecycle and error handling need more detail.**  
    Newline-delimited UTF-8 JSON and stderr diagnostics match the [transport specification](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports). Add bounded line reads, flushing, EOF handling, and tests for multiple messages per read and partial messages. Notifications must receive no JSON-RPC response ([base protocol](https://modelcontextprotocol.io/specification/2025-06-18/basic)).

    “Negotiate down” is misleading: return the requested version only if implemented; otherwise return a supported version ([lifecycle](https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle)). Batch support was **removed** in 2025-06-18, so older-version support cannot be promised casually ([changelog](https://modelcontextprotocol.io/specification/2025-06-18/changelog)).

    **Recommendation:** start with an explicit supported-version set. Map malformed protocol/arguments separately from execution failures; a Zig error such as a failed remote sync can still be a tool execution error. Return proper `content` blocks, preferably structured results plus JSON text, rather than bare outcome JSON ([tools specification](https://modelcontextprotocol.io/specification/2025-06-18/server/tools)).

17. **`--data-dir --user` is a reasonable operator mode, but its authority must stay outside tool inputs.**  
    The existing administrative deletion command indeed bypasses passwords ([serve.zig:31](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/serve.zig:31)). That differs from interactive deletion’s reauthentication. Local startup also probes both git and xit, selects the nearest repository, and preserves global config ([main.zig:98](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/main.zig:98)).

    **Recommendation:** require the server-mode options together, resolve the named account to a stable ID, and recheck activity per call. Never let HTTP tool arguments select another acting user or an administrative bypass. Reuse local discovery without starting the TUI/web listener. Do not initialize `SessionStore` merely to access data: its initialization clears flash storage ([web.zig:3228](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:3228)).

18. **The HTTP origin statement is wrong; bearer tokens alone are not the full interoperability design.**  
    [Plan:367](/Users/florinbraghis/code/haxy/hyperhaxy/docs/domain-layer-plan.md:367) explicitly removes same-origin checking. Streamable HTTP requires `Origin` validation. GET returning 405 is valid; accepted notifications need HTTP 202 with no body, and subsequent requests need protocol-version handling ([transport specification](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)).

    **Recommendation:** retain an explicit allowed-origin policy and choose stateless HTTP initially unless sessions are needed. Personal bearer tokens are a valid manually configured integration, but do not provide standard MCP authorization discovery. General client interoperability needs a separate OAuth/resource-metadata decision ([authorization specification](https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization)). Specify token creation authorization, expiry/revocation, secure storage, and account-deletion behavior.

    Also correct the scope claim: adding a token view explicitly changes hyperhaxy, contradicting “only one dependency line changes” ([plan:20](/Users/florinbraghis/code/haxy/hyperhaxy/docs/domain-layer-plan.md:20), [plan:360](/Users/florinbraghis/code/haxy/hyperhaxy/docs/domain-layer-plan.md:360)).

19. **Command failures do not necessarily mean nothing changed.**  
    `mergeAndRemoveFork` commits the merge before attempting fork removal; cleanup can subsequently fail ([patch.zig:1244](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/patch.zig:1244)). Event consumption also performs participant subscriptions, notification delivery, and activity updates after the repository transaction ([event.zig:782](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/event.zig:782)).

    **Recommendation:** preserve existing transaction boundaries and distinguish committed mutations with cleanup failures where necessary. Do not add automatic retries for creates, merges, or sync. Document retry semantics and set MCP behavior annotations accurately. Centralizing the command call must not accidentally duplicate notification delivery or imply cross-repository atomicity.

20. **The phase order delays validation, and the full estimates are optimistic.**  
    Move a small slice of queries and stdio ahead of the remaining command families: prove list/create/read-back through MCP, web, and TUI before extracting everything. `Repo.init` recomposition is not a prerequisite for useful MCP. The later JSON router is small only once wire formats, pagination, failure semantics, and authentication are settled.

    Reuse the substantial existing event/patch/notification tests; the absence of HTTP POST tests is real, so add representative transport tests rather than relying only on domain tests ([test.zig:1](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test.zig:1)). Include backend/hash combinations, fresh authorization, fork lifecycle, feedback retention, and local refresh.

    **My estimate for one developer familiar with this code:** three weeks is plausible for a deliberately narrow local issue/comment MCP. Full extraction with UI parity and stdio is more credibly **5–8 weeks**, followed by **1–3 weeks** for HTTP, personal tokens, and their UI. Standard OAuth interoperability needs separate estimation. The proposed 3–4 days for query extraction is particularly tight.

No files were modified. This was a source review plus a stdin-only Zig syntax check; I did not run builds or tests.