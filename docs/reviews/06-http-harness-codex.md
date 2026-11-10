The harness is a useful and mostly faithful basis for HTTP adapter tests, but **I would not yet treat this tree as the phase 5 behavioural baseline**. The production seam and attachment allocation fix look sound. The remaining gates are resolving the four deliberate failures, testing unread-body refusal and connection reuse, and capturing deterministic **whole-page JSON**, including currently untested patch-edit and conflict views. I reviewed `delete.zig`, `branches.zig`, `patches.zig`, and `merge.zig` in depth and skimmed the remaining files. No files were changed and no builds or tests were run; execution results below are your supplied results.

**2. Blockers before the loader split, then should-fix items**

These are blockers to declaring the baseline ready, not objections to landing preparatory tests.

1. **Resolve the four failing expectations before recording goldens.** Accept D1/D2 and restore D3/D4 as explained below. The merge test additionally contains a wrong historical oracle: [merge.zig:203](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/merge.zig:203) expects `InvalidPatch`, whereas this fixture reaches `NotFound` at 66c1ab6. Historical `patch.zig:1099` obtains the event moment before its missing-patch check; historical `event.zig:2051` can fail because no thread-event history exists. Update the accepted test to 404 `"event not found"` with an accurate `differs` comment, and also exercise a missing patch in a repository containing events.

2. **The harness does not establish prompt refusal without reading the body, or working keep-alive.** Every `send` supplies an immediately available body followed by EOF, then starts another connection for the next request: [harness.zig:329](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/harness.zig:329), [harness.zig:362](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/harness.zig:362). Removing `keep_alive=false` from a refusal can therefore leave its status/body tests passing while a real slow client blocks the server. Zig’s responder drains unread bodies before responding on a reusable connection and suppresses drain errors: [Server.zig:630](/opt/homebrew/Cellar/zig/0.17.1/lib/zig/std/http/Server.zig:630). This particularly undermines the “before any body is read” claim at [attach.zig:204](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/attach.zig:204).
   
   **Fix:** add a reader that records—and independently fails the test on—any forbidden body-read attempt, even if the server catches the read error. Assert zero body reads and `Connection: close` for representative login, permission, missing-repo and upload refusals. Add a successful POST followed by GET through one `serveConnection` invocation, including a request coalesced into the reader’s buffer.

3. **Scalar JSON assertions are not the required snapshot baseline.** [harness.zig:607](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/harness.zig:607) checks selected scalar paths; it cannot detect disappearing unrelated fields, changed windows, ordering, or links. The plan explicitly requires identical route JSON: [domain-layer-plan.md:433](/Users/florinbraghis/code/haxy/hyperhaxy/docs/domain-layer-plan.md:433). Capture the corpus described in section 6 before changing loaders.

The concrete should-fix findings are:

| Finding | Evidence | Concrete fix |
|---|---|---|
| Patch flash “comes back once” checks a fresh client. The original client consumes the first response inside the helper and is destroyed; the second browser never had its cookie. | [patches.zig:161](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/patches.zig:161), [patches.zig:189](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/patches.zig:189) | Pass a caller-owned client into the helper; GET twice with that client and assert cookie clearing. |
| An absence assertion can pass on a failed/non-JSON page. Fork deletion checks `jsonAt(...forks.0) == null` without establishing that the returned user page or forks array exists. | [delete.zig:426](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/delete.zig:426), [harness.zig:572](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/harness.zig:572) | Require status 200, JSON, the expected page variant, and an empty **existing array**. Add an array-length assertion helper. |
| The attachment boundary follows the production constant. An accidental limit change changes both implementation and test input. | [attach.zig:206](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/attach.zig:206) | Pin the historical `10 * 1024 * 1024` literal; test exact-limit acceptance and one-byte-over rejection. Historical source: `66c1ab6:src/event/Attachment.zig:32`. |
| The squash test does not prove that multiple commits become one. Its source contains one commit, and it checks only the merged marker and tip message. | [patches.zig:25](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/patches.zig:25), [merge.zig:49](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/merge.zig:49) | Arrange two source commits; inspect resulting history, parent/count and file contents through GETs. |
| Response framing accepts contradictory Content-Length headers by retaining the last one. It also accepts malformed status delimiters and insufficiently validates header names. | [harness.zig:513](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/harness.zig:513), [harness.zig:519](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/harness.zig:519) | Reject conflicting lengths, validate the complete status-line grammar and header field names. Add parser tests with handcrafted responses. |
| Invalid cookie paths are accepted verbatim. `Path=` can subsequently index before the slice; a relative Path behaves differently from a browser’s default-path fallback. | [harness.zig:423](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/harness.zig:423), [harness.zig:433](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/harness.zig:433) | Use the default path when Path is empty or does not start with `/`; guard empty paths. Test path boundaries, replacement, deletion and multiple Set-Cookie lines. |

