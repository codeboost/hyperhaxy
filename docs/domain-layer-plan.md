# Domain layer, MCP server and JSON API for haxy

Status: revision 2, 2026-11-09, after a Codex review of revision 1 (see §9).
"The fork" is `../haxy-hyperhaxy` (github.com/codeboost/haxy), currently at the
same commit upstream haxy is pinned to in hyperhaxy's `build.zig.zon` (66c1ab6).
Paths below are in the fork unless prefixed `hyperhaxy/`.

## 1. Goal

Give haxy one transport-neutral layer of **operations** (writes and reads) that
the TUI, the web UI (haxy's own and hyperhaxy's), an MCP server and a later JSON
API all call. Each transport becomes an adapter: parse its input shape, build a
context, call the operation, render the result its way.

Non-goals: changing the event model or storage; upstreaming (the work happens
in the fork; upstreaming is a separate decision once it exists); OAuth-based MCP
authorization (see §6.4).

## 2. Where things stand

- **hyperhaxy** is a pure renderer. haxy's `web.Frontend.render_html` hook hands
  it a built `ui.Page` plus `ui.Session.Data`; it writes HTML and posts forms
  back to haxy's own URLs. It holds no domain logic. This plan touches it in two
  places only: the dependency line in `build.zig.zon` (phase 0) and, in phase 6,
  a page for access tokens.
- **Reads** already have a data layer. `ui.Page` and the per-tab structs in
  `src/ui/Repo/*.zig` are plain data, JSON-serializable (`ui.Snapshot`), and
  already served to `Accept: application/json` requests. Each tab has an `init`
  that is nearly a query, but with positional, URL-encoded arguments and, for
  `Patches`, a `*ui.Session` dependency. `Repo.init` builds every tab on every
  request (`src/ui/Repo.zig:366-393`), and in local mode first consumes the
  events branch and refreshes patch branches (`src/ui/Repo.zig:313-316`), so
  reads currently depend on a write-ish preparation step.
- **Writes** are partly layered. The event modules already hold real
  operations: `evt.createRepo`, `evt.updateUser`, `Comment.create`,
  `Comment.update`, `Attachment` creation, `pch.publish`, `pch.merge`,
  `pch.mergeAndRemoveFork`, `fork.create`. What is missing is the layer between
  "intent" and those calls: authorization, input validation, repo resolution,
  the fork-vs-branch switch, and outcome classification. Today that lives in
  thirty POST handlers in `src/web.zig` (about 1,900 lines) and again in the
  TUI widgets (`src/ui/widget/thread.zig` `submit*`, and the `Members`,
  `Branches`, `Settings`, `UserKeys`, `UserSettings`, `NewRepo`, `NewUser`,
  `Delete`, `Undo`, `Events` widgets).
- **Tests** do not cover the write handlers. `src/test/net.zig` covers git
  fetch/push/clone over the wire; `src/test/ui.zig` covers widget behaviour;
  `src/test/event/*` and `src/test/undo.zig` drive temp repos directly and are
  the model for operation tests. Nothing POSTs to a web route.
- **Authorization** has two levels today. Repo and tab role checks are
  transport-neutral in `ui.zig` (`Actor`, `Authorization`, `authorizeUser`,
  `activeUser`, `localAuthor`). Object-level checks are scattered:
  `RepoSource.canModify` checks authorship for edits (`src/ui.zig:2257`), repo
  deletion requires the creator rather than any granted owner
  (`src/ui/Repo.zig:322`), account and fork deletion re-check the password and a
  typed confirmation (`src/ui/Delete.zig:46`). Read resolution hides private
  repos, disabled tabs and the event history from non-writers
  (`src/ui/Repo.zig:259-287`); `serve_common.resolveRepoPath` itself does not
  authorize.
- **Side effects after the transaction.** `evt.consume` subscribes
  participants, delivers notifications and bumps repo activity after the repo
  transaction commits (`src/event.zig:782-786`). `pch.mergeAndRemoveFork`
  commits the merge before removing the fork (`src/patch.zig:1244`). Viewing a
  thread marks its notification read during page build
  (`src/ui/Repo.zig:452` and following).
- **wasm constraint**: `src/main_wasm.zig` imports `ui.zig` and `web.zig` for
  `wasm32-freestanding`. Lazy analysis means importing native code is fine;
  calling it is not. Widgets already guard with `if (comptime wasm) return;`
  before filesystem work (`src/ui/widget/thread.zig:3078`).

