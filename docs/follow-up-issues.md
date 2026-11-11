# Follow-up issues

Things found while building the domain layer (phases 0 to 4) and the HTTP test
harness that are not fixed. Written 2026-11-10 against the haxy fork at
`b123eaf` (branch `domain-layer`); file and line references are to that
commit. `66c1ab6` is the last commit before the domain layer.

Each entry says where it came from, how to see it, and what a fix would
involve. The order within a section is by how much it matters.

## 1. Faults in haxy that predate the domain layer

These behave the same at `66c1ab6`. None was introduced by the refactor, and
each is a candidate for an upstream fix on its own.

### 1.1 A long branch or tag name breaks every page of its repo

(Phase 5 recorded its page snapshots without fixing this; the arranged data
holds no such ref. It is still the most serious open fault.)

A branch or tag whose url-encoded name is longer than 512 bytes makes the
repo's pages answer 500 `RouteTooLong`, as HTML and as JSON, for every reader.
193 raw bytes are enough (80 `é` and 33 `x` encode to 513).

- Why: routes hold a ref in a 512-byte array (`src/ui.zig:380`,
  `ref_route_max_len`). `refLink` and the window links in
  `src/ui/Repo/Refs.zig:430,446` return `error.RouteTooLong` for a name that
  does not fit. Every repo page builds the refs view whatever tab is selected
  (`src/ui/Repo.zig:390,551`), and a JSON request builds the widget root
  before returning. So one ref fails the whole page.
- Who can cause it: anyone with write access can push an unprotected branch
  over ssh. The length rule in `ProtectBranch` and `SetDefaultBranch` does not
  apply to pushed refs. A local repo can hit it with its own refs.
- What still works: other repos and the git transport. A POST can succeed and
  then redirect into the broken page.
- Seen by: a probe run at `66c1ab6` (repo root, branches, refs, commits and
  settings pages all 500) and the repos slice on today's code. The boundary
  tests in `src/test/web/branches.zig` deliberately do not create such a
  branch.
- Fix: either let routes carry any valid encoded ref name, or give a ref whose
  link cannot be built a fallback (listed without a link, cursor skipped) so
  it never aborts page construction. Add a web test that creates the branch
  and requests the files, issues and settings pages as HTML and JSON. This is
  a behaviour change; record it in the plan's review log.

### 1.2 A form body cut short is acted on as if complete

A POST whose body is shorter than its `content-length` is read to end of
input and parsed as the whole form (`readFormBody`, `src/web.zig:3184`). A
client that drops mid-body can have a partial form acted on: with every field
present in the part that arrived, a repo is created.

- Seen by: `src/test/web/connection.zig`, the malformed-bodies test (declared
  100 bytes, sent fewer; 303 and the repo exists).
- Fix: compare the bytes read with the declared length and answer 400 when
  they differ. Check what `std.http.Server`'s body reader reports at early end
  of input before choosing where to detect it.

### 1.3 Requests a browser can send answer 500

Each lets an error out of the handler into the connection loop's catch-all
(`src/web.zig:165`), which answers 500 with the error name as the body.

| Request | Answer | Where |
|---|---|---|
| Closing a merged patch, or merging one twice | 500 `PatchAlreadyMerged` | `src/event/Patch.zig:177`; `domain.classify` already calls it a conflict (`src/domain.zig:605`), but `handleThreadStatus` and `handlePatchMerge` do not map that kind |
| Local mode, a patch form failure other than a missing title (bad target branch, same branch) | 500 `InvalidFormFeedback` | `respondThreadFormFailure`, `src/web.zig:513`: the local flash cookie can only carry `required_title` and an assignment failure |
| An upload shorter than its declared length | 500 `EndOfStream` | the attachment read in the event module |
| A form field with invalid percent-encoding (`name=%zz`) | 500 `InvalidPercentEncoding` | `decodeFormValue`, `src/web.zig:3197` |
| A form larger than 64 KiB | 500 `StreamTooLong` | `readFormBody`, `src/web.zig:3184` |

- Seen by: `src/test/web/patch_edit.zig`, `merge.zig`, `patches.zig`
  (the local missing-branch test), `attach.zig`, `connection.zig`. The tests
  assert the 500s, since that is what both versions do.
- Fix: 409 for the first (the classification is there; the adapters need the
  mapping), a wider local flash encoding or a flash file for the second, 400
  for the third and fourth, 413 for the fifth. Each changes a test's expected
  literal and needs a `// differs from 66c1ab6:` comment.

### 1.4 `ui.urlEncodeRef` hands back less than it allocated

`urlEncodeRef` (`src/ui.zig:2125`) returns `Allocating.written()`, so only an
arena may own the result. `sendAttachment` freed it with a general allocator
on every download; that is fixed in `b123eaf`. Nothing stops the next caller
making the same mistake.

- Fix: say so in the doc comment and name the parameter for an arena (it is
  already `aa`), or return an owned slice (`toOwnedSlice`). Codex found no
  other caller with the fault.