Other harness conclusions:

- **Truncation and trailing bytes:** correctly rejected using the declared length; an abandoned partial response does not silently become a successful shorter body. Unsupported transfer encoding fails explicitly. [harness.zig:523](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/harness.zig:523)
- **Flush fidelity:** not tested. The allocating writer exposes buffered bytes, and the harness itself flushes after the server returns. A missing production flush could be concealed. Use a buffered capture writer for connection tests and inspect bytes delivered by server-side flushing. [harness.zig:370](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/harness.zig:370)
- **Cookies:** normal absolute-path boundary matching, longest-path-first sending, replacement by name/path, multiple Set-Cookie processing and nonpositive Max-Age deletion are implemented correctly. Positive Max-Age expiration, Expires, Domain and Secure semantics are not modeled. That is sufficient for the currently emitted cookies, but should be documented as a bounded jar. [harness.zig:312](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/harness.zig:312), [harness.zig:389](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/harness.zig:389), [harness.zig:409](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/harness.zig:409)
- **SplitReader:** for the current nonempty form requests, it faithfully models a client withholding its body until after the head. Clearing the hook before calling it prevents double invocation; errors propagate separately. Every current in-flight test asserts `hook_ran`. However, the hook means “next underlying read after the head”: with an empty or ignored body, that read can be body disposal or the next request-head read. It is not a general proof that application processing paused at the intended point. [harness.zig:466](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/harness.zig:466), [harness.zig:388](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/harness.zig:388)
- **Header overrides:** case-insensitive replacement and null suppression work. They deliberately cannot generate duplicate request headers; a raw-wire entry point would be needed for those tests. [harness.zig:350](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/harness.zig:350)
- **JSON lookup:** present JSON null is correctly distinguished from a missing path by `expectJson`. Dotted lookup is adequate for the current schema, but is not an escaping-capable general JSON path language. [harness.zig:571](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/harness.zig:571), [harness.zig:608](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/harness.zig:608)
- **Memory:** normal-path ownership looks sound: response bytes/JSON/logs are copied into the response arena, and client cookie storage survives response teardown. Replacement cookie values accumulate until client teardown, which is reasonable for these short-lived clients. [harness.zig:255](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/harness.zig:255), [harness.zig:499](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/harness.zig:499)
- **Diagnostics:** `describe`’s `else` belongs to the inner `session == .object` condition. A response with no session JSON can omit its body from diagnostics. Give the outer optional check its own fallback. [harness.zig:659](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/harness.zig:659)

The production changes themselves are acceptable. `handleConnection` retains ownership and lifetime of both stream buffers while `serveConnection` runs; the request loop, error handling and git dispatch are unchanged. The git callback still receives the same server object that owns the request and underlying reader/writer, and its existing flush remains: [web.zig:127](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:127), [web.zig:143](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:143), [web.zig:158](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:158), [serve_http.zig:44](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/serve_http.zig:44). The wasm import supplies the embedded file required by web rendering: [build.zig:83](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/build.zig:83).