## 3. Target shape

New code lives in the fork, exported from `src/lib.zig` as `haxy.domain` and
`haxy.mcp`. Start with a small seam and few files; split further only when a
file gets unwieldy.

```
src/domain.zig              Ctx, Host, auth, repo opening helpers, failure classification
src/domain/threads.zig      thread, comment, attachment, assignment operations (issue/patch/discuss)
src/domain/patches.zig      publish, merge, draft (fork) operations
src/domain/repos.zig        repo create/settings/delete, members, branches, undo, sync, local refresh
src/domain/users.zig        register, settings, keys, delete, tokens (phase 6)
src/domain/notifications.zig list, mark read, dismiss, subscribe, mute
src/domain/reads.zig        query structs wrapping the per-tab loaders
src/mcp.zig                 tool registry, initialize / tools/list / tools/call
src/mcp/jsonrpc.zig         JSON-RPC 2.0 envelope types and parsing
src/mcp/stdio.zig           newline-delimited stdio transport
src/mcp/http.zig            (phase 6) Streamable HTTP endpoint
src/api.zig                 (phase 7) /api/v1 JSON router
```

### 3.1 Context and ownership

```zig
pub const Ctx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,                 // scratch; operations free what they take
    arena: *std.heap.ArenaAllocator,        // results; owned by the caller, never reset by an operation
    host: Host,                             // .local = ui.RepoSource | .server = { admin_repo_path, users_dir }
    admin: ?*rp.Repo(.xit, evt.admin_repo_opts), // stable storage owned by the caller for the Ctx's lifetime
    moment: ?evt.AdminDB.HashMap(.read_only),    // cursors into `admin`; null in local mode
    user_id: ?[evt.event_id_size]u8,        // the acting account, already checked active; null = logged out
    now: i64,
};
```

Ownership rules, which revision 1 left implicit:

- **Input buffers** belong to the transport and must outlive the call only.
  Operations copy anything they return into `ctx.arena`.
- **Results** are allocated in `ctx.arena`. The caller decides its lifetime:
  the web request arena for one page, the TUI's page arena (which navigation
  history retains, `src/ui.zig:3257`), or a per-call arena in MCP.
- **The admin repo** must outlive the moment's cursors, as `web.renderPage`
  already does (`src/web.zig:2453`). A `Ctx` never points at a local variable
  of its own initializer; the owner (request handler, TUI session, MCP server)
  holds the repo and passes a pointer.
- **Repo handles** for the target repo are opened per operation unless the
  caller passes an already open one through the `runOpen` variant (§3.3), which
  page composition uses to open once per page.

`Ctx.initServer(...)` opens nothing itself; it takes the admin repo pointer,
reads the moment and drops a `user_id` whose account is removed.
`Ctx.initLocal(...)` wraps a `RepoSource`. Resolving a cookie or bearer token to
a user id is transport work; the context only receives the id.

### 3.2 Authorization, in three levels

1. **Read resolution**: `domain.resolveRepo(ctx, identity)` returns the repo
   record, the viewer's role and the on-disk path, or `not_found`. It hides
   private repos the viewer cannot read and reports disabled tabs and the
   event history as unavailable to non-writers, as `Repo.init` does today.
   Every read and write starts here.
2. **Role check**: `ctx.authorize(identity, min_role, thread_kind)` is
   `ui.authorizeUser` moved to `domain.zig` (`ui.zig` keeps aliases). Returns
   `Authorization = actor | login_required | repo_not_found | forbidden`.
3. **Object check**: edits and removals call `canModify(actor, kind, id)`
   (authorship or a role that overrides it); repo deletion requires the
   creator; account and fork deletion take `password` and `confirm` inputs and
   re-verify them inside the operation, not in the UI.

Local mode yields an owner actor from the repo's git config (`localAuthor`).
Server-only operations (fork drafts, members, tokens, undo) and local-only
operations (sync) return a **capability** result, `unavailable_here`, which is
distinct from denial so a tool list stays the same across modes and the
message is accurate. Mode matrix to encode in tests: sync is local-only; undo
is server and xit-only (local xit has no undo, `src/test/undo.zig:140`).

### 3.3 Operations