### 1.5 A removed account's name can be registered again

After an account is deleted, someone else can register its name. Anything
keyed by name (repo paths like `dave:x`, assignee lookups by name) can then
resolve to the new account.

- From: the phase 4 review (`docs/reviews/05-phase4-codex.md`, B8: "preserve
  existing name reuse").
- Fix: a decision first: reserve removed names, or accept reuse and audit
  what is keyed by name.

### 1.6 Smaller

- The repo settings UI would show an owner tab role as "members" and save it
  back as write (`src/ui/Repo/Settings.zig`, `labelRole`). No path can store
  an owner tab role today, so it cannot be reached.
- On a local host, `POST /repo/new` and `POST /user/new` answer 404
  "new event target not found" instead of 405, because the generic `new`
  route claims them (`src/web.zig`, `handleNew`).
- `zig fmt --check` flags `src/domain.zig`, `src/domain/patches.zig` and
  `src/mcp/jsonrpc.zig`.

## 2. Decisions left open by the refactor

### 2.1 A local host and a server-style thread url (D4)

On a local host, `POST /alice:open/issues/new` with an empty title answers
404 "repo not found" today. At `66c1ab6` it answered 303 with a
required-title flash for a page that does not exist there, because the title
was validated before the url's repo was resolved. Codex said restore
(`docs/reviews/06-http-harness-codex.md`, section 3). Today's behaviour was
kept, because restoring means validating the title in the adapter as well as
in the operation. The test is in `src/test/web/threads.zig` under a
`differs` comment.

- To restore: in `handleThreadNew`, when a local host's url names no repo,
  read the body and answer the required-title failure before the 404. About
  eight lines, plus flipping the test.

### 2.2 MCP choices that could go either way

From phase 4, recorded in the plan's review log:

- `sync` runs without the local refresh the other tools get first.
- A tool error does not say in its text that a change was made when the
  failure is one classified `changed`; only sync reports its stage.
- `update_repo_settings` hides the `owner` tab role through a per-field
  schema override (`tool_schema_enums`) instead of a narrower input type.

## 3. Tests still missing

### 3.1 Phase 5 page snapshots

Whole-page JSON baselines for a fixed set of routes, taken before the loader
split. The method is in the plan (phase 5, step 4) and the route list in
section 6 of `docs/reviews/06-http-harness-codex.md`. The harness has
`getJson` but no normaliser and no deterministic fixture yet: `session.now`
is the wall clock, ids are random, `session.user_id` is a byte array,
`session.ansi_art` is picked at random, commits carry real timestamps, and a
local repo's displayed name is its temp directory's.

### 3.2 Not reachable through the HTTP harness as it stands

- A conflict in a patch's status, revision or target branch. Two local repos
  synced through a file remote give conflicts in title, labels and
  description only (`src/test/web/conflicts.zig`); the other fields need the
  second repo to have the patch's source branch with shared history.
- Merging a fork-backed patch, which needs a revision pushed into the fork.
  `src/test/net.zig` pushes over real sockets and could arrange it.
- Sync failing after the local merge (`SyncMergedNotPushed`,
  `SyncPushedNotRefetched`) and a refusal at the refetch stage. The domain
  test in `src/test/domain/sync.zig` has an ssh stand-in that refuses at the
  push stage; nothing does over HTTP, and nothing reaches the refetch stage.
- Post-commit cleanup failures (`RepoRemovedDirKept`, `UserRemovedDirKept`):
  no way to inject them.
- Notification paging past one window (more than 20 notified threads).
  Reachable, not written.
- Duplicate request headers: the client's header override cannot produce
  them; a raw-bytes entry point would.
- The harness's unflushed-response check has never been seen to fire, because
  no handler leaves bytes unflushed. Breaking a flush once would prove it.

### 3.3 Outside the web seam

From the phase 4 review, still untested:

- TUI: a role revoked between a widget's pre-check and the operation (the
  widgets now handle it; no test drives it), form retention and clearing,
  undo failure display, sync setup failures.
- `Session.rememberSshKey` at the key limit.
- `haxy delete-user`: its output and errors on the command line.

## 4. Housekeeping

### 4.1 The parity run is manual

Running the web tests against `66c1ab6` is the check that the handlers still
answer as the originals did. It took these steps by hand:

1. `git worktree add --detach <dir> 66c1ab6` from the fork.
2. In `<dir>`: apply the `serveConnection` split (`src/web.zig`), the
   `haxy.wasm` import for the test module (`build.zig`) and the
   `sendAttachment` arena fix (`src/web.zig`); add
   `_ = @import("test/web.zig");` to `src/test.zig`.
3. Copy `src/test/web.zig` and `src/test/web/` from the fork.
4. `zig build test -Dtest-filter="web:" --summary all`.
5. Compare the failing tests with the `// differs from 66c1ab6:` comments
   (`grep -n "differs from 66c1ab6" src/test/web/*.zig`). At `b123eaf`:
   345 of 357 pass and the twelve failures are exactly the tests whose
   comment records an accepted difference. The six attachment-serving
   comments record the arena fix and do not fail.