The attachment arena fix is correct: `urlEncodeRef` returns `Allocating.written()`, not an owned allocation of that length, and the function’s arena now releases the backing allocation. [ui.zig:2125](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui.zig:2125), [web.zig:1617](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1617), [web.zig:1643](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1643). I found no remaining equivalent wrong-length free among its callers or escaping `Allocating.written()` returns: the route builders, resolved refs and undo descriptions use arenas. Representative ownership evidence: [ui.zig:1488](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui.zig:1488), [Commits.zig:91](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo/Commits.zig:91), [Undo.zig:171](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo/Undo.zig:171). Making the arena-only contract explicit would prevent recurrence.

The deep sample otherwise contains meaningful outcome assertions. Deletion checks surviving/deleted pages and credential races; branches use independent encoded literals; patch creation checks retained fields and persisted content. Historical samples agree for branch feedback (`66c1ab6:src/web.zig:900`), required-title feedback (`:1182`), deletion responses (`:1115`, `:1129`) and merge conflict (`:1377`). No cross-test dependence or definite clock/random-order flake was found: fixtures are fresh, and sequential events are ordered by graph generation rather than timestamp ties. [harness.zig:77](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/harness.zig:77), [event.zig:1378](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/event.zig:1378). Mutating each test once does not establish every claim in a compound test—the flash and squash examples demonstrate that limitation.

**3. D1–D4 verdicts**

| Difference | Verdict | Reason and action |
|---|---|---|
| **D1: authorization changes while the body is withheld** | **ACCEPT the whole family** | Keep pre-body refusal **and** operation authorization. Permissions removed before the mutation executes should take effect. Settings demotion leaves the public repo visible but removes owner permission: **403** is correct. Revocation from `alice:secret` removes visibility: **404** is correct. Disabling the patch tab removes that target: **404 `"repo not found"`** matches established tab-off handling. If visibility remains and only write permission is lost, use **403**, not a blanket 404. Evidence: [domain.zig:398](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain.zig:398), [repos.zig:450](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/repos.zig:450), [threads.zig:294](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/threads.zig:294). Change [patches.zig:370](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/patches.zig:370) to assert refusal, add a `differs` comment, then re-enable the tab and verify no patch was created. |
| **D2: nonexistent patch merge** | **ACCEPT** | A well-formed missing resource should return 404, not expose an internal error. Keep [web.zig:1490](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1490). Correct the historical comment to **500 `"NotFound"` for this fixture**, and assert today’s 404 `"event not found"`. |
| **D3: logged-out server POST using a local thread URL** | **RESTORE** | This accidentally reverses the established login-before-repository contract. Historical `web.zig:593` checks the session before identity at `:595`; today identity failure precedes authorization at [web.zig:1289](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1289) and [web.zig:1349](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1349). Check `hasSession` before context construction/identity resolution in both handlers. Preserve **403 `"log in to make changes"`**. This also avoids anonymous admin I/O. |
| **D4: local untitled POST using a server-style URL** | **RESTORE for this parity refactor** | The old ordering is unusual, but there is no permission or functional requirement to change it here. Historical local authorization succeeds at `web.zig:590`, title validation returns feedback at `:1182`, and repository resolution follows at `:1200`. Preserve local required-title feedback before rejecting this invalid base; valid-title requests should remain 404. The existing oracle at [threads.zig:785](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/threads.zig:785) is accurate. Apply the ordering consistently to issue, discussion and patch creation. |

Review 03 explicitly requires operation authorization to remain: [03-phase2-codex.md:13](/Users/florinbraghis/code/haxy/hyperhaxy/docs/reviews/03-phase2-codex.md:13). Review 05’s settings row merely describes the additional check; it is not itself an explicit acceptance: [05-phase4-codex.md:12](/Users/florinbraghis/code/haxy/hyperhaxy/docs/reviews/05-phase4-codex.md:12). D1 supplies that explicit acceptance now.

**4. Every existing `differs from 66c1ab6` comment**

There are **12**.