An operation is a struct whose fields are its decoded input and which has
`run(self, ctx: *Ctx) !Result`. Example, corrected from revision 1 (a field
and a declaration may not share a name, and `evt.EventKind` includes
non-thread kinds):

```zig
pub const ThreadKind = enum { issue, patch, discuss };

pub const CreateThread = struct {
    pub const tool_name = "create_thread";
    pub const tool_description = "Open a new issue, patch or discussion in a repository.";
    repo: []const u8,                       // "owner:name"; "" in local mode
    kind: ThreadKind,
    title: []const u8,
    labels: []const u8 = "",
    body: []const u8 = "",
    target_branch: []const u8 = "",         // patches only
    source_branch: ?[]const u8 = null,      // patches: null starts a fork-backed draft (server only)

    pub const Result = struct { id: [evt.event_id_size * 2]u8 };

    pub fn run(self: CreateThread, ctx: *Ctx) Error!Result { ... }
    pub const Error = domain.Error;          // the shared, classified error set
};
```

Conventions:

- **Errors, not outcome unions, by default.** Operations return an inferred
  error set (`!Result`). `domain.Error` is the explicit set of *expected*
  failures (`InvalidTitle`, `LabelsTooLong`, `InvalidTargetBranch`,
  `SameBranch`, `UnrelatedBranches`, `NameTaken`, `NotFound`, `LoginRequired`,
  `Forbidden`, `UnavailableHere`, `MergeConflict`, `StaleRevision`, ...) that
  `domain.classify(err) Failure` recognises; anything outside it classifies
  as `internal`. (Revision 2 had operations return `Error!Result`; the
  phase 1 review showed that enumerating Zig's infrastructure errors in one
  explicit set is impractical, so the inferred set carries them and
  `classify` is the single place that sorts them.) `Failure` is a small
  struct (kind, whether retryable, whether the repo changed) that every
  adapter uses; nothing is marked retryable today.
  A result union is used only where the failure carries a payload the caller
  needs, such as conflict resolution reporting which fields still conflict.
  The existing `ui.Session.FormFeedback.*Failure` enums become projections of
  `domain.Error` via `fromError`, so form feedback keeps working.
- **Inventory first.** Before extracting an operation, list its expected
  failures from the handler, the widget and the event module. Revision 1
  assumed the feedback enums were complete; they are not (`PatchFailure` lacks
  merge conflicts, stale revisions and unavailable checks, `src/web.zig:1377`;
  `Issue.fieldsValid` rejects oversized labels with no matching enum arm,
  `src/event/Issue.zig:60`).
- **Decoded inputs.** Operation inputs are plain decoded strings. The
  per-tab loaders currently percent-decode internally (`Issues.emptyResult`,
  `User.init`, `Files.init` at `src/ui/Repo/Files.zig:164`); that decoding
  moves to the route adapters, and tests cover literal `%`, Unicode and refs
  containing `/`. CRLF normalization and form-field lookup are the web
  adapter's job.
- **No UI concerns.** Operations do not redirect, flash, navigate, build
  widgets or touch `Session`.
- **Generic inside, concrete outside.** `run` is not generic. Inside it, a
  `withRepo(ctx, resolved, args, comptime body)` helper does the usual
  `AnyRepo` open plus `inline else` dispatch and calls `body` with the concrete
  `repo_kind`/`repo_opts`. It is the default, not the only way to open a repo:
  sync opens with a progress context (`src/ui/Repo/Events.zig:897`), fork
  operations open two repos, and tests open with `.is_test = true` across
  git/xit × SHA-1/SHA-256 (`src/test/event/patch.zig:19`). Operations that
  need it expose `runOpen(self, ctx, comptime repo_kind, comptime repo_opts, repo)`
  for callers that already hold the repo.
- **Transaction boundaries stay where they are.** An operation wraps the
  existing event-module call; it does not add retries or claim atomicity
  across repos. `classify` reports `changed: true` for failures after a
  commit (fork cleanup after a merge). Notification delivery and participant
  subscription keep happening inside `evt.consume`, exactly once.

### 3.4 Reads

Reads are operations too, returning the data types that already exist, so the
page structs, hyperhaxy's renderer and the wasm client are unchanged:

```zig
pub const ListIssues = struct {
    pub const tool_name = "list_issues";
    pub const tool_description = "List a repository's issues by status, newest first.";
    repo: []const u8,
    status: evt.Issue.Status = .open,
    search: []const u8 = "",                // decoded; the UI search syntax (words, label:x, assignee:y)
    from: []const u8 = "",                  // id of the window's first item; "" for the first window
    pub fn run(self: ListIssues, ctx: *Ctx) Error!ui.Repo.Issues.Window { ... }
};
```

Realities the Codex review surfaced about the loaders, and how the plan
handles them:

- `Issues.init` builds open, closed and conflict windows, labels, selection
  and comment detail in one pass, and roots the window at the selected
  issue's actual status (`src/ui/Repo/Issues.zig:284,340`); each entry loads
  comments, attachments and assignees (`src/ui/widget/thread.zig:418`).
  **Bridge first:** `ListIssues` calls the full loader and returns one window.
  That is correct and cheap enough for an MCP tool. **Extract later:** split
  the loader into a window loader and a detail loader that both `Repo.init`
  and the reads call. `Repo.init` recomposition is therefore phase 5, not a
  prerequisite for MCP.
- `GetIssue`/`GetPatch`/`GetDiscussion` are implemented as "the window rooted
  at this id with the thread selected", with explicit `NotFound` and a
  `comments_from` paging input.
- **Local preparation is its own operation.** `Repo.init` consumes the events
  branch and refreshes patch branches before reading in local mode
  (`src/ui/Repo.zig:313`). A read that skips this sees stale data after a
  fetch. `domain.repos.RefreshLocal` does that step; the page adapter and the
  MCP server call it before reads in local mode (MCP: once per `tools/call`,
  cheap when nothing changed). Reads themselves stay read-only.
- **Mergeability is already read-only.** `Patches.init` reads the cached
  mergeability and `readMergeability` never refreshes; stale becomes
  `.unknown` (`src/ui/Repo/Patches.zig:793`, `src/patch.zig:453`). Keep that;
  revision 1's worry was wrong.
- **Fork identity is an address.** Files, commits and diffs can belong to a
  fork-backed draft, and fork browsing handles renamed or deleted targets
  (`src/ui/Fork.zig:45`). Read inputs take `repo` plus an optional
  `fork_id`/`patchrev` instead of assuming the main repo. `ListPatches` takes
  a `view` (open, closed, merged, drafts, conflicts), not only a status.
- `Patches.init` needs the user name, repo id, admin moment and an open
  target repo for drafts (`src/ui/Repo/Patches.zig:553,804`). The read
  resolves the user name from `ctx.user_id` and passes the rest explicitly;
  the `*ui.Session` parameter goes away.
- **Notifications** are extracted explicitly: `ListNotifications` returns
  rows with notification ids, the unread count and the observed
  `last_child_id`; `MarkRead` takes that id to keep the race protection in
  `notify.markRead` (`src/notify.zig:147`). Viewing a thread via MCP does
  **not** mark anything read; the UI adapter calls `MarkRead` on navigation
  as it effectively does today. `notify_action` enrichment moves out of
  `Repo.readNotify` into a helper the reads can call.
- Viewer-dependent fields (`can_modify`, `notify_action`) stay in results,
  computed from `ctx.user_id`. Phase 2 status: `can_modify` is filled by the
  bridged reads; `notify_action` is still `null` from them because the
  enrichment lives in `Repo.readNotify`, which only the page build calls.
  Moving it into the helper described above is phase 4 work.

### 3.5 MCP server

- **Protocol**: JSON-RPC 2.0. Supported protocol versions are an explicit set,
  initially `{"2025-06-18"}`. `initialize` returns the client's requested
  version if it is in the set, otherwise the newest supported one. No batch
  support (removed in 2025-06-18; older versions are not promised). Methods:
  `initialize`, `notifications/initialized`, `ping`, `tools/list`,
  `tools/call`. Notifications get no response. Unknown methods return
  `-32601`.
- **Stdio transport**: one UTF-8 JSON object per line on stdin/stdout,
  diagnostics on stderr. Bounded line length, explicit flush after each
  response, clean exit on EOF. Tests feed several messages in one read and a
  message split across reads.
- **Registry**: a comptime tuple of operation types. `tools/list` derives each
  `inputSchema` from `@typeInfo` (fields → properties, fields with defaults →
  omittable, `?T` → nullable, enums → `enum`) and adds what reflection cannot
  know from a per-operation `pub const tool_schema_notes` (field descriptions,
  id formats, patch-only combinations). Omittable and nullable are kept
  distinct; unknown fields are rejected to match the schema. Tool names are
  the explicit `tool_name` constants, never derived from the Zig type name.