6. `git worktree remove --force <dir>`.

A script that does this and fails on any unexpected name would let it run
before each phase lands. It depends on the web tests importing only `std`,
`xit`, `web.zig` and `event.zig`; a test that imports the domain layer breaks
it at step 4.

### 4.2 The build cache grows without bound

`haxy-hyperhaxy/.zig-cache` reached 39 GB and filled the disk during this
work. Every distinct `-Dtest-filter` string builds a new test binary of about
100 MB. Stale directories under `.zig-cache/o` can be deleted at any time
when no build is running; the small ones (compiler runtime objects) are worth
keeping.

### 4.3 Upstream

The attachment fix (1.4), the long ref name fix (1.1) and the truncated-body
check (1.2) do not depend on the domain layer and could go upstream as their
own changes.

## 5. Added in phase 5 (2026-11-11)

Found while adding the reads and recomposing the pages. References are to the
phase 5 tree. Phase 6, step 0 in the plan covers the largest item (result
types of their own for the reads a machine calls, and a bound on replies) and
is not repeated here.

### 5.1 Faults that predate the domain layer

- **A file or directory whose name has a space cannot be addressed by any
  url.** The files route takes `path:` raw: it is not percent-decoded on the
  way in and not encoded when a link is written. `path:dir%20A` and
  `path:tok%20plus.txt` answer 404, and a raw space cannot appear in a request
  line. `path:dir%2541` is also 404 where `path:dir%41` works. The diff
  route's `path` is handled the same way and probably shows "no changes" for
  such a file (read, not run). Seen by: the edges snapshots
  (`src/test/web/golden/edges/`, the `path:` cases), which record today's
  answers. Fix: decode the path where the route is read and encode it where
  links are built, as phase 5 did for searches and refs; the edges goldens
  for those cases then change on purpose.
- **Pages that probably answer 500 for an id that names nothing** (read from
  the code, not run): the commits page with a `from` that is a well-formed
  oid of no commit (`Commits.zig`, the plain-log walk); the diff page and the
  fork diff page with an object oid that does not exist (`Diff.init`,
  `Fork.zig`). The reads check the oid first and answer not found.
- **The drafts window counts a draft whose fork was deleted** while leaving
  it out of the list (`Patches.zig`, the drafts index size), on the page and
  in `ListPatches` alike.
- **The files page at a patch revision does not check the patch tab**, nor
  does the revision diff. The review accepted this as policy (turning the tab
  off hides fork browsing, not the repo's revision files); it is written
  here so phase 6 carries the same rule over HTTP on purpose.

### 5.2 Left open by phase 5

- **A tool error does not say which input was wrong.** A contradictory
  combination answers `get_diff failed (invalid_input): InvalidReadArguments`
  and the caller must work out which rule it broke from the schema notes.
- **Description details**: `list_files` says it preloads "up to about 2 MB"
  where about 4 MB was measured (one file can cross the budget and the README
  is exempt); the shared fork note names inputs (`ref_kind`, `patchrev`) that
  `get_commit` and `get_diff` do not have; `read_file` says "up to 5000
  lines" but a window also stops at a cell budget.
- **The user page and the fork page** (`User.init`, `Fork.init`) still decide
  visibility with `session.userId()`, which is not checked against removed
  accounts, while the repo page and the notifications header use the
  session's checked context (`Session.pageCtx`). The snapshots pin today's
  behaviour; moving these two pages onto `pageCtx` would make all four
  agree.
- **The local `ListPatches` drafts view** returns an empty window, not
  "unavailable here", because local repos have no drafts. Accepted; noted in
  the schema.

### 5.3 Tests still missing

- A truncated diff (needs about a million changed lines).
- Storage failures inside xit repos: objects and refs live in one db file,
  so the tests that remove or corrupt a loose object only run on git.
- HTML output and the TUI: the snapshots compare JSON. A JSON request does
  build the widget root, so construction is exercised, but nothing asserts
  links, forms or navigation on the rendered page.
- Nine of the nineteen account-read tests (`src/test/domain/accounts.zig`)
  were never shown able to fail; the mutation run covered the other ten.
  Their order checks compare sets, because the order of repos active in the
  same second is by id.
- A second window of notifications.
- The snapshot tests share one frozen clock and one random source
  (`snapshot.zig`, `Det`) and must run one at a time. Zig runs a test binary's
  tests serially today; if that changes, the state has to become per world.

### 5.4 Housekeeping

- The goldens are 18 MB on disk in 411 files (well under 2 MB compressed).
  Each repo page snapshot carries every tab's data, because the page does.
- Updating goldens is deliberate and manual:
  `HAXY_SNAPSHOT_UPDATE=1 zig build test -Dtest-filter="web: page snapshots"`.
  Update mode does not delete goldens that are no longer taken.
- The edges goldens were recorded from `b123eaf` to prove parity with the
  code before phase 5. That check is done; from here they are ordinary
  baselines of the current tree.