| Comment | Accurate? | Prior acceptance exists? |
|---|---|---|
| [users.zig:414](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/users.zig:414) | Yes: removed account’s empty email previously produced validation feedback. | **Exists:** review 05 B2, [line 154](/Users/florinbraghis/code/haxy/hyperhaxy/docs/reviews/05-phase4-codex.md:154). |
| [keys.zig:199](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/keys.zig:199) | Yes: malformed key previously reached validation first. | **Exists:** review 05 B2. |
| [notify.zig:263](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/notify.zig:263) | Yes: a nonexistent target previously acquired a subscription. | **Exists:** review 04 A, [line 118](/Users/florinbraghis/code/haxy/hyperhaxy/docs/reviews/04-phase3-codex.md:118). |
| [threads.zig:299](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/threads.zig:299) | Yes. | **Exists as a general instruction:** review 03 finding 2 requires operation authorization. The specific 404 is approved under D1 here. |
| [repos.zig:446](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/repos.zig:446) | Yes. | **Missing explicit acceptance in the cited row.** It describes the difference. D1 accepts it now. |
| [patches.zig:480](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/patches.zig:480) | Yes: foreign draft previously propagated `InvalidPatchDraft` as 500. | **Exists:** review 04 F, [line 123](/Users/florinbraghis/code/haxy/hyperhaxy/docs/reviews/04-phase3-codex.md:123). |
| [attach.zig:299](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/attach.zig:299) | Yes: wrong-kind wording changed. | **Exists:** review 04 G explicitly accepts the wording, although G’s overall verdict is CHANGE for authorization ordering: [line 124](/Users/florinbraghis/code/haxy/hyperhaxy/docs/reviews/04-phase3-codex.md:124). |
| [attach.zig:47](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/attach.zig:47) | Yes: wrong-length-free prerequisite. | **Missing prior acceptance; accepted here.** |
| [attach.zig:77](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/attach.zig:77) | Yes, same allocation issue. | **Missing prior acceptance; accepted here.** |
| [attach.zig:111](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/attach.zig:111) | Yes, same allocation issue. | **Missing prior acceptance; accepted here.** |
| [attach.zig:130](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/attach.zig:130) | Yes, same allocation issue. | **Missing prior acceptance; accepted here.** |
| [attach.zig:364](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/attach.zig:364) | Yes, same allocation issue. | **Missing prior acceptance; accepted here.** |

The five allocation comments describe a prerequisite fix, not a deliberate change to the HTTP contract. None falsely claims an earlier approval.

**5. POST route coverage**

The tables enumerate the actual suffix dispatchers: **32 server routes** at [web.zig:199](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:199), and **11 local routes** at [web.zig:242](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:242).

`Y` = explicit coverage; `gap` = missing direct coverage; `partial` = some subtypes only; `—` = inapplicable. `O/R/P` means **logged out / insufficient role or wrong actor / private repository**. “Malformed” below means field/route input; raw framing is addressed afterward. Evidence filenames in the tables are under `src/test/web/`.