- **Results**: `tools/call` returns MCP `content` blocks: a JSON text block plus
  `structuredContent` with the result. Failures classified by
  `domain.classify` return `isError: true` with the human text; protocol and
  argument errors return JSON-RPC errors. Tool annotations (`readOnlyHint`,
  `destructiveHint`, `idempotentHint`) are set from the operation.
- **Limits**: request line length, decoded attachment size
  (`evt.Attachment.max_size`, 10 MiB) and base64 length are bounded
  separately; one call at a time per stdio session.
- **Attachments**: `Attach` stays a streaming operation taking a reader, as
  the upload handler does today (`src/web.zig:1642`). The MCP adapter decodes
  base64 into a bounded buffer and hands over a fixed reader.
- **Entry points**:
  - `haxy mcp` inside a repo: local mode. Reuses the bare command's repo
    discovery (nearest git or xit repo, global config author,
    `src/main.zig:98`) without starting the TUI or web listener.
  - `haxy mcp --data-dir DIR --user NAME`: operator mode over stdio against
    server data, acting as the named account. Both flags are required
    together; the name is resolved to an id at startup and re-checked active
    per call. Same trust model as `haxy delete-user`. It does not construct a
    `SessionStore` (its init clears flash storage, `src/web.zig:3228`). The
    acting user is never selectable from tool arguments.
  - Phase 6 adds Streamable HTTP on the web listener.
- **Destructive tools** (`remove_*`, `delete_repo`, `delete_fork`, user
  deletion) are registered only with `--allow-destructive`.

## 4. Phases

Each phase ends with `zig build test` and `zig build wasm` green in the fork
and `zig build try` working in hyperhaxy. The order is changed from revision 1
to validate the whole path early: a vertical slice reaches MCP before the
remaining operation families are extracted.

### Phase 0: wiring (hours)

1. hyperhaxy `build.zig.zon`: replace the haxy `.url`/`.hash` with
   `.path = "../haxy-hyperhaxy"`; confirm `zig build try` serves hyperhaxy.
2. Fork: `src/domain.zig` (empty namespace) exported from `src/lib.zig`;
   `src/test/domain.zig` added to `src/test.zig`; `zig build wasm` added to
   whatever CI or pre-commit check exists.
3. Fixture `src/test/domain/fixture.zig`: temp data dir, admin repo via
   `evt.initAdminRepo`, two users via `evt.createUser`, a public and a
   private repo via `evt.createRepo`, a `Ctx` for a chosen user; plus a
   local-mode variant around a temp git and a temp xit repo, like
   `src/test/undo.zig`. Parametrized over backend × hash like
   `src/test/event/patch.zig`.

### Phase 1: context, resolution and authorization (2 days)

1. `Ctx`, `Host`, `resolveRepo`, `authorize`, `canModify` in `domain.zig`;
   `Actor`, `Authorization`, `activeUser`, `authorizeUser`, `localAuthor`
   moved from `ui.zig` with aliases left behind.
2. `domain.Error` and `classify`; the `FormFeedback.*Failure.fromError`
   helpers re-pointed at it.
3. `withRepo` and the `runOpen` convention.
4. `web.authorizeWrite` becomes `ctx.authorize` plus a response mapper.

Tests: resolution and authorization for owner, member, stranger, removed
user and logged-out viewer on public and private repos; disabled tab;
authorship `canModify`; local owner actor.

### Phase 2: vertical slice to MCP (1.5 weeks)

Operations: `RefreshLocal`, `ListIssues`, `GetIssue`, `CreateThread`
(issues and discussions; patches in phase 3), `CreateComment`,
`SetThreadStatus`. Adapters: web handlers `handleThreadNew` (non-patch
path), `handleCommentNew`, `handleThreadStatus` cut to parse → run → respond
with feedback via `fromError`; TUI `submitNewThread`, `submitComment` and the
status buttons call the same operations behind the wasm guard. MCP:
`mcp/jsonrpc.zig`, `mcp/stdio.zig`, `mcp.zig` with the registry, and the
`haxy mcp` subcommand in local mode.

Done when: Claude Code or the MCP inspector can list issues, create one and
comment on it against `haxy mcp` in a demo repo, the web form path and the
TUI path still work, and operation tests cover happy path, every classified
failure, denial and `unavailable_here` for each slice operation.