| Server suffix | Success and form failures covered | O / R / P | Malformed input and remaining gaps | Local mode |
|---|---|---|---|---|
| `login` | Success, unknown user, wrong password: `smoke.zig:47,67`; `users.zig:193` | Y / — / scoped-private gap | Blank/missing fields gap; public scoped redirect covered at `users.zig:227` | Exclusion: `users.zig:432` |
| `logout` | Success, token revocation; no form failures: `users.zig:248,269` | gap / — / — | Malformed cookie/base gap | Exclusion: `users.zig:432` |
| `repo/new` | Both hashes, visibility, copying; required/invalid/taken name, invalid copy: `repos.zig:43,59,73,116,140,158,173` | Y / — / Y, copy source | Bad hash/access and missing hash: `repos.zig:189`; missing access not directly tested | Exclusion gap |
| `user/new` | Success; required/invalid/taken name, required/taken email, required/mismatched password: `users.zig:49,76,80,89,93,97,101` | Y / logged-in refusal Y / — | Invalid names and validation precedence covered: `users.zig:106,154,173` | Exclusion gap |
| `user` | Email/password changes; required/taken email, wrong current password, required/mismatched new password: `users.zig:321,336,362,366,370,374,378` | Y / — / — | Arbitrary base gap; removed session covered at `users.zig:401` | Exclusion: `users.zig:432` |
| `addkey` | Success; invalid, unsupported, duplicate, limit: `keys.zig:57,89,107,124,160` | Y / — / — | Invalid key covered; removed session at `keys.zig:186` | Exclusion: `users.zig:432` |
| `removekey` | Success and absent-key no-op: `keys.zig:211,242` | Y / — / — | Bad route/fingerprint: `keys.zig:262,298` | Exclusion gap |
| `delete` | Repo/user/fork success; wrong confirmation/password for all: `delete.zig:70,143,159,277,339,414,448` | Y / Y / Y | Wrong target page: `delete.zig:215`; malformed fork ID gap | Account exclusion: `users.zig:432`; repo/fork variants gap |
| `settings` | Rename/settings success; required/invalid/taken name: `repos.zig:224,276,307` | Y / Y / Y | Bad access/role and wrong page: `repos.zig:324,403`; auth at `:346,367,390` | Exclusion: `repos.zig:461` |
| `grant` | Success; unknown/removed/duplicate user: `members.zig:49,69,90,105` | Y / Y / Y | Wrong route gap; auth at `members.zig:236,259,281` | Exclusion: `repos.zig:461` |
| `revoke` | Success and self-revoke: `members.zig:123,176` | Y / **gap** / Y | Missing user/member/row: `members.zig:204` | Exclusion gap |
| `promote` | Success: `members.zig:155`; no flash failures | **gap** / Y / **gap** | Missing member/row: `members.zig:211` | Exclusion gap |
| `demote` | Success and self-demote: `members.zig:165,176` | **gap / gap / gap** | Missing member/row: `members.zig:211` | Exclusion gap |
| `protect` | Success; duplicate, missing, limit, too-long: `branches.zig:68,111,176,197,214` | Y / Y / Y | Encoded boundaries/Unicode: `branches.zig:83,111`; auth at `:330,358,381` | Exclusion: `repos.zig:461` |
| `unprotect` | Success and absent-protection no-op: `branches.zig:83,238` | Y / **gap** / Y | Too-long/missing row: `branches.zig:165,258` | Exclusion gap |
| `default` | Success, SHA256; missing/too-long branch: `branches.zig:269,286,302,147` | Y / Y / **gap** | Wrong page gap; auth at `branches.zig:334,363` | Exclusion gap |
| `new` | Issue/discussion/branch-patch/draft/comment/reply success; title, labels, target/source/same/unrelated branches, empty comment failures: `threads.zig:44,79,103,126,147`; `patches.zig:120,180,196,205,214,223,241,260`; `comments.zig:49,79,120` | Y for issue/patch/comment; discussion direct gaps | Missing/malformed comment targets: `comments.zig:134,164`; host-mode mixups: `threads.zig:748`; generic unknown target gap | Supported; below |
| `edit` | Issue/discussion/comment success and title/label/body failures: `threads.zig:311,375,398,422`; `comments.zig:259,332`. **Patch edit entirely missing.** | partial / partial / **gap** | Missing/malformed issue and missing comment: `threads.zig:437,459`; `comments.zig:348`; malformed comment gap | Supported |
| `remove` | Issue/discussion/comment/attachment/draft success: `threads.zig:620,638`; `comments.zig:388`; `attach.zig:305`; `patches.zig:533`. Published patch gap. | issue only / Y for tested subtypes / **gap** | Missing IDs covered at `threads.zig:669`, `comments.zig:424`, `attach.zig:350`; malformed IDs gap | Supported |
| `open` | Issue reopen only: `threads.zig:516`; patch gap | **gap / gap / gap** | All malformed/missing target cases gap | Supported, untested |
| `close` | Issue close: `threads.zig:488`; patch gap | Y / Y / Y | Missing/malformed/discussion targets: `threads.zig:544,564,577`; auth at `:522,602` | Supported |
| `resolve` | Ordinary issue title/labels and patch labels; blank-title failure: `patches.zig:572,591,607` | Y / Y / Y | Missing issue/wrong kind: `patches.zig:624,636`. **Real conflicts, hunks, `theirs`, bad hunk count and overlong labels missing.** | Supported |
| `publish` | Draft success: `patches.zig:447`; no flash failures | Y / Y / Y | Malformed ID: `patches.zig:513`; missing owned draft/already-published gaps; auth at `:469,501,507` | Exclusion: `patches.zig:521` |
| `merge` | Success, SHA256, protected target, conflict, stale check: `merge.zig:34,63,77,139,158` | **gap** / Y / Y | Malformed ID at `merge.zig:206`; missing-ID oracle wrong at `:203` | Exclusion: `merge.zig:218` |
| `squash` | Success and second-merge failure: `merge.zig:49,174` | Y / **gap / gap** | Malformed/missing target, conflict and stale-check gaps | Exclusion: `merge.zig:218` |
| `attach` | Byte-serving success; missing/bad name, empty, no length, oversized: `attach.zig:46,76,110,180` | Y / Y / Y | Wrong/missing/comment target: `attach.zig:266,278,290`; truncated upload and fixed exact-limit gap | Supported |
| `assign` | Name/email success; unknown/removed, invalid email, duplicate: `assign.zig:52,75,90,104,115,132` | Y / Y / Y | Missing/comment/malformed target: `assign.zig:204`; stale actor gap | Supported |
| `unassign` | Success, absent assignment 404: `assign.zig:267,285` | Y / Y / **gap** | Missing assignee/malformed target: `assign.zig:345`; stale actor gap | Supported |
| `subscribe` | Success, idempotence/resubscribe: `notify.zig:147,168` | Y / — / Y | Bad/missing target: `notify.zig:236,257`; restricted-tab behaviour gap | Exclusion: `notify.zig:273` |
| `mute` | Success: `notify.zig:125` | Y / — / **gap** | Bad/missing target and restricted-tab gaps; grouped auth at `notify.zig:201` | Exclusion: `notify.zig:273` |
| `undo` | Both hashes; copied-history refusal: `undo.zig:63,67,95` | Y / Y / Y | Missing/unknown index: `undo.zig:71,84`; nonnumeric/overflow gap | Exclusion: `repos.zig:461` |
| `search` | Issue/discussion redirect/filtering: `threads.zig:699,717`; no flash failures | Y / — / gap | Nonsearch/unknown page: `threads.zig:729`; encoded/overlong search and other loader types gap | Supported |

For account-wide handlers, repository role/private restrictions generally do not apply; scoped redirect/follow-up behaviour remains worth testing.

Local mode has no logged-out, role or private-repository dimension:

| Local suffix | Explicit coverage | Gaps |
|---|---|---|
| `new` | Git/xit issue, discussion, comment/reply, branch patch; issue/patch title, empty comment, invalid branch and draft refusal: `threads.zig:818,829,870`; `comments.zig:439,478`; `patches.zig:390,431` | Discussion title, label boundaries, malformed parents; `/repo/new` and `/user/new` fallback |
| `edit` | Git/xit issue success/title failure and comment success: `threads.zig:833,838`; `comments.zig:450,478` | Discussion/patch edit, empty comment edit, malformed targets |
| `remove` | Git/xit issue/comment; xit attachment: `threads.zig:856`; `comments.zig:468`; `attach.zig:385` | Discussion/patch, malformed/missing targets |
| `open` | None | Issue and patch reopening |
| `close` | Git/xit issue: `threads.zig:847,870` | Patch and malformed/missing targets |
| `resolve` | Xit issue title: `patches.zig:682` | Git, patch, invalid fields and actual conflicts |
| `sync` | Git/xit bidirectional success; no remote/no URL/unusable URL/wrong base: `sync.zig:53,61,70,116,120,124` | Remote-reported failure text/escaping and interrupted transfer |
| `attach` | Xit success: `attach.zig:363` | Git, upload failures and malformed targets |
| `assign` | Git/xit email success, invalid name/email, duplicate: `assign.zig:363,404` | Missing/malformed targets |
| `unassign` | Git/xit success: `assign.zig:397,404` | Missing assignment/malformed targets |
| `search` | Git/xit issue redirect: `threads.zig:864,870` | Other loaders and following-GET filtering |