### Phase 3: remaining thread, patch and comment operations (1.5 weeks)

| Operation | Replaces in web.zig | Replaces in TUI |
|---|---|---|
| CreateThread (patch: branch and fork-draft paths) | rest of handleThreadNew | Patches.create |
| EditThread | handleThreadEdit | submitEditedThread |
| ResolveConflict (union result: remaining conflicts) | handleThreadResolve | submitResolution |
| EditComment | handleCommentEdit | comment edit path |
| RemoveThread / RemoveComment / RemoveAttachment | handleRemove | submitRemove |
| Assign / Unassign | handleAssign / handleUnassign | thread tool buttons |
| Attach (streaming) | handleAttach | n/a (web only) |
| Subscribe / Mute | handleNotify | thread notify button |
| PublishPatch / MergePatch(mode) | handlePatchPublish / handlePatchMerge | patch tool buttons |
| DeleteFork | (fork delete page) | Fork delete |

Form feedback retention (which form failed, which values are kept, never
passwords) is adapter work and keeps its own tests: TUI values copied into
the session arena (`src/ui/widget/thread.zig:3236`), server web flash
storage, local web cookie (`src/web.zig:472`).

### Phase 4: repo, user and notification operations (1 week)

- Repo: `CreateRepo`, `UpdateRepoSettings`, `DeleteRepo` (creator only),
  `Grant`/`Revoke`/`Promote`/`Demote`, `ProtectBranch`/`UnprotectBranch`/
  `SetDefaultBranch`, `Undo`, `Sync` (progress callback parameter).
- User: `RegisterUser`, `UpdateUserSettings`, `AddKey`, `RemoveKey`,
  `DeleteUser` (password and confirm verified inside; `serve.deleteUser` calls
  the same operation with a bypass flag it alone can set).
- Notifications: `ListNotifications` (ids, unread count, `last_child_id`),
  `MarkRead`, `Dismiss`; `notify_action` enrichment helper.
- `Session.HostRequest` stays. The host loop calls the operations while the
  UI keeps scheduling, the "syncing…" frame, navigation and failure display
  (`src/ui.zig:2893`, `src/ui/Repo/Events.zig:802`).
- Login and logout stay in `web.zig`; `evt.User.verifyCredentials` is their
  domain function.

Done when: no `fn handle*` in `web.zig` except login, logout, search and
attachment byte serving calls `evt.`, `pch.` or `fork.` directly, and no TUI
widget calls `evt.consume` directly. Handler length is not a criterion.

### Phase 5: reads and page composition (1.5 weeks)

1. Remaining reads as bridges over the loaders: `GetRepo`, `ListFiles`,
   `ReadFile`, `ListCommits`, `GetCommit`, `Diff`, `ListRefs`,
   `ListPatches(view)`, `GetPatch`, `ListDiscussions`, `GetDiscussion`,
   `ListEvents`, `ListRepos`, `ListUsers`, all with fork addressing where it
   applies. Decoding moves to route adapters.
2. Split `Issues`/`Patches`/`Discussions` loaders into window and detail
   loaders; `Patches.init` loses `*ui.Session`.
3. `Repo.init` composes the reads with one open repo via `runOpen`.
4. Snapshot tests: JSON of a fixed set of routes identical before and after.

### Phase 6: MCP over HTTP and personal tokens (1.5 weeks)

1. Tokens: `CreateToken`, `RevokeToken`, `ListTokens`; stored hashed under
   the data dir next to `SessionStore` (never as events). Creation requires
   the logged-in user's password; tokens have an optional expiry and are
   revoked with the account. First cut has no scopes. New `UserView.tokens`
   in both UIs, including a hyperhaxy page.
2. `web.zig`: `POST /mcp` requiring `Authorization: Bearer`; `GET /mcp` 405;
   notifications answered with `202` and no body; `MCP-Protocol-Version`
   header handled; **Origin validated** against the configured `web_url`
   (the transport spec requires it); stateless, no session ids. Body size
   bounded; one in-flight call per connection.
3. Standard MCP authorization discovery (OAuth resource metadata) is out of
   scope; personal tokens cover manually configured clients. Revisit if a
   client needs discovery.

### Phase 7: JSON API (1 week, optional)