Two dispatch details matter: local `/repo/new` and `/user/new` fall into generic `new` and return its 404, rather than necessarily 405; see [web.zig:747](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:747). Server `sync` is absent, and its 405 is tested at [repos.zig:471](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/repos.zig:471).

**Gaps that matter before phase 5:**

- Patch edit success and retained failure fields: its distinct adapter branch is [web.zig:2183](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:2183) and [web.zig:2199](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:2199).
- Actual conflicted issue/patch detail and resolution, including numbered hunks and `theirs`: [web.zig:2271](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:2271), [web.zig:2295](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:2295).
- Patch close/reopen, drafts/forks, pagination, search and permission-dependent detail data in the JSON corpus.
- The connection/unread-body checks above.

The remaining missing permutations of shared authorization handlers can follow incrementally, but the current grouped test names overstate their coverage. For example, members’ logged-out loop exercises only grant/revoke, and branches’ low-role loop only protect/default: [members.zig:236](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/members.zig:236), [branches.zig:358](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/branches.zig:358).

No form test sends malformed percent encoding, duplicate fields, an oversized form, truncated form data or chunked form data: `postWith` always constructs valid encoding. Those paths exist at [web.zig:3131](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:3131) and [web.zig:3175](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:3175). Add representative combined authorization/malformed-body tests; exhaustive wire permutations are less urgent for the loader split. The single cross-origin test covers server login only: [smoke.zig:92](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/smoke.zig:92).

**6. Phase 5 baseline recommendation**

Take phase 5 goldens from the **accepted pre-phase-5 tree**, after the decisions above. Keep the 66c1ab6 parity run separately; phase 5 should compare against its immediate accepted predecessor.

Add a whole-snapshot canonicalizer and comparison helper around `getJson`, using only `std`. Require expected HTTP status, JSON content type and page variant before comparison. Preserve all keys, nulls, array order, counts, permission flags, links and cursors; sort object keys only. The existing `getJson` is the correct seam: [harness.zig:264](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/harness.zig:264).

Use these normalization rules:

| Value | Treatment |
|---|---|
| `session.now` | Assert integer, replace with a fixed sentinel. It is assigned from real time at [web.zig:2470](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:2470). |
| `session.ansi_art` | Assert the expected representation, replace with a sentinel; selection is random at [ui.zig:3427](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui.zig:3427). |
| User/repo/thread/comment/attachment/fork IDs | Maintain an explicit bijection from fixture identities to stable IDs. Apply it consistently to fields, object keys where relevant, and embedded URLs. Never replace every hex-looking string indiscriminately. |
| `session.user_id` | Normalize the **raw bytes**, preserving null versus authenticated identity and the expected representation. It is a byte slice, not a hex string: [ui.zig:2580](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui.zig:2580). Zig can serialize valid UTF-8 byte slices as strings, otherwise arrays; fixed fixture IDs avoid that additional variability: [Stringify.zig:504](/opt/homebrew/Cellar/zig/0.17.1/lib/zig/std/json/Stringify.zig:504). |
| Event/commit times and OIDs | Prefer explicit fixed IDs and monotonically increasing timestamps during arrangement. Otherwise include exact known mappings in the fixture manifest. Normalizing only `session.now` is insufficient: current commits use real timestamps at [harness.zig:188](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/harness.zig:188) and [harness.zig:705](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/harness.zig:705). |
| Local repository display name | Create a stable named child directory, such as `snapshot-repo`, beneath the temporary directory. Currently the random temporary basename becomes the displayed repo name: [Repo.zig:247](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo.zig:247). |
| Paths | Do not blanket-strip them. Repository filesystem paths already serialize as empty strings; file paths and route paths are behaviour: [domain.zig:102](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain.zig:102). |

For complex fork/conflict arrangements, retaining an immutable arranged fixture and copying it into each test is also reasonable. Reset or clone state for each snapshot—or replay an explicitly fixed request sequence—because GETs consume flashes and mark notifications read. [web.zig:353](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:353), [notify.zig:94](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/notify.zig:94)

The fixed corpus should contain:

- **Cast and visibility:** existing Alice/Bob/Carol/Dave, plus a read-only member and promoted noncreator owner; public/private repositories and disabled/member-only tabs. Capture anonymous, owner, member and stranger variants where output differs.
- **Files/history/refs:** `/alice:open`, file and nested-directory routes, line windows and find; branch/tag/object addressing; commit list/message/search/later window; meaningful diff and patch-revision diff; refs search and later windows. Include text, Markdown, binary files, slash/percent/Unicode refs, tags, a merge commit, and enough refs to cross the **50-row** window. [Refs.zig:15](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo/Refs.zig:15)
- **Threads:** issue/discussion/patch lists, second windows, searches and labels; selected detail, description, edit, remove and resolve views. Arrange more than 20 items in the lists being paginated, and more than 10 comments in the comment window, with replies, assignments, attachments and removed entries. [Issues.zig:17](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo/Issues.zig:17), [Comment.zig:14](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo/Comment.zig:14)
- **Patch/fork states:** branch patch, owned and foreign drafts, published fork, open/closed/merged patches, stale/available merge checks, actual conflicts, and fork targets renamed/deleted. Forks compose their own files/history/patch data and are explicitly in scope: [Fork.zig:98](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Fork.zig:98).
- **Other pages:** `/`, `/home/users`, `/alice` and `/alice/forks`, including search/pagination; repository settings/members/branches; events active/removed/detail/moment; undo list/selection; notifications before and after reading, settings and keys; hidden-repo and unknown-route 404s.
- **Other modes:** representative file/history/ref/thread/conflict snapshots on local Git, local xit and SHA256 server repositories.

The harness changes needed now are deterministic arrangement/manifest support, full-tree comparison, explicit JSON array assertions, and the connection checks. No second production loader seam is necessary.

**7. RouteTooLong assessment**

**Confirmed, and still present today.** The relevant refs code is unchanged from 66c1ab6.

The failure chain is:

1. Ref names are percent-encoded and placed into a route limited to 512 bytes: [Refs.zig:445](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo/Refs.zig:445), [ui.zig:380](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui.zig:380), [ui.zig:687](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui.zig:687).
2. An oversized encoded name makes `refLink` return `RouteTooLong`. Window-navigation links have the same failure: [Refs.zig:430](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo/Refs.zig:430).
3. Every repository page builds the refs view, irrespective of the selected tab: [Repo.zig:549](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo.zig:549).
4. Even JSON requests construct the widget root **before** taking the JSON-only return: [web.zig:2472](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:2472). The outer handler converts the error to 500: [web.zig:165](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:165).

Thus the supplied probe’s “every page” result is credible for its fixture. More precisely, the failure occurs when the eagerly constructed refs window contains the offending name or navigation cursor; an offending ref beyond the initial window need not immediately break every ordinary route. Both branches and tags use this code. [Refs.zig:234](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo/Refs.zig:234)

This is a **significant pre-existing repository availability bug**. Owners and write-role members can push an ordinary unprotected branch over SSH; public read access alone does not grant that ability. [serve_ssh.zig:666](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/serve_ssh.zig:666), [serve_ssh.zig:691](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/serve_ssh.zig:691). A valid short raw name can exceed 512 after encoding—the test’s 513-byte encoded name is only 193 raw bytes: [branches.zig:9](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/branches.zig:9). The protection/default-selection limit does not constrain incoming pushed refs: [domain/repos.zig:370](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain/repos.zig:370).

The affected repository’s HTML and JSON pages can fail for all readers; unrelated repositories and the git transport are separate. A normal POST may still mutate successfully and then redirect into a broken page. Local repositories can encounter the same problem from legitimate locally created refs.

**Fix:** make route representation accommodate valid encoded ref names, or provide a nonthrowing fallback for unrepresentable ref links and cursors; one ref must not abort unrelated page construction. Add a test that actually creates the oversized encoded branch and requests files, issues and settings as both HTML and JSON. The current boundary test explicitly avoids creating it: [branches.zig:116](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/web/branches.zig:116). Treat the repair as a separate accepted behaviour change before blessing snapshots, rather than recording 500 pages as the normal baseline.