`/api/v1/<tool_name>` over the same registry, same tokens, same `classify`
mapping to HTTP statuses. Mostly deciding URL and pagination shape, once the
MCP wire format has settled them.

## 5. Cross-cutting rules

- **wasm**: guards stay in front of `Ctx` construction and operation calls
  in widgets; `mcp.zig` is never imported from `ui.zig` or `web.zig`'s wasm
  path; `zig build wasm` runs with every test run from phase 0.
- **Feedback wording** stays in the presentation layers; `classify` returns a
  kind, not prose.
- **No automatic retries** for creates, merges or sync anywhere.
- **Commits** per phase and per operation group, so an upstream PR series
  stays possible.

## 6. Risks

1. Loader split in phase 5 is the riskiest refactor; the snapshot tests are
   the guard.
2. Fork-backed drafts span the user repo and the copied fork; `CreateThread`
   for patches and `DeleteFork` need lifecycle tests across both.
3. Search syntax is passed through as one string; structured filters later
   are additive.
4. Token storage and revocation on account deletion need a test with
   `DeleteUser`.
5. Operator mode (`--data-dir --user`) is a password bypass by design; keep it
   stdio-only and documented next to `delete-user`.

## 7. Estimates

| Phase | Effort |
|---|---|
| 0 wiring | hours |
| 1 context, resolution, auth, errors | 2 days |
| 2 vertical slice to MCP | 1.5 weeks |
| 3 remaining thread/patch/comment operations | 1.5 weeks |
| 4 repo, user, notification operations | 1 week |
| 5 reads and page composition | 1.5 weeks |
| 6 MCP over HTTP, tokens, UI | 1.5 weeks |
| 7 JSON API | 1 week |

A usable local-mode MCP (`haxy mcp` in a repo, issues and comments read and
write) lands at the end of phase 2, about two weeks in. Full extraction with
TUI and web parity plus stdio is 6 to 7 weeks; HTTP and tokens add 1.5. These
match the reviewer's 5 to 8 plus 1 to 3 range.

## 8. Out of scope, deliberately

OAuth discovery for MCP; MCP resources and prompts; SSE streaming on the HTTP
transport; token scopes; structured search filters; upstreaming.

## 9. Review log

Raw reviews are in `docs/reviews/`.

- 2026-11-09, phases 0–2 implemented test-first in the fork on branch
  `domain-layer` by Opus 5.5 implementors, each phase reviewed by Codex
  (`docs/reviews/02-phase0-1-codex.md`, `03-phase2-codex.md`) and fixed before
  the next. Phase 0–1 review: no blockers; fixed local `resolveRepo` ownership,
  wasm compile wired into `zig build test`, shared authorization path,
  `retryable` never true, `RepoSource` moved into the domain so `domain.zig`
  no longer imports `ui.zig`, and the error convention change recorded in
  §3.3. Phase 2 review: one blocker (lenient MCP argument coercion including a
  float-to-integer panic) fixed with schema-driven validation before parsing;
  web handlers pre-authorize before reading the body; TUI survives a tab or
  repo disappearing mid-session; a committed-but-unconsumed local git write
  returns `CommittedUnconsumed`, classified `changed = true`; MCP envelope and
  `initialize` validation; setup failures as `-32603`; conservative tool
  annotations; added tests for user removal between calls, a full local
  session and schema derivation. Suite: 105 tests. `notify_action` deferral
  noted in §3.4.
- 2026-11-09, Codex (gpt-5 class) read-only review of revision 1 against both
  repos. Twenty findings; all verified against the code where they cited
  lines, and folded in above. The substantive changes: local refresh split
  from reads; notifications extracted with ids and explicit `MarkRead`;
  three-level authorization including authorship, creator-only delete and
  password re-verification; ownership rules for arenas and the admin repo;
  `HostRequest` kept; fork addressing and `DeleteFork`; `withRepo` no longer
  the sole opener; error sets plus `classify` instead of per-command outcome
  unions; explicit tool names and `ThreadKind`; decoded inputs; streaming
  attachments; stdio lifecycle and version negotiation corrected; Origin
  validation and 202 for notifications on HTTP; OAuth explicitly deferred;
  phases reordered around a vertical slice; estimates raised. Corrected
  factual errors from revision 1: mergeability is already read-only; the
  same-origin claim; hyperhaxy is touched in phase 6; the `description`
  field/declaration clash.